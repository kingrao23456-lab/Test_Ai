import { floatTo16BitPCM, pcm16ToBase64, base64ToPCM16, pcm16ToFloat32 } from "./audio-utils";
import { debugLog } from "./debugLogger";

export class AudioStreamer {
  private audioContext: AudioContext | null = null;
  private stream: MediaStream | null = null;
  private processor: ScriptProcessorNode | null = null;
  private source: MediaStreamAudioSourceNode | null = null;
  private nextStartTime: number = 0;
  private isPlaying: boolean = false;
  private activeSources: AudioBufferSourceNode[] = [];

  constructor(private onAudioData: (base64: string) => void) {}

  async startRecording() {
    debugLog("MIC", "startRecording() called");
    try {
      this.audioContext = new AudioContext({ sampleRate: 16000 });
      debugLog("MIC", "AudioContext created, state:", this.audioContext.state);

      if (this.audioContext.state === "suspended") {
        debugLog("MIC", "AudioContext was suspended, resuming...");
        await this.audioContext.resume();
        debugLog("MIC", "AudioContext state after resume:", this.audioContext.state);
      }

      debugLog("MIC", "Calling navigator.mediaDevices.getUserMedia({ audio: true })");
      this.stream = await navigator.mediaDevices.getUserMedia({ audio: true });

      const tracks = this.stream.getAudioTracks();
      debugLog(
        "MIC",
        "getUserMedia SUCCESS. Track count:",
        tracks.length,
        "label:",
        tracks[0]?.label,
        "enabled:",
        tracks[0]?.enabled,
        "muted:",
        tracks[0]?.muted,
        "readyState:",
        tracks[0]?.readyState
      );

      this.source = this.audioContext.createMediaStreamSource(this.stream);

      // Using ScriptProcessorNode for simplicity in this environment
      // Buffer size 2048 at 16kHz is ~128ms
      this.processor = this.audioContext.createScriptProcessor(2048, 1, 1);

      let chunkCount = 0;
      this.processor.onaudioprocess = (e) => {
        const inputData = e.inputBuffer.getChannelData(0);
        const pcmData = floatTo16BitPCM(inputData);
        const base64 = pcm16ToBase64(pcmData);
        this.onAudioData(base64);
        chunkCount++;
        if (chunkCount === 1) {
          debugLog("MIC", "First audio chunk captured and sent — mic is actively streaming.");
        }
      };

      this.source.connect(this.processor);
      this.processor.connect(this.audioContext.destination);
      this.nextStartTime = this.audioContext.currentTime;
      debugLog("MIC", "Recording pipeline fully connected.");
    } catch (err: any) {
      debugLog(
        "MIC_ERROR",
        "startRecording FAILED. name:",
        err?.name,
        "message:",
        err?.message,
        "stack:",
        err?.stack
      );
      throw err;
    }
  }

  stopRecording() {
    debugLog("MIC", "stopRecording() called");
    this.processor?.disconnect();
    this.source?.disconnect();
    this.stream?.getTracks().forEach(track => track.stop());
    this.audioContext?.close();
    this.audioContext = null;
    this.stream = null;
    this.processor = null;
    this.source = null;
    this.activeSources = [];
  }

  playAudioChunk(base64: string) {
    if (!this.audioContext) {
      this.audioContext = new AudioContext({ sampleRate: 24000 });
      this.nextStartTime = this.audioContext.currentTime;
    }

    const pcmData = base64ToPCM16(base64);
    const float32Data = pcm16ToFloat32(pcmData);
    
    const buffer = this.audioContext.createBuffer(1, float32Data.length, 24000);
    buffer.getChannelData(0).set(float32Data);
    
    const source = this.audioContext.createBufferSource();
    source.buffer = buffer;
    source.connect(this.audioContext.destination);
    
    source.onended = () => {
      this.activeSources = this.activeSources.filter(s => s !== source);
    };
    this.activeSources.push(source);

    const startTime = Math.max(this.nextStartTime, this.audioContext.currentTime);
    source.start(startTime);
    this.nextStartTime = startTime + buffer.duration;
  }

  stopPlayback() {
    // Actually stop all active sources for true interruption
    this.activeSources.forEach(source => {
      try {
        source.stop();
        source.disconnect();
      } catch (e) {}
    });
    this.activeSources = [];
    this.nextStartTime = this.audioContext?.currentTime || 0;
  }
}

