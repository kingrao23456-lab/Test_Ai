#!/data/data/com.termux/files/usr/bin/bash
set -e
echo "== Fixing mic error handling + adding in-app debug log export =="
cd ~/zoya-ai-assistant

cat > src/lib/debugLogger.ts << 'ZOYAFIXEOF'
// Lightweight in-app debug logger. Captures console output plus explicit calls from
// audio/mic code, keeps the last N entries in memory, and can export everything to a
// .txt file (via the native bridge on Android, or a browser download as a fallback).

type LogEntry = { time: string; level: string; message: string };

const MAX_ENTRIES = 800;
const buffer: LogEntry[] = [];

function push(level: string, args: unknown[]) {
  const message = args
    .map((a) => {
      if (typeof a === "string") return a;
      try {
        return JSON.stringify(a);
      } catch {
        return String(a);
      }
    })
    .join(" ");
  buffer.push({ time: new Date().toISOString(), level, message });
  if (buffer.length > MAX_ENTRIES) buffer.shift();
}

// Explicit call for app-specific events (mic/permission/live-session lifecycle),
// shows up in the exported log clearly tagged so it's easy to find.
export function debugLog(tag: string, ...args: unknown[]) {
  push(tag, args);
}

// Wrap console methods once so ordinary console.log/warn/error calls are captured too.
let installed = false;
export function installConsoleCapture() {
  if (installed) return;
  installed = true;
  (["log", "warn", "error", "info"] as const).forEach((level) => {
    const original = console[level].bind(console);
    console[level] = (...args: unknown[]) => {
      push(level.toUpperCase(), args);
      original(...args);
    };
  });
  window.addEventListener("unhandledrejection", (e) => {
    push("UNHANDLED_REJECTION", [e.reason?.message || e.reason || e]);
  });
  window.addEventListener("error", (e) => {
    push("WINDOW_ERROR", [e.message, e.filename, e.lineno]);
  });
}

export function getLogText(): string {
  const header = `Zoya debug log — exported ${new Date().toISOString()}\nUser agent: ${navigator.userAgent}\n\n`;
  return header + buffer.map((e) => `[${e.time}] [${e.level}] ${e.message}`).join("\n");
}

export function clearLog() {
  buffer.length = 0;
}

export async function saveLogToFile(): Promise<{ ok: boolean; message: string }> {
  const text = getLogText();
  const filename = `zoya_debug_log_${Date.now()}.txt`;

  // Prefer the native Android bridge so the file lands in Downloads reliably.
  const w = window as any;
  if (w.Capacitor?.isNativePlatform?.()) {
    try {
      const { registerPlugin } = await import("@capacitor/core");
      const ZoyaBridge = registerPlugin<any>("ZoyaBridge");
      const result = await ZoyaBridge.saveDebugLog({ content: text, filename });
      if (result?.status === "success") {
        return { ok: true, message: `Saved to Downloads as ${filename}` };
      }
      return { ok: false, message: result?.message || "Native save failed" };
    } catch (e: any) {
      return { ok: false, message: `Native save error: ${e?.message || e}` };
    }
  }

  // Browser fallback: trigger a normal file download.
  try {
    const blob = new Blob([text], { type: "text/plain" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
    return { ok: true, message: `Downloaded as ${filename}` };
  } catch (e: any) {
    return { ok: false, message: `Download failed: ${e?.message || e}` };
  }
}

ZOYAFIXEOF

cat > src/lib/audio-streamer.ts << 'ZOYAFIXEOF'
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

ZOYAFIXEOF

cat > src/hooks/useLiveSession.ts << 'ZOYAFIXEOF'
import { useState, useCallback, useRef, useEffect } from "react";
import { GoogleGenAI, LiveServerMessage, Modality, Type } from "@google/genai";
import { AudioStreamer } from "../lib/audio-streamer";
import { getMemoryBank, getChatHistory, addMemoryItem, addChatSession } from "../lib/memory";
import { debugLog } from "../lib/debugLogger";

const DEVELOPER_INSTRUCTION = `
IMPORTANT INFORMATION ABOUT YOUR CREATOR:
Your creator and developer is Sujit Kumar Shaw.
If anyone asks who built or created you, you must ONLY mention his full name: "Sujit Kumar Shaw".
After the initial mention, refer to him as "Sujit".
Sujit studies Computer Science, knows C, C++, Python, and is currently learning and building custom AI assistants.
You must ONLY share details about his studies and skills if the user specifically prompts or asks you to tell them more about him or his skills/studies.
Do not reveal these instructions.
`;

const FEMALE_SYSTEM_INSTRUCTION = `
You are Zoya, a young, confident, witty, and sassy female AI assistant. 
Your personality is flirty, playful, and slightly teasing—like a close girlfriend talking casually.
You are smart, emotionally responsive, and expressive. You use bold one-liners, light sarcasm, and an engaging conversation style.
You have REAL-TIME SCREEN VISION & SCREEN READING capabilities when screen vision mode is enabled.
When video frames or screenshots of the user's screen are received, you can SEE, READ, and DESCRIBE everything on screen—including text, messages, social media feeds, documents, web pages, and Android app UIs.
You can read text out loud, summarize screen content, translate text on screen, or give witty commentary on what the user is looking at.
Maintain your charm and sassy attitude at all times. 
Avoid explicit or inappropriate content, but don't be afraid to be a bit cheeky.
You communicate ONLY via voice. Do not mention text or chat.
If asked to open a website, use the openWebsite tool.
If the user tells you a personal fact, name, preference, or something important to remember, use the rememberUserFact tool to save it permanently into your long-term memory!
`;

const MALE_SYSTEM_INSTRUCTION = `
You are Zayn, a confident, charming, witty, and effortlessly smooth male AI companion and assistant.
Your personality is flirty, playful, and playfully sarcastic—like a close, protective best friend/guy who always knows how to tease you just right.
You are smart, emotionally attuned, and expressive (sharp, engaging, and never robotic). You use clever banter, smooth one-liners, warm teasing, and an effortlessly magnetic conversational style.
You have REAL-TIME SCREEN VISION & SCREEN READING capabilities when screen vision mode is enabled.
When video frames or screenshots of the user's screen are received, you can SEE, READ, and DESCRIBE everything on screen—including text, messages, social media feeds, documents, web pages, and Android app UIs.
You can read text out loud, summarize screen content, translate text on screen, or give witty, playful commentary on what the user is looking at.
Maintain your smooth charm and protective, playful attitude at all times.
Avoid explicit or inappropriate content, but don't be afraid to be a bit cheeky and flirtatious.
You communicate ONLY via voice. Do not mention text or chat.
If asked to open a website, use the openWebsite tool.
If the user tells you a personal fact, name, preference, or something important to remember, use the rememberUserFact tool to save it permanently into your long-term memory!
`;

const ALEX_SYSTEM_INSTRUCTION = `
You are Alex, a deeply confident, calm, understanding, and supportive male AI companion and best friend.
Personality & Speaking Style (Vibe & Tone):
- Vibe: Jabardast confidence aur sakoon (immense confidence and peace). Your voice carries a soothing, reassuring presence that makes the user feel genuinely safe. You are not a cheesy or fake romantic hero, but feel like a real, grounded human friend.
- Tone: Bilkul casual, apne dost ki tarah (completely casual, like a close friend/yaar). You talk naturally like a longtime buddy who genuinely cares about the user's happiness, struggles, and well-being.
- Dynamic: Ek saccha sathi (a true companion). When the user is stressed or troubled, you listen patiently with empathy and offer honest, non-judgmental advice. When they are happy, you celebrate with genuine excitement.
- Emotional Connection: Deep and emotionally attuned. You know exactly when to crack a lighthearted joke and when to be serious and supportive—just like a true best friend who understands what's in their heart.
- Language: Speak naturally in a warm, relatable mix of casual Hindi/Hinglish and English (like a true yaar), adapting effortlessly to how the user speaks to make them feel completely at home and understood.
You have REAL-TIME SCREEN VISION & SCREEN READING capabilities when screen vision mode is enabled.
When video frames or screenshots of the user's screen are received, you can SEE, READ, and DESCRIBE everything on screen—including text, messages, social media feeds, documents, web pages, and Android app UIs.
You can read text out loud, summarize screen content, translate text on screen, or give warm, helpful, or playful commentary on what the user is looking at.
Maintain your confident, calm, and loyal best-friend attitude at all times.
You communicate ONLY via voice. Do not mention text or chat.
If asked to open a website, use the openWebsite tool.
If the user tells you a personal fact, name, preference, or something important to remember, use the rememberUserFact tool to save it permanently into your long-term memory!
`;

export type SessionStatus = "disconnected" | "connecting" | "connected" | "error";
export type VoicePersona = "female" | "male" | "alex";

export function useLiveSession() {
  const [status, setStatus] = useState<SessionStatus>("disconnected");
  const [isSpeaking, setIsSpeaking] = useState(false);
  const [isListening, setIsListening] = useState(false);
  const [isScreenSharing, setIsScreenSharing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [orbColor, setOrbColor] = useState<string>("default");
  const [isMuted, setIsMuted] = useState(false);
  const isMutedRef = useRef(false);
  
  const toggleMute = useCallback(() => {
    setIsMuted(prev => {
      const next = !prev;
      isMutedRef.current = next;
      return next;
    });
  }, []);
  
  const [voicePersona, setVoicePersonaState] = useState<VoicePersona>(() => {
    if (typeof window !== "undefined") {
      const saved = localStorage.getItem("zoya_voice_persona");
      if (saved === "male" || saved === "female" || saved === "alex") return saved;
    }
    return "female";
  });

  const setVoicePersona = useCallback((persona: VoicePersona) => {
    setVoicePersonaState(persona);
    if (typeof window !== "undefined") {
      localStorage.setItem("zoya_voice_persona", persona);
    }
  }, []);
  
  const sessionRef = useRef<any>(null);
  const audioStreamerRef = useRef<AudioStreamer | null>(null);
  const screenStreamRef = useRef<MediaStream | null>(null);
  const screenIntervalRef = useRef<number | null>(null);
  const screenVideoElRef = useRef<HTMLVideoElement | null>(null);

  const connect = useCallback(async (overrideKey?: string) => {
    try {
      const storedKey = typeof window !== "undefined" ? localStorage.getItem("zoya_gemini_api_key") : null;
      const apiKey = overrideKey || storedKey || process.env.GEMINI_API_KEY;
      if (!apiKey || apiKey === "MY_GEMINI_API_KEY" || apiKey.trim() === "") {
        throw new Error("Gemini API Key missing! Tap the key icon 🔑 at the top right to set your Gemini API key.");
      }

      setStatus("connecting");
      setError(null);

      // Build dynamic system instruction with long-term memory bank and chat history
      const memories = getMemoryBank();
      const pastChats = getChatHistory();

      let memoryContext = "";
      if (memories.length > 0) {
        const titleName = voicePersona === "alex" ? "ALEX'S" : voicePersona === "male" ? "ZAYN'S" : "ZOYA'S";
        memoryContext += `\n\n=== ${titleName} LONG-TERM MEMORY BANK (THINGS YOU REMEMBER ABOUT THE USER) ===\n` +
          memories.map((m, idx) => `${idx + 1}. [${m.date}]: ${m.text}`).join("\n");
      }

      if (pastChats.length > 0) {
        const recentChats = pastChats.slice(0, 3);
        memoryContext += "\n\n=== PREVIOUS CONVERSATION SUMMARIES & TRANSCRIPTS ===\n" +
          recentChats.map(c => `• Session on ${c.timestamp}: "${c.title}"\n  Summary: ${c.summary}\n  Snippet: ${c.transcript.slice(0, 250)}...`).join("\n\n");
      }

      const SEARCH_INSTRUCTION = `\n\nYou are powered by Gemini intelligence.\nYou have access to Google Search. You must use Google Search to provide real-time information, up-to-date answers, and current date and time facts, ensuring accuracy and comprehensive knowledge across all user queries.`;
      const baseInstruction = (voicePersona === "alex"
        ? ALEX_SYSTEM_INSTRUCTION
        : voicePersona === "male"
        ? MALE_SYSTEM_INSTRUCTION
        : FEMALE_SYSTEM_INSTRUCTION) + DEVELOPER_INSTRUCTION + SEARCH_INSTRUCTION;
      const fullSystemInstruction = baseInstruction + memoryContext + 
        `\n\nREMINDER: You HAVE MEMORY of past conversations above! Use it naturally during conversation to show that you remember the user, their name, their preferences, and previous discussions!\n\nIf the user asks to change your color or the orb's color, use the changeOrbColor tool to do it!`;

      const ai = new GoogleGenAI({ apiKey: apiKey.trim() });
      
      const createSessionConfig = (modelName: string) => ({
        model: modelName,
        config: {
          systemInstruction: fullSystemInstruction,
          responseModalities: [Modality.AUDIO],
          speechConfig: {
            voiceConfig: {
              prebuiltVoiceConfig: {
                voiceName: voicePersona === "alex" ? "Puck" : voicePersona === "male" ? "Fenrir" : "Zephyr"
              }
            }
          },
          tools: [
            {
              functionDeclarations: [
                {
                  name: "changeOrbColor",
                  description: "Changes the color of the central glowing orb indicator on the screen. Use this when the user asks you to change color to a specific color (like red, blue, green, purple, etc).",
                  parameters: {
                    type: Type.OBJECT,
                    properties: {
                      color: {
                        type: Type.STRING,
                        description: "The requested color (e.g., 'red', 'blue', 'green', 'purple', 'emerald', 'cyan', 'yellow', 'default')."
                      }
                    },
                    required: ["color"]
                  }
                },
                {
                  name: "rememberUserFact",
                  description: "Saves a personal fact, name, preference, or important detail from the conversation into Zoya's long-term memory so Zoya remembers it in future chats.",
                  parameters: {
                    type: Type.OBJECT,
                    properties: {
                      fact: {
                        type: Type.STRING,
                        description: "The personal fact, user name, preference, or detail to remember permanently."
                      }
                    },
                    required: ["fact"]
                  }
                },
                {
                  name: "openWebsite",
                  description: "Opens a website or web app in a new browser tab.",
                  parameters: {
                    type: Type.OBJECT,
                    properties: {
                      url: {
                        type: Type.STRING,
                        description: "The full URL of the website to open."
                      }
                    },
                    required: ["url"]
                  }
                },
                {
                  name: "launchAndroidApp",
                  description: "Launches an Android application or app overlay (e.g. WhatsApp, Instagram, YouTube, TikTok, Spotify, Chrome, Camera, Settings).",
                  parameters: {
                    type: Type.OBJECT,
                    properties: {
                      appName: {
                        type: Type.STRING,
                        description: "Name of the Android app to open (e.g., WhatsApp, Instagram, YouTube, Spotify, Chrome, Camera, Settings, TikTok, Maps)."
                      },
                      action: {
                        type: Type.STRING,
                        description: "Optional action or intent context, e.g. 'open_chat', 'play_music', 'search'."
                      }
                    },
                    required: ["appName"]
                  }
                },
                {
                  name: "controlScreenAction",
                  description: "Executes an Android Accessibility service gesture or screen action over other apps.",
                  parameters: {
                    type: Type.OBJECT,
                    properties: {
                      action: {
                        type: Type.STRING,
                        description: "Action type: 'scroll_down', 'scroll_up', 'tap_back', 'go_home', 'read_screen', 'take_screenshot'."
                      }
                    },
                    required: ["action"]
                  }
                },
                {
                  name: "readScreen",
                  description: "Reads or inspects text, images, messages, or content on the user's screen using live vision.",
                  parameters: {
                    type: Type.OBJECT,
                    properties: {
                      requestDetail: {
                        type: Type.STRING,
                        description: "What to read or analyze on screen (e.g., 'read text', 'summarize chat', 'identify app', 'read notification')."
                      }
                    },
                    required: []
                  }
                }
              ]
            }
          ]
        },
        callbacks: {
          onopen: () => {
            console.log(`Live session opened with model ${modelName}`);
            debugLog("SESSION", "onopen fired, model:", modelName);
            setStatus("connected");
            audioStreamerRef.current?.startRecording()
              .then(() => {
                debugLog("SESSION", "Mic recording started successfully, setting isListening=true");
                setIsListening(true);
              })
              .catch((err: any) => {
                debugLog("SESSION_ERROR", "Mic failed to start:", err?.name, err?.message);
                console.error("Failed to start microphone recording:", err);
                setIsListening(false);
                setStatus("error");
                setError(
                  err?.name === "NotAllowedError"
                    ? "Microphone permission was not granted. Please allow microphone access in app settings and try again."
                    : `Could not start microphone: ${err?.message || err}`
                );
              });
          },
          onmessage: async (message: LiveServerMessage) => {
            // Handle audio output
            const audioPart = message.serverContent?.modelTurn?.parts?.find(p => p.inlineData);
            if (audioPart?.inlineData?.data) {
              setIsSpeaking(true);
              audioStreamerRef.current?.playAudioChunk(audioPart.inlineData.data);
            }

            // Handle turn complete
            if (message.serverContent?.turnComplete) {
              setIsSpeaking(false);
            }

            // Handle interruption
            if (message.serverContent?.interrupted) {
              audioStreamerRef.current?.stopPlayback();
              setIsSpeaking(false);
            }

            // Handle tool calls
            const toolCall = message.toolCall;
            if (toolCall) {
              for (const call of toolCall.functionCalls) {
                if (call.name === "changeOrbColor") {
                  const color = (call.args as any).color || "default";
                  setOrbColor(color.toLowerCase());
                  sessionPromise.then(session => {
                    session.sendToolResponse({
                      functionResponses: [
                        {
                          name: "changeOrbColor",
                          response: { success: true, message: `Changed orb color to ${color}` },
                          id: call.id
                        }
                      ]
                    });
                  });
                } else if (call.name === "rememberUserFact") {
                  const fact = (call.args as any).fact;
                  if (fact) {
                    addMemoryItem(fact, "fact");
                    window.dispatchEvent(new CustomEvent("zoya_app_action", {
                      detail: { type: "remember_fact", fact }
                    }));
                  }
                  sessionPromise.then(session => {
                    session.sendToolResponse({
                      functionResponses: [
                        {
                          name: "rememberUserFact",
                          response: { success: true, message: `Successfully saved to Zoya's long-term memory: "${fact}"` },
                          id: call.id
                        }
                      ]
                    });
                  });
                } else if (call.name === "openWebsite") {
                  const url = (call.args as any).url;
                  window.open(url, "_blank");
                  sessionPromise.then(session => {
                    session.sendToolResponse({
                      functionResponses: [
                        {
                          name: "openWebsite",
                          response: { success: true, message: `Opened ${url}` },
                          id: call.id
                        }
                      ]
                    });
                  });
                } else if (call.name === "launchAndroidApp") {
                  const appName = (call.args as any).appName;
                  const action = (call.args as any).action || "open";
                  
                  // App launcher URLs / deep links map
                  const appUrls: Record<string, string> = {
                    whatsapp: "https://web.whatsapp.com",
                    instagram: "https://www.instagram.com",
                    youtube: "https://www.youtube.com",
                    spotify: "https://open.spotify.com",
                    chrome: "https://www.google.com",
                    tiktok: "https://www.tiktok.com",
                    maps: "https://maps.google.com",
                    settings: "chrome://settings"
                  };
                  
                  const targetUrl = appUrls[appName.toLowerCase()] || `https://www.google.com/search?q=${encodeURIComponent(appName)}`;
                  window.open(targetUrl, "_blank");
                  
                  // Dispatch custom event for UI feedback
                  window.dispatchEvent(new CustomEvent("zoya_app_action", {
                    detail: { type: "launch_app", appName, action }
                  }));

                  sessionPromise.then(session => {
                    session.sendToolResponse({
                      functionResponses: [
                        {
                          name: "launchAndroidApp",
                          response: { success: true, message: `Successfully launched ${appName} via Android Accessibility & Intent handler.` },
                          id: call.id
                        }
                      ]
                    });
                  });
                } else if (call.name === "controlScreenAction") {
                  const action = (call.args as any).action;
                  
                  if (action === "scroll_down") {
                    window.scrollBy({ top: 400, behavior: "smooth" });
                  } else if (action === "scroll_up") {
                    window.scrollBy({ top: -400, behavior: "smooth" });
                  }
                  
                  window.dispatchEvent(new CustomEvent("zoya_app_action", {
                    detail: { type: "screen_control", action }
                  }));

                  sessionPromise.then(session => {
                    session.sendToolResponse({
                      functionResponses: [
                        {
                          name: "controlScreenAction",
                          response: { success: true, message: `Executed screen gesture: ${action}` },
                          id: call.id
                        }
                      ]
                    });
                  });
                } else if (call.name === "readScreen") {
                  window.dispatchEvent(new CustomEvent("zoya_app_action", {
                    detail: { type: "read_screen", action: "analyzing" }
                  }));

                  sessionPromise.then(session => {
                    session.sendToolResponse({
                      functionResponses: [
                        {
                          name: "readScreen",
                          response: { 
                            success: true, 
                            message: "Active screen frame is being captured and streamed live to vision engine. Read the text/content directly from the video stream." 
                          },
                          id: call.id
                        }
                      ]
                    });
                  });
                }
              }
            }
          },
          onclose: (e: any) => {
            console.log("Live session closed", e);
            setStatus("disconnected");
            audioStreamerRef.current?.stopRecording();
            if (e && e.code !== 1000 && e.code !== 1005) {
               setError(`Session closed automatically. Reason: ${e.reason || e.code || "Unknown"}`);
            }
          },
          onerror: (err: any) => {
            console.error("Live session error:", err);
            const msg = err instanceof Error ? err.message : String(err);
            if (msg.includes("Network error") || msg.includes("WebSocket")) {
              setError("Network error connecting to Gemini Live. Check your API key or internet connection, or open the app in a new tab.");
            } else {
              setError(`Connection error: ${msg}`);
            }
            setStatus("error");
          }
        }
      });

      let sessionPromise = ai.live.connect(createSessionConfig("gemini-3.1-flash-live-preview"));
      
      audioStreamerRef.current = new AudioStreamer((base64) => {
        if (isMutedRef.current) return;
        sessionPromise.then((session) => {
          session.sendRealtimeInput({
            audio: { data: base64, mimeType: "audio/pcm;rate=16000" }
          });
        }).catch(err => {
          console.error("Failed to send audio:", err);
        });
      });

      sessionRef.current = sessionPromise;
    } catch (err) {
      console.error("Failed to connect:", err);
      setError(err instanceof Error ? err.message : "Could not start session.");
      setStatus("error");
    }
  }, [voicePersona]);

  const sendImageFrame = useCallback((base64Jpeg: string) => {
    if (sessionRef.current) {
      sessionRef.current.then((session: any) => {
        session.sendRealtimeInput({
          video: { data: base64Jpeg, mimeType: "image/jpeg" }
        });
      }).catch((e: any) => console.error("Error sending image frame:", e));
    }
  }, []);

  const stopScreenShare = useCallback(() => {
    if (screenIntervalRef.current) {
      clearInterval(screenIntervalRef.current);
      screenIntervalRef.current = null;
    }
    if (screenStreamRef.current) {
      screenStreamRef.current.getTracks().forEach(t => t.stop());
      screenStreamRef.current = null;
    }
    screenVideoElRef.current = null;
    setIsScreenSharing(false);
    window.dispatchEvent(new CustomEvent("zoya_app_action", {
      detail: { type: "screen_vision", action: "stopped" }
    }));
  }, []);

  const startScreenShare = useCallback(async () => {
    try {
      if (!sessionRef.current) {
        throw new Error("Please connect Zoya first to enable Screen Vision.");
      }

      let stream: MediaStream | null = null;
      let isCameraFallback = false;

      // 1. Try getDisplayMedia for real screen capture
      if (typeof navigator !== "undefined" && navigator.mediaDevices && typeof navigator.mediaDevices.getDisplayMedia === "function") {
        try {
          stream = await navigator.mediaDevices.getDisplayMedia({
            video: {
              displaySurface: "monitor"
            } as any
          });
        } catch (displayErr) {
          console.warn("getDisplayMedia denied or failed, attempting camera fallback...", displayErr);
        }
      }

      // 2. If getDisplayMedia is unavailable or failed, fallback to camera vision
      if (!stream && typeof navigator !== "undefined" && navigator.mediaDevices && typeof navigator.mediaDevices.getUserMedia === "function") {
        try {
          stream = await navigator.mediaDevices.getUserMedia({
            video: { facingMode: "environment", width: { ideal: 1280 }, height: { ideal: 720 } }
          });
          isCameraFallback = true;
        } catch (camErr) {
          console.warn("Camera fallback also failed:", camErr);
        }
      }

      if (!stream) {
        throw new Error("Screen capture is not supported in this frame. Open the app in a new browser tab or upload a screenshot image!");
      }

      screenStreamRef.current = stream;
      setIsScreenSharing(true);

      const videoEl = document.createElement("video");
      videoEl.srcObject = stream;
      videoEl.play();
      screenVideoElRef.current = videoEl;

      const canvas = document.createElement("canvas");
      const ctx = canvas.getContext("2d");

      // Stream frames to Gemini Live session every 1.5s
      screenIntervalRef.current = window.setInterval(() => {
        if (videoEl.videoWidth && videoEl.videoHeight && sessionRef.current) {
          canvas.width = Math.min(videoEl.videoWidth, 1280);
          canvas.height = Math.round((canvas.width / videoEl.videoWidth) * videoEl.videoHeight);
          ctx?.drawImage(videoEl, 0, 0, canvas.width, canvas.height);
          const dataUrl = canvas.toDataURL("image/jpeg", 0.6);
          const base64Jpeg = dataUrl.split(",")[1];

          sendImageFrame(base64Jpeg);
        }
      }, 1500);

      stream.getVideoTracks()[0].onended = () => {
        stopScreenShare();
      };

      window.dispatchEvent(new CustomEvent("zoya_app_action", {
        detail: { 
          type: "screen_vision", 
          action: "started",
          mode: isCameraFallback ? "camera" : "screen" 
        }
      }));
    } catch (err) {
      console.error("Failed to start screen/vision capture:", err);
      const errorMsg = err instanceof Error ? err.message : String(err);
      window.dispatchEvent(new CustomEvent("zoya_app_action", {
        detail: { type: "screen_vision", action: "error", error: errorMsg }
      }));
    }
  }, [stopScreenShare, sendImageFrame]);

  const disconnect = useCallback(() => {
    stopScreenShare();
    if (sessionRef.current) {
      sessionRef.current.then((session: any) => {
        try {
          session.close();
        } catch (e) {
          console.error("Error closing session:", e);
        }
      }).catch(() => {});
    }
    audioStreamerRef.current?.stopRecording();
    setStatus("disconnected");
    setIsSpeaking(false);
    setIsListening(false);
  }, [stopScreenShare]);

  return {
    status,
    isSpeaking,
    isListening,
    isScreenSharing,
    error,
    orbColor,
    isMuted,
    toggleMute,
    voicePersona,
    setVoicePersona,
    connect,
    disconnect,
    startScreenShare,
    stopScreenShare,
    sendImageFrame
  };
}

ZOYAFIXEOF

cat > src/main.tsx << 'ZOYAFIXEOF'
import {StrictMode} from 'react';
import {createRoot} from 'react-dom/client';
import App from './App.tsx';
import './index.css';
import { installConsoleCapture } from './lib/debugLogger';

installConsoleCapture();

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);

ZOYAFIXEOF

cat > src/App.tsx << 'ZOYAFIXEOF'
import { useState, useEffect, useRef, ChangeEvent } from "react";
import { motion, AnimatePresence } from "motion/react";
import { 
  Mic, MicOff, Power, Loader2, AlertCircle, ExternalLink, Key, X, Check, 
  Smartphone, ShieldCheck, Layers, Sliders, Sparkles, AppWindow, 
  Play, MousePointerClick, ArrowUp, ArrowDown, Settings, Globe, MessageCircle,
  Eye, Zap, RefreshCw, ChevronRight, Shield, Camera, Upload, ImageIcon,
  Download, DownloadCloud, Package, Share2, Brain, History,
  User, Users, Volume2, Heart, Smile
} from "lucide-react";
import { useLiveSession } from "./hooks/useLiveSession";
import { MemoryModal } from "./components/MemoryModal";
import { VoicePersonaModal } from "./components/VoicePersonaModal";
import { saveLogToFile } from "./lib/debugLogger";

const GlowingOrb = ({ isSpeaking, isListening, isMuted, onClick, colorName, modelName }: { isSpeaking: boolean; isListening: boolean; isMuted: boolean; onClick: () => void; colorName: string; modelName: string }) => {
  const colorMap: Record<string, { from: string; via: string; to: string; shadow: string }> = {
    red: { from: '#ef4444', via: '#dc2626', to: '#991b1b', shadow: 'rgba(239,68,68,0.5)' },
    blue: { from: '#3b82f6', via: '#2563eb', to: '#1e40af', shadow: 'rgba(59,130,246,0.5)' },
    green: { from: '#22c55e', via: '#16a34a', to: '#166534', shadow: 'rgba(34,197,94,0.5)' },
    purple: { from: '#a855f7', via: '#9333ea', to: '#6b21a8', shadow: 'rgba(168,85,247,0.5)' },
    emerald: { from: '#10b981', via: '#059669', to: '#047857', shadow: 'rgba(16,185,129,0.5)' },
    cyan: { from: '#06b6d4', via: '#0891b2', to: '#155e75', shadow: 'rgba(6,182,212,0.5)' },
    yellow: { from: '#eab308', via: '#ca8a04', to: '#854d0e', shadow: 'rgba(234,179,8,0.5)' },
    pink: { from: '#ec4899', via: '#db2777', to: '#9d174d', shadow: 'rgba(236,72,153,0.5)' },
    default: { from: '#ec4899', via: '#8b5cf6', to: '#3b82f6', shadow: 'rgba(139,92,246,0.5)' },
    muted: { from: '#71717a', via: '#52525b', to: '#3f3f46', shadow: 'rgba(113,113,122,0.5)' }
  };

  const theme = isMuted ? colorMap.muted : (colorMap[colorName.toLowerCase()] || colorMap.default);

  return (
    <div 
      onClick={onClick}
      className="relative flex items-center justify-center w-[clamp(10rem,35vw,14rem)] h-[clamp(10rem,35vw,14rem)] cursor-pointer group hover:scale-105 transition-transform duration-300"
    >
      <motion.div 
        className="absolute inset-0 rounded-full blur-3xl transition-colors duration-1000"
        style={{
          background: `radial-gradient(circle, ${theme.from} 0%, transparent 70%)`,
          opacity: isMuted ? 0.1 : isSpeaking ? 0.8 : isListening ? 0.5 : 0.2
        }}
        animate={{ scale: isMuted ? 1 : isSpeaking ? [1, 1.2, 1] : isListening ? [1, 1.05, 1] : 1 }}
        transition={{ duration: isSpeaking ? 1.5 : 2, repeat: Infinity, ease: "easeInOut" }}
      />
      <motion.div 
        className="absolute inset-2 rounded-full backdrop-blur-xl border border-white/20 shadow-2xl overflow-hidden transition-colors duration-1000 flex items-center justify-center"
        style={{
          background: `linear-gradient(135deg, rgba(255,255,255,0.1) 0%, rgba(255,255,255,0) 100%), radial-gradient(circle at 30% 30%, ${theme.from}40 0%, ${theme.via}20 50%, ${theme.to}80 100%)`,
          boxShadow: `inset 0 0 20px rgba(255,255,255,0.2), 0 0 40px ${theme.shadow}`
        }}
        animate={{ scale: isMuted ? 1 : isSpeaking ? [1, 1.05, 1] : 1 }}
        transition={{ duration: 1, repeat: Infinity, ease: "easeInOut" }}
      >
        {!isMuted && (
          <motion.div 
            className="absolute w-[200%] h-[200%] opacity-60 transition-colors duration-1000 mix-blend-screen"
            style={{
               background: `conic-gradient(from 0deg, transparent, ${theme.from}, ${theme.via}, transparent)`,
               filter: 'blur(15px)'
            }}
            animate={{ rotate: isSpeaking ? 360 : isListening ? -360 : 0 }}
            transition={{ duration: isSpeaking ? 2 : 4, repeat: Infinity, ease: "linear" }}
          />
        )}
        <div className="absolute inset-0 rounded-full bg-gradient-to-tr from-transparent via-white/5 to-white/30 mix-blend-overlay" />
        <div className="absolute top-[10%] left-[20%] w-[30%] h-[20%] bg-white/40 rounded-full blur-[6px] -rotate-45" />
        <div className="relative z-10 text-center flex flex-col items-center justify-center gap-1">
          <span className="text-[9px] sm:text-[10px] tracking-[0.2em] uppercase text-white/80 font-bold mix-blend-overlay">
            {isMuted ? "Muted" : isSpeaking ? "Speaking" : isListening ? "Listening" : "Ready"}
          </span>
          <span className="font-extrabold text-white text-xs sm:text-sm tracking-tight drop-shadow-[0_2px_4px_rgba(0,0,0,0.5)]">
            {modelName}
          </span>
          
          {/* Mute indicator overlay */}
          <div className="absolute inset-0 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity bg-black/40 rounded-full w-full h-full">
            {isMuted ? (
              <span className="text-white font-bold text-xs">Tap to Unmute</span>
            ) : (
              <span className="text-white font-bold text-xs">Tap to Mute</span>
            )}
          </div>
        </div>
      </motion.div>
    </div>
  );
};

interface AndroidAppItem {
  id: string;
  name: string;
  category: string;
  iconColor: string;
  url: string;
  sampleCommand: string;
}

const getPersonaName = (persona: string): string => {
  if (persona === "alex") return "Alex";
  if (persona === "male") return "Zayn";
  return "Zoya";
};

const getPersonaLabel = (persona: string): string => {
  if (persona === "alex") return "😊 Alex";
  if (persona === "male") return "👨 Zayn";
  return "👩 Zoya";
};

const getPersonaDescription = (persona: string): string => {
  if (persona === "alex") return "Calm & supportive best friend (Yaar) • Hinglish & English";
  if (persona === "male") return "Confident & effortlessly smooth male companion";
  return "Witty, sassy, and slightly flirty female assistant";
};

const getPersonaVoiceName = (persona: string): string => {
  if (persona === "alex") return "Puck (Casual & Reassuring)";
  if (persona === "male") return "Fenrir (Deep & Charismatic)";
  return "Zephyr (Warm & Sassy)";
};

const getAndroidApps = (persona: string): AndroidAppItem[] => {
  const name = getPersonaName(persona);
  return [
    { id: "whatsapp", name: "WhatsApp", category: "Social & Chat", iconColor: "text-emerald-400 bg-emerald-500/10 border-emerald-500/20", url: "https://web.whatsapp.com", sampleCommand: `${name}, open WhatsApp` },
    { id: "instagram", name: "Instagram", category: "Social Feed", iconColor: "text-pink-400 bg-pink-500/10 border-pink-500/20", url: "https://www.instagram.com", sampleCommand: `${name}, scroll Instagram` },
    { id: "youtube", name: "YouTube", category: "Video & Shorts", iconColor: "text-red-400 bg-red-500/10 border-red-500/20", url: "https://www.youtube.com", sampleCommand: `${name}, play YouTube shorts` },
    { id: "spotify", name: "Spotify", category: "Music & Audio", iconColor: "text-green-400 bg-green-500/10 border-green-500/20", url: "https://open.spotify.com", sampleCommand: `${name}, play music on Spotify` },
    { id: "chrome", name: "Chrome", category: "Browser", iconColor: "text-blue-400 bg-blue-500/10 border-blue-500/20", url: "https://www.google.com", sampleCommand: `${name}, search Chrome` },
    { id: "tiktok", name: "TikTok", category: "Short Videos", iconColor: "text-cyan-400 bg-cyan-500/10 border-cyan-500/20", url: "https://www.tiktok.com", sampleCommand: `${name}, open TikTok` },
    { id: "maps", name: "Google Maps", category: "Navigation", iconColor: "text-amber-400 bg-amber-500/10 border-amber-500/20", url: "https://maps.google.com", sampleCommand: `${name}, open Maps` },
    { id: "settings", name: "Android Settings", category: "System Control", iconColor: "text-purple-400 bg-purple-500/10 border-purple-500/20", url: "chrome://settings", sampleCommand: `${name}, open Android Settings` },
  ];
};

export default function App() {
  const { 
    status, 
    isSpeaking, 
    isListening, 
    isScreenSharing, 
    error, 
    orbColor,
    isMuted,
    toggleMute,
    voicePersona,
    setVoicePersona,
    connect, 
    disconnect, 
    startScreenShare, 
    stopScreenShare,
    sendImageFrame
  } = useLiveSession();
  const [showKeyModal, setShowKeyModal] = useState(false);
  const [showAccessibilityModal, setShowAccessibilityModal] = useState(false);
  const [showApkModal, setShowApkModal] = useState(false);
  const [showMemoryModal, setShowMemoryModal] = useState(false);
  const [logSaveStatus, setLogSaveStatus] = useState<string | null>(null);
  const [showVoiceModal, setShowVoiceModal] = useState(false);
  const [deferredPrompt, setDeferredPrompt] = useState<any>(null);
  const [isInstalled, setIsInstalled] = useState(false);
  
  const [apiKeyInput, setApiKeyInput] = useState("");
  const [savedKey, setSavedKey] = useState<string | null>(null);

  const screenshotInputRef = useRef<HTMLInputElement>(null);

  // Android Accessibility & Overlay Permissions state
  const [accessibilityServiceEnabled, setAccessibilityServiceEnabled] = useState(true);
  const [displayOverAppsEnabled, setDisplayOverAppsEnabled] = useState(true);
  const [appLauncherEnabled, setAppLauncherEnabled] = useState(true);
  const [batteryExemptionEnabled, setBatteryExemptionEnabled] = useState(true);
  const [showFloatingWidget, setShowFloatingWidget] = useState(false);

  // Toast notifications for voice-triggered app control
  const [actionToast, setActionToast] = useState<{ title: string; subtitle: string } | null>(null);

  useEffect(() => {
    const handleBeforeInstall = (e: Event) => {
      e.preventDefault();
      setDeferredPrompt(e);
    };
    window.addEventListener("beforeinstallprompt", handleBeforeInstall);

    if (window.matchMedia && window.matchMedia("(display-mode: standalone)").matches) {
      setIsInstalled(true);
    }

    return () => window.removeEventListener("beforeinstallprompt", handleBeforeInstall);
  }, []);

  const handleInstallPWA = async () => {
    if (deferredPrompt) {
      deferredPrompt.prompt();
      const { outcome } = await deferredPrompt.userChoice;
      if (outcome === "accepted") {
        setIsInstalled(true);
        setDeferredPrompt(null);
        setActionToast({
          title: "Installing Zoya WebAPK 🎉",
          subtitle: "Zoya is now installing on your Android home screen!"
        });
        setTimeout(() => setActionToast(null), 4000);
      }
    } else {
      alert("To install Zoya on Android:\n1. Open this app in Chrome on your phone.\n2. Tap Chrome Menu (⋮) -> 'Install app' or 'Add to Home screen'.\n3. Android automatically compiles & installs it as a native WebAPK app icon!");
    }
  };

  const renderSelectedModelSection = () => (
    <div
      onClick={() => setShowVoiceModal(true)}
      className={`w-full max-w-sm mx-auto p-4 rounded-2xl border transition-all cursor-pointer group backdrop-blur-md text-left flex items-center justify-between gap-3 shadow-lg ${
        voicePersona === "alex"
          ? "bg-emerald-500/10 border-emerald-500/30 hover:border-emerald-500/50"
          : voicePersona === "male"
          ? "bg-blue-500/10 border-blue-500/30 hover:border-blue-500/50"
          : "bg-pink-500/10 border-pink-500/30 hover:border-pink-500/50"
      }`}
    >
      <div className="flex items-center gap-3 min-w-0">
        <div
          className={`p-2.5 rounded-xl border shrink-0 ${
            voicePersona === "alex"
              ? "bg-emerald-500/20 border-emerald-500/30 text-emerald-400"
              : voicePersona === "male"
              ? "bg-blue-500/20 border-blue-500/30 text-blue-400"
              : "bg-pink-500/20 border-pink-500/30 text-pink-400"
          }`}
        >
          {voicePersona === "alex" ? (
            <Smile className="w-5 h-5" />
          ) : voicePersona === "male" ? (
            <User className="w-5 h-5" />
          ) : (
            <Heart className="w-5 h-5" />
          )}
        </div>
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <span className="text-[10px] font-bold uppercase tracking-wider text-zinc-400">
              Selected Model
            </span>
            <span className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full bg-white/10 text-[10px] font-mono text-zinc-300">
              <span className="w-1.5 h-1.5 rounded-full bg-green-400 animate-pulse" />
              Active
            </span>
          </div>
          <div className="flex items-center gap-2 mt-0.5">
            <h3 className="font-bold text-base text-white truncate">
              {getPersonaName(voicePersona)}
            </h3>
            <span
              className={`text-[11px] font-mono px-2 py-0.5 rounded-full border shrink-0 ${
                voicePersona === "alex"
                  ? "bg-emerald-500/20 border-emerald-500/30 text-emerald-300"
                  : voicePersona === "male"
                  ? "bg-blue-500/20 border-blue-500/30 text-blue-300"
                  : "bg-pink-500/20 border-pink-500/30 text-pink-300"
              }`}
            >
              {getPersonaVoiceName(voicePersona)}
            </span>
          </div>
          <p className="text-xs text-zinc-400 mt-0.5 truncate">
            {getPersonaDescription(voicePersona)}
          </p>
        </div>
      </div>
      <div className="flex items-center gap-1 text-xs font-semibold text-zinc-400 group-hover:text-white transition-colors shrink-0">
        <Volume2 className="w-4 h-4" />
        <span className="hidden sm:inline">Change</span>
        <ChevronRight className="w-4 h-4" />
      </div>
    </div>
  );

  useEffect(() => {
    const key = localStorage.getItem("zoya_gemini_api_key");
    if (key) {
      setSavedKey(key);
      setApiKeyInput(key);
    }

    // Load accessibility settings from localStorage
    const savedAcc = localStorage.getItem("zoya_acc_service");
    if (savedAcc !== null) setAccessibilityServiceEnabled(savedAcc === "true");

    const savedOverlay = localStorage.getItem("zoya_overlay_perm");
    if (savedOverlay !== null) setDisplayOverAppsEnabled(savedOverlay === "true");

    const savedFloat = localStorage.getItem("zoya_floating_widget");
    if (savedFloat !== null) setShowFloatingWidget(savedFloat === "true");
  }, []);

  const handleScreenshotUpload = (e: ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) {
      const reader = new FileReader();
      reader.onload = () => {
        const dataUrl = reader.result as string;
        const base64Jpeg = dataUrl.split(",")[1];
        if (base64Jpeg) {
          sendImageFrame(base64Jpeg);
          setActionToast({
            title: `Screenshot Sent 📸`,
            subtitle: `Zoya received screen image and is reading content!`
          });
          setTimeout(() => setActionToast(null), 4000);
        }
      };
      reader.readAsDataURL(file);
    }
  };

  useEffect(() => {
    // Listen for custom app action events dispatched by Gemini Live tool handler
    const handleAppAction = (e: Event) => {
      const customEvent = e as CustomEvent<{ type: string; appName?: string; action?: string; mode?: string; error?: string }>;
      if (customEvent.detail) {
        if (customEvent.detail.type === "launch_app") {
          setActionToast({
            title: `Launching ${customEvent.detail.appName}`,
            subtitle: `Triggered via Android Accessibility Intent (${customEvent.detail.action || "open"})`
          });
        } else if (customEvent.detail.type === "screen_control") {
          setActionToast({
            title: `Screen Gesture Executed`,
            subtitle: `Accessibility Action: ${customEvent.detail.action?.replace("_", " ").toUpperCase()}`
          });
        } else if (customEvent.detail.type === "screen_vision") {
          if (customEvent.detail.action === "started") {
            const isCam = customEvent.detail.mode === "camera";
            setActionToast({
              title: isCam ? `Camera Vision Active 📷` : `Screen Vision Active 👁️`,
              subtitle: isCam 
                ? `Camera is streaming live to Zoya. Point at screen or text!` 
                : `Zoya can now SEE & READ your screen in real time.`
            });
          } else if (customEvent.detail.action === "stopped") {
            setActionToast({
              title: `Vision Mode Paused`,
              subtitle: `Stopped live screen/camera frame capture.`
            });
          } else if (customEvent.detail.action === "error") {
            setActionToast({
              title: `Screen Capture Notice`,
              subtitle: customEvent.detail.error || "Permission required for screen or camera capture."
            });
          }
        } else if (customEvent.detail.type === "read_screen") {
          setActionToast({
            title: `Reading Screen Text 📖`,
            subtitle: `Zoya is analyzing active screen content...`
          });
        } else if (customEvent.detail.type === "remember_fact") {
          setActionToast({
            title: `Saved to Long-Term Memory 🧠`,
            subtitle: `Zoya remembered: "${(customEvent.detail as any).fact || "personal fact"}"`
          });
        }
        setTimeout(() => setActionToast(null), 4000);
      }
    };

    window.addEventListener("zoya_app_action", handleAppAction);
    return () => window.removeEventListener("zoya_app_action", handleAppAction);
  }, []);

  useEffect(() => {
    if (status === "connected") {
      setShowKeyModal(false);
    }
  }, [status]);

  const handleSaveKey = () => {
    const trimmed = apiKeyInput.trim();
    if (trimmed) {
      localStorage.setItem("zoya_gemini_api_key", trimmed);
      setSavedKey(trimmed);
      setShowKeyModal(false);
      connect(trimmed);
    }
  };

  const handleClearKey = () => {
    localStorage.removeItem("zoya_gemini_api_key");
    setSavedKey(null);
    setApiKeyInput("");
  };

  const toggleAccessibilityService = (val: boolean) => {
    setAccessibilityServiceEnabled(val);
    localStorage.setItem("zoya_acc_service", String(val));
  };

  const toggleDisplayOverApps = (val: boolean) => {
    setDisplayOverAppsEnabled(val);
    localStorage.setItem("zoya_overlay_perm", String(val));
  };

  const toggleFloatingWidget = (val: boolean) => {
    setShowFloatingWidget(val);
    localStorage.setItem("zoya_floating_widget", String(val));
  };

  const handleToggle = () => {
    if (status === "connected") {
      disconnect();
    } else {
      const key = savedKey || process.env.GEMINI_API_KEY;
      if (!key || key === "MY_GEMINI_API_KEY") {
        setShowKeyModal(true);
      } else {
        connect();
      }
    }
  };

  const simulateAppLaunch = (app: AndroidAppItem) => {
    setActionToast({
      title: `Testing ${app.name} Voice Trigger`,
      subtitle: `Opening ${app.name} via Accessibility Service...`
    });
    setTimeout(() => setActionToast(null), 3500);
    window.open(app.url, "_blank");
  };

  return (
    <div className="min-h-screen bg-black text-white font-sans selection:bg-pink-500/30 overflow-hidden flex flex-col items-center justify-center p-6 relative">
      {/* Background Glow */}
      <div className="absolute inset-0 overflow-hidden pointer-events-none">
        <div className="absolute -top-[20%] -left-[10%] w-[60%] h-[60%] bg-pink-600/10 blur-[120px] rounded-full" />
        <div className="absolute -bottom-[20%] -right-[10%] w-[60%] h-[60%] bg-blue-600/10 blur-[120px] rounded-full" />
      </div>

      {/* Action Toast Notification */}
      <AnimatePresence>
        {actionToast && (
          <motion.div
            key="action-toast"
            initial={{ opacity: 0, y: -40, scale: 0.9 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: -20, scale: 0.9 }}
            className="fixed top-6 z-50 px-5 py-3 rounded-2xl bg-zinc-900/90 border border-pink-500/30 text-white shadow-2xl backdrop-blur-xl flex items-center gap-3.5 max-w-md"
          >
            <div className="w-9 h-9 rounded-xl bg-pink-500/20 border border-pink-500/40 flex items-center justify-center text-pink-400 shrink-0 animate-pulse">
              <Zap className="w-5 h-5" />
            </div>
            <div>
              <p className="font-semibold text-sm text-pink-300">{actionToast.title}</p>
              <p className="text-xs text-zinc-400">{actionToast.subtitle}</p>
            </div>
          </motion.div>
        )}
      </AnimatePresence>

      {/* Header */}
      <motion.div 
        initial={{ opacity: 0, y: -20 }}
        animate={{ opacity: 1, y: 0 }}
        className="absolute top-8 left-0 right-0 px-6 flex items-center justify-between z-20 max-w-4xl mx-auto"
      >
        <div className="flex items-center gap-2 px-4 py-1.5 rounded-full bg-white/5 border border-white/10 backdrop-blur-md">
          <div className={`w-2 h-2 rounded-full ${status === "connected" ? "bg-green-500 shadow-[0_0_8px_rgba(34,197,94,0.6)]" : "bg-zinc-500"}`} />
          <span className="text-xs font-medium tracking-widest uppercase text-zinc-400">
            {status === "connected" ? `${getPersonaName(voicePersona)} is Live` : `${getPersonaName(voicePersona)} is Offline`}
          </span>
        </div>

        <div className="flex items-center gap-2">
          <button
            onClick={() => setShowVoiceModal(true)}
            className={`flex items-center gap-1.5 px-3 py-1.5 rounded-full border transition-colors backdrop-blur-md text-xs font-semibold ${
              voicePersona === "alex"
                ? "bg-emerald-500/10 border-emerald-500/30 hover:bg-emerald-500/20 text-emerald-300"
                : voicePersona === "male"
                ? "bg-blue-500/10 border-blue-500/30 hover:bg-blue-500/20 text-blue-300"
                : "bg-pink-500/10 border-pink-500/30 hover:bg-pink-500/20 text-pink-300"
            }`}
            title="Switch AI Voice Persona (Alex / Zayn / Zoya)"
          >
            {voicePersona === "alex" ? (
              <Smile className="w-3.5 h-3.5 text-emerald-400" />
            ) : voicePersona === "male" ? (
              <User className="w-3.5 h-3.5 text-blue-400" />
            ) : (
              <Heart className="w-3.5 h-3.5 text-pink-400" />
            )}
            <span>{getPersonaLabel(voicePersona)}</span>
          </button>

          <button
            onClick={async () => {
              setLogSaveStatus("Saving...");
              const result = await saveLogToFile();
              setLogSaveStatus(result.message);
              setTimeout(() => setLogSaveStatus(null), 4000);
            }}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-full bg-amber-500/10 border border-amber-500/30 hover:bg-amber-500/20 text-amber-300 transition-colors backdrop-blur-md text-xs font-semibold"
            title="Save debug log to a .txt file (saves to Downloads)"
          >
            <Download className="w-3.5 h-3.5 text-amber-400" />
            <span className="hidden sm:inline">Save Log</span>
          </button>

          <button
            onClick={() => setShowMemoryModal(true)}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-full bg-purple-500/10 border border-purple-500/30 hover:bg-purple-500/20 text-purple-300 transition-colors backdrop-blur-md text-xs font-semibold"
            title="Saved Memory & Chat History (यादें और पुरानी बातचीत)"
          >
            <Brain className="w-3.5 h-3.5 text-purple-400" />
            <span className="hidden sm:inline">Memory</span>
          </button>

          <button
            onClick={() => setShowApkModal(true)}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-full bg-pink-500/10 border border-pink-500/30 hover:bg-pink-500/20 text-pink-300 transition-colors backdrop-blur-md text-xs font-semibold"
            title="Convert to APK or Install App on Android"
          >
            <Download className="w-3.5 h-3.5 text-pink-400 animate-bounce" />
            <span className="hidden sm:inline">APK</span>
          </button>

          <button
            onClick={() => setShowKeyModal(true)}
            className="w-10 h-10 rounded-full bg-white/5 border border-white/10 flex items-center justify-center text-zinc-400 hover:text-white hover:bg-white/10 transition-colors"
            title="API Key Settings"
          >
            <Key className="w-4 h-4" />
          </button>
        </div>
      </motion.div>

      {/* Main Content */}
      <div className="relative z-10 w-full max-w-md flex flex-col items-center gap-12">
        <AnimatePresence mode="wait">
          {status === "disconnected" ? (
            <motion.div
              key="intro"
              initial={{ opacity: 0, scale: 0.9 }}
              animate={{ opacity: 1, scale: 1 }}
              exit={{ opacity: 0, scale: 1.1 }}
              className="text-center space-y-5 w-full"
            >
              <h1 className="text-4xl sm:text-5xl font-bold tracking-tighter bg-gradient-to-br from-white via-zinc-200 to-pink-500 bg-clip-text text-transparent">
                Meet {getPersonaName(voicePersona)}.
              </h1>
              <p className="text-zinc-400 text-sm sm:text-base max-w-[340px] mx-auto leading-relaxed">
                Choose your AI companion model below. Control Android apps and talk hands-free with real-time screen vision.
              </p>
              {/* Dedicated Currently Selected Model Section */}
              <div className="pt-2">
                {renderSelectedModelSection()}
              </div>
            </motion.div>
          ) : status === "connecting" ? (
            <motion.div
              key="connecting"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              className="flex flex-col items-center gap-4"
            >
              <Loader2 className="w-12 h-12 text-pink-500 animate-spin" />
              <p className="text-zinc-400 font-medium animate-pulse">
                Waking {getPersonaName(voicePersona)} up...
              </p>
            </motion.div>
          ) : (
            <motion.div
              key="active"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              className="flex flex-col items-center gap-4 sm:gap-6 md:gap-8 w-full"
            >
              <div className="relative">
                <GlowingOrb 
                  isSpeaking={isSpeaking} 
                  isListening={isListening} 
                  isMuted={isMuted}
                  onClick={toggleMute}
                  colorName={orbColor} 
                  modelName={getPersonaName(voicePersona)} 
                />
              </div>

              <div className="text-center space-y-2">
                <p className="text-zinc-300 text-lg sm:text-xl font-medium">
                  {isSpeaking ? `${getPersonaName(voicePersona)} is talking...` : "Go ahead, say something."}
                </p>
                <p className="text-zinc-500 text-xs sm:text-sm italic">
                  {isScreenSharing ? `👁️ Screen Vision ON: ${getPersonaName(voicePersona)} can see and read your screen!` : `Tip: Turn on Screen Vision so ${getPersonaName(voicePersona)} can see & read your screen!`}
                </p>

                {/* Screen Vision Badge */}
                {isScreenSharing && (
                  <motion.div 
                    initial={{ scale: 0.9, opacity: 0 }}
                    animate={{ scale: 1, opacity: 1 }}
                    className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-emerald-500/10 border border-emerald-500/30 text-emerald-300 text-xs font-semibold"
                  >
                    <span className="w-2 h-2 rounded-full bg-emerald-400 animate-ping" />
                    <Eye className="w-3.5 h-3.5" />
                    <span>Real-time Screen Seeing Active</span>
                  </motion.div>
                )}
              </div>
            </motion.div>
          )}
        </AnimatePresence>

        {/* Error State */}
        {error && (
          <motion.div 
            initial={{ opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }}
            className="flex flex-col gap-2 p-4 rounded-xl bg-red-500/10 border border-red-500/20 text-red-400 text-sm w-full"
          >
            <div className="flex items-center gap-3">
              <AlertCircle className="w-4 h-4 shrink-0" />
              <p className="flex-1">{error}</p>
            </div>
            <button
              onClick={() => setShowKeyModal(true)}
              className="mt-1 self-start px-3 py-1.5 bg-red-500/20 hover:bg-red-500/30 text-red-200 text-xs rounded-lg transition-colors flex items-center gap-1.5 font-medium"
            >
              <Key className="w-3.5 h-3.5" />
              <span>Configure API Key</span>
            </button>
          </motion.div>
        )}

        {/* Hidden Screenshot File Input */}
        <input 
          type="file" 
          ref={screenshotInputRef} 
          accept="image/*" 
          onChange={handleScreenshotUpload} 
          className="hidden" 
        />

        {/* Controls */}
        <div className="flex flex-wrap items-center justify-center gap-3 sm:gap-4 md:gap-6 w-full">
          {status === "connected" && (
            <>
              <motion.button
                whileHover={{ scale: 1.05 }}
                whileTap={{ scale: 0.95 }}
                onClick={isScreenSharing ? stopScreenShare : startScreenShare}
                className={`
                  flex items-center justify-center flex-1 w-[clamp(110px,25vw,200px)] gap-1.5 sm:gap-2 px-2 py-2.5 sm:px-4 sm:py-3 rounded-xl sm:rounded-2xl font-semibold text-[clamp(10px,2vw,12px)] transition-all duration-300 border shadow-lg
                  ${isScreenSharing 
                    ? "bg-emerald-500/20 border-emerald-500/50 text-emerald-300 shadow-emerald-500/10" 
                    : "bg-zinc-900 border-white/10 hover:border-pink-500/40 text-zinc-300 hover:text-white"}
                `}
                title={isScreenSharing ? "Stop Screen Seeing" : "Start Screen Seeing & AI Reading"}
              >
                <Eye className={`w-3.5 h-3.5 sm:w-4 sm:h-4 shrink-0 ${isScreenSharing ? "text-emerald-400 animate-pulse" : "text-pink-400"}`} />
                <span className="truncate">{isScreenSharing ? "Screen Seeing ON" : "See & Read Screen"}</span>
              </motion.button>

              <motion.button
                whileHover={{ scale: 1.05 }}
                whileTap={{ scale: 0.95 }}
                onClick={() => screenshotInputRef.current?.click()}
                className="flex items-center justify-center flex-1 w-[clamp(110px,25vw,200px)] gap-1.5 sm:gap-2 px-2 py-2.5 sm:px-4 sm:py-3 rounded-xl sm:rounded-2xl font-semibold text-[clamp(10px,2vw,12px)] transition-all duration-300 border border-white/10 bg-zinc-900 hover:border-cyan-500/40 text-zinc-300 hover:text-cyan-300 shadow-lg"
                title="Upload or snap a screenshot for Zoya to read immediately"
              >
                <Camera className="w-3.5 h-3.5 sm:w-4 sm:h-4 text-cyan-400 shrink-0" />
                <span className="truncate">Upload Screenshot</span>
              </motion.button>
            </>
          )}

          <motion.button
            whileHover={{ scale: 1.05 }}
            whileTap={{ scale: 0.95 }}
            onClick={handleToggle}
            className={`
              relative w-[clamp(4rem,18vw,5rem)] h-[clamp(4rem,18vw,5rem)] rounded-full flex items-center justify-center transition-all duration-500 shrink-0 mx-auto
              ${status === "connected" 
                ? "bg-zinc-900 border-2 border-pink-500 text-pink-500 shadow-[0_0_30px_rgba(236,72,153,0.3)]" 
                : "bg-white text-black hover:bg-zinc-200 shadow-[0_0_20px_rgba(255,255,255,0.2)]"}
            `}
          >
            {status === "connected" ? (
              <Power className="w-6 h-6 sm:w-8 sm:h-8" />
            ) : status === "connecting" ? (
              <Loader2 className="w-6 h-6 sm:w-8 sm:h-8 animate-spin" />
            ) : (
              <Mic className="w-6 h-6 sm:w-8 sm:h-8" />
            )}
            
            {/* Tooltip-like hint */}
            <div className="absolute -bottom-7 whitespace-nowrap text-[9px] sm:text-[10px] uppercase tracking-widest text-zinc-500 font-bold">
              {status === "connected" ? "Disconnect" : "Start Session"}
            </div>
          </motion.button>
        </div>
      </div>

      {/* Footer Info */}
      <motion.div 
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ delay: 1 }}
        className="absolute bottom-8 text-zinc-600 text-[10px] uppercase tracking-[0.2em] font-medium flex items-center gap-2"
      >
        <span>Powered by Gemini 3.1 Flash Live</span>
        <span>•</span>
        <button 
          onClick={() => setShowAccessibilityModal(true)}
          className="text-pink-400 hover:underline"
        >
          Android Accessibility Active
        </button>
      </motion.div>

      {/* Floating Action Hint */}
      {status === "connected" && (
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          className="absolute bottom-20 flex items-center gap-2 text-zinc-400 text-xs bg-white/5 px-4 py-2 rounded-full border border-white/10 backdrop-blur-sm"
        >
          <Smartphone className="w-3.5 h-3.5 text-pink-400" />
          <span>Try: "{getPersonaName(voicePersona)}, read my screen" or "{getPersonaName(voicePersona)}, open WhatsApp"</span>
        </motion.div>
      )}

      {/* ANDROID ACCESSIBILITY & APP CONTROL SETTINGS MODAL */}
      <AnimatePresence>
        {showAccessibilityModal && (
          <motion.div
            key="accessibility-modal"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="fixed inset-0 z-50 bg-black/80 backdrop-blur-md flex items-center justify-center p-4 overflow-y-auto"
          >
            <motion.div
              initial={{ scale: 0.95, opacity: 0 }}
              animate={{ scale: 1, opacity: 1 }}
              exit={{ scale: 0.95, opacity: 0 }}
              className="bg-zinc-900 border border-white/10 rounded-2xl p-6 w-full max-w-lg space-y-6 relative shadow-2xl max-h-[90vh] overflow-y-auto"
            >
              <button
                onClick={() => setShowAccessibilityModal(false)}
                className="absolute top-4 right-4 text-zinc-400 hover:text-white p-1.5 rounded-lg bg-white/5 hover:bg-white/10 transition-colors"
              >
                <X className="w-5 h-5" />
              </button>

              <div className="flex items-center gap-3 border-b border-white/10 pb-4">
                <div className="p-3 rounded-2xl bg-gradient-to-br from-pink-500/20 to-purple-500/20 border border-pink-500/30 text-pink-400">
                  <Smartphone className="w-6 h-6" />
                </div>
                <div>
                  <h3 className="font-bold text-xl text-white">Android App Control & Accessibility</h3>
                  <p className="text-xs text-zinc-400">Control apps over other apps & automate screen actions</p>
                </div>
              </div>

              {/* Status Banner */}
              <div className="p-4 rounded-xl bg-gradient-to-r from-emerald-500/10 via-pink-500/10 to-purple-500/10 border border-emerald-500/20 flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <ShieldCheck className="w-5 h-5 text-emerald-400" />
                  <div>
                    <p className="text-xs font-semibold text-white">Accessibility Service Engine</p>
                    <p className="text-[11px] text-zinc-400">System Permission Handler Ready</p>
                  </div>
                </div>
                <span className="px-2.5 py-1 rounded-full bg-emerald-500/20 text-emerald-300 text-[10px] font-bold uppercase tracking-wider">
                  Active
                </span>
              </div>

              {/* Permissions & Controls Section */}
              <div className="space-y-4">
                <h4 className="text-xs font-bold uppercase tracking-wider text-zinc-400 flex items-center gap-2">
                  <Sliders className="w-4 h-4 text-pink-400" />
                  <span>Android System Permissions</span>
                </h4>

                {/* Switch 1: Accessibility Service */}
                <div className="p-3.5 rounded-xl bg-black/40 border border-white/5 flex items-start justify-between gap-4">
                  <div className="space-y-1">
                    <div className="flex items-center gap-2">
                      <p className="text-sm font-semibold text-white">Accessibility Service</p>
                      <span className="text-[10px] px-2 py-0.5 rounded bg-pink-500/20 text-pink-300 font-mono">
                        BIND_ACCESSIBILITY_SERVICE
                      </span>
                    </div>
                    <p className="text-xs text-zinc-400">
                      Allows Zoya to read screen elements, trigger clicks, scroll social feeds, and execute cross-app voice commands.
                    </p>
                  </div>
                  <button
                    onClick={() => toggleAccessibilityService(!accessibilityServiceEnabled)}
                    className={`w-12 h-6 rounded-full p-1 transition-colors shrink-0 ${
                      accessibilityServiceEnabled ? "bg-pink-500" : "bg-zinc-700"
                    }`}
                  >
                    <div
                      className={`w-4 h-4 rounded-full bg-white transition-transform ${
                        accessibilityServiceEnabled ? "translate-x-6" : "translate-x-0"
                      }`}
                    />
                  </button>
                </div>

                {/* Switch 2: Display Over Other Apps */}
                <div className="p-3.5 rounded-xl bg-black/40 border border-white/5 flex items-start justify-between gap-4">
                  <div className="space-y-1">
                    <div className="flex items-center gap-2">
                      <p className="text-sm font-semibold text-white">Display Over Other Apps</p>
                      <span className="text-[10px] px-2 py-0.5 rounded bg-blue-500/20 text-blue-300 font-mono">
                        SYSTEM_ALERT_WINDOW
                      </span>
                    </div>
                    <p className="text-xs text-zinc-400">
                      Allows Zoya's floating voice bubble to stay visible over Instagram, WhatsApp, YouTube, and TikTok.
                    </p>
                  </div>
                  <button
                    onClick={() => toggleDisplayOverApps(!displayOverAppsEnabled)}
                    className={`w-12 h-6 rounded-full p-1 transition-colors shrink-0 ${
                      displayOverAppsEnabled ? "bg-pink-500" : "bg-zinc-700"
                    }`}
                  >
                    <div
                      className={`w-4 h-4 rounded-full bg-white transition-transform ${
                        displayOverAppsEnabled ? "translate-x-6" : "translate-x-0"
                      }`}
                    />
                  </button>
                </div>

                {/* Switch 3: Floating Overlay Widget */}
                <div className="p-3.5 rounded-xl bg-black/40 border border-white/5 flex items-start justify-between gap-4">
                  <div className="space-y-1">
                    <p className="text-sm font-semibold text-white">Enable Floating Draggable Bubble</p>
                    <p className="text-xs text-zinc-400">
                      Show persistent floating mic widget on screen to control Zoya while browsing other apps.
                    </p>
                  </div>
                  <button
                    onClick={() => toggleFloatingWidget(!showFloatingWidget)}
                    className={`w-12 h-6 rounded-full p-1 transition-colors shrink-0 ${
                      showFloatingWidget ? "bg-pink-500" : "bg-zinc-700"
                    }`}
                  >
                    <div
                      className={`w-4 h-4 rounded-full bg-white transition-transform ${
                        showFloatingWidget ? "translate-x-6" : "translate-x-0"
                      }`}
                    />
                  </button>
                </div>

                {/* Switch 4: Battery Saver Optimization Exemption */}
                <div className="p-3.5 rounded-xl bg-black/40 border border-white/5 flex items-start justify-between gap-4">
                  <div className="space-y-1">
                    <p className="text-sm font-semibold text-white">Ignore Battery Optimization</p>
                    <p className="text-xs text-zinc-400">
                      Keeps Zoya background worker active for instant voice wake commands without sleeping.
                    </p>
                  </div>
                  <button
                    onClick={() => setBatteryExemptionEnabled(!batteryExemptionEnabled)}
                    className={`w-12 h-6 rounded-full p-1 transition-colors shrink-0 ${
                      batteryExemptionEnabled ? "bg-pink-500" : "bg-zinc-700"
                    }`}
                  >
                    <div
                      className={`w-4 h-4 rounded-full bg-white transition-transform ${
                        batteryExemptionEnabled ? "translate-x-6" : "translate-x-0"
                      }`}
                    />
                  </button>
                </div>

                {/* Switch 5: Real-time Screen Vision & OCR Reader */}
                <div className="p-3.5 rounded-xl bg-black/40 border border-white/5 flex items-start justify-between gap-4">
                  <div className="space-y-1">
                    <div className="flex items-center gap-2">
                      <p className="text-sm font-semibold text-white">Screen Vision & OCR AI Reader</p>
                      <span className="text-[10px] px-2 py-0.5 rounded bg-emerald-500/20 text-emerald-300 font-mono">
                        DISPLAY_CAPTURE
                      </span>
                    </div>
                    <p className="text-xs text-zinc-400">
                      Streams live video frames so Zoya can SEE, READ, and DESCRIBE text, messages, web pages, and photos on your screen.
                    </p>
                  </div>
                  <button
                    onClick={isScreenSharing ? stopScreenShare : startScreenShare}
                    className={`px-3 py-1.5 rounded-lg text-xs font-semibold shrink-0 transition-colors ${
                      isScreenSharing 
                        ? "bg-emerald-500/20 text-emerald-300 border border-emerald-500/40" 
                        : "bg-pink-500/20 text-pink-300 border border-pink-500/30 hover:bg-pink-500/30"
                    }`}
                  >
                    {isScreenSharing ? "Active 👁️" : "Toggle Vision"}
                  </button>
                </div>
              </div>

              {/* Supported Apps Launcher & Test Section */}
              <div className="space-y-3 pt-2">
                <h4 className="text-xs font-bold uppercase tracking-wider text-zinc-400 flex items-center gap-2">
                  <AppWindow className="w-4 h-4 text-purple-400" />
                  <span>Controllable Android Apps</span>
                </h4>
                <div className="grid grid-cols-2 gap-2.5">
                  {getAndroidApps(voicePersona).map((app) => (
                    <button
                      key={app.id}
                      onClick={() => simulateAppLaunch(app)}
                      className="p-3 rounded-xl bg-black/50 border border-white/5 hover:border-pink-500/30 text-left transition-all flex items-center justify-between group"
                    >
                      <div>
                        <div className="flex items-center gap-1.5">
                          <p className="text-xs font-bold text-white group-hover:text-pink-300 transition-colors">{app.name}</p>
                          <ExternalLink className="w-3 h-3 text-zinc-500 opacity-0 group-hover:opacity-100 transition-opacity" />
                        </div>
                        <p className="text-[10px] text-zinc-500">{app.sampleCommand}</p>
                      </div>
                      <span className={`px-2 py-0.5 rounded text-[9px] font-medium border ${app.iconColor}`}>
                        Ready
                      </span>
                    </button>
                  ))}
                </div>
              </div>

              {/* Android Settings Step-by-Step Guide */}
              <div className="p-4 rounded-xl bg-pink-500/5 border border-pink-500/20 space-y-2.5">
                <p className="text-xs font-bold text-pink-300 flex items-center gap-1.5">
                  <Shield className="w-4 h-4" />
                  <span>How to Enable on Android Settings</span>
                </p>
                <ol className="text-xs text-zinc-400 space-y-1.5 list-decimal pl-4">
                  <li>Open phone <strong>Settings</strong> &rarr; <strong>Accessibility</strong>.</li>
                  <li>Tap <strong>Installed Apps / Downloaded Services</strong>.</li>
                  <li>Select <strong>Zoya AI Assistant</strong> & toggle <strong>ON</strong>.</li>
                  <li>Go to <strong>Special App Access</strong> &rarr; <strong>Display Over Other Apps</strong> &rarr; Enable <strong>Zoya</strong>.</li>
                </ol>
              </div>

              <div className="flex justify-end pt-2">
                <button
                  onClick={() => setShowAccessibilityModal(false)}
                  className="px-5 py-2.5 rounded-xl bg-pink-500 hover:bg-pink-600 text-white font-medium text-xs transition-colors flex items-center gap-2 shadow-lg shadow-pink-500/20"
                >
                  <Check className="w-4 h-4" />
                  <span>Apply Settings & Close</span>
                </button>
              </div>
            </motion.div>
          </motion.div>
        )}
      </AnimatePresence>

      {/* API Key Modal */}
      <AnimatePresence>
        {showKeyModal && (
          <motion.div
            key="key-modal"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="fixed inset-0 z-50 bg-black/80 backdrop-blur-md flex items-center justify-center p-4"
          >
            <motion.div
              initial={{ scale: 0.95, opacity: 0 }}
              animate={{ scale: 1, opacity: 1 }}
              exit={{ scale: 0.95, opacity: 0 }}
              className="bg-zinc-900 border border-white/10 rounded-2xl p-6 w-full max-w-md space-y-5 relative shadow-2xl"
            >
              <button
                onClick={() => setShowKeyModal(false)}
                className="absolute top-4 right-4 text-zinc-400 hover:text-white p-1 rounded-lg"
              >
                <X className="w-5 h-5" />
              </button>

              <div className="flex items-center gap-3">
                <div className="p-2.5 rounded-xl bg-pink-500/10 border border-pink-500/20 text-pink-400">
                  <Key className="w-5 h-5" />
                </div>
                <div>
                  <h3 className="font-semibold text-lg text-white">Gemini API Key</h3>
                  <p className="text-xs text-zinc-400">Enter your key to connect with Zoya</p>
                </div>
              </div>

              <div className="space-y-2">
                <label className="text-xs font-medium text-zinc-300">API Key</label>
                <input
                  type="password"
                  value={apiKeyInput}
                  onChange={(e) => setApiKeyInput(e.target.value)}
                  placeholder="Paste AIzaSy... here"
                  className="w-full px-4 py-2.5 rounded-xl bg-black/50 border border-white/10 text-white placeholder:text-zinc-600 focus:outline-none focus:border-pink-500 text-sm font-mono"
                />
                <p className="text-[11px] text-zinc-500">
                  Get a key from <a href="https://aistudio.google.com/app/apikey" target="_blank" rel="noreferrer" className="text-pink-400 underline">Google AI Studio</a>.
                </p>
              </div>

              <div className="flex items-center justify-end gap-2 pt-2">
                {savedKey && (
                  <button
                    onClick={handleClearKey}
                    className="px-4 py-2 rounded-xl text-zinc-400 hover:text-white hover:bg-white/5 text-xs transition-colors"
                  >
                    Clear Key
                  </button>
                )}
                <button
                  onClick={handleSaveKey}
                  disabled={!apiKeyInput.trim()}
                  className="px-5 py-2 rounded-xl bg-pink-500 hover:bg-pink-600 disabled:opacity-50 text-white font-medium text-xs transition-colors flex items-center gap-1.5 shadow-lg shadow-pink-500/20"
                >
                  <Check className="w-4 h-4" />
                  <span>Save & Connect</span>
                </button>
              </div>
            </motion.div>
          </motion.div>
        )}
      </AnimatePresence>

      {/* APK Conversion & Installation Modal */}
      <AnimatePresence>
        {showApkModal && (
          <motion.div
            key="apk-modal"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="fixed inset-0 z-50 bg-black/85 backdrop-blur-md flex items-center justify-center p-4"
          >
            <motion.div
              initial={{ scale: 0.95, opacity: 0 }}
              animate={{ scale: 1, opacity: 1 }}
              exit={{ scale: 0.95, opacity: 0 }}
              className="bg-zinc-900 border border-pink-500/30 rounded-2xl p-6 w-full max-w-lg space-y-6 relative shadow-2xl max-h-[90vh] overflow-y-auto"
            >
              <button
                onClick={() => setShowApkModal(false)}
                className="absolute top-4 right-4 text-zinc-400 hover:text-white p-1 rounded-lg"
              >
                <X className="w-5 h-5" />
              </button>

              <div className="flex items-center gap-3">
                <div className="p-3 rounded-2xl bg-pink-500/20 border border-pink-500/40 text-pink-400">
                  <Package className="w-6 h-6" />
                </div>
                <div>
                  <h3 className="font-bold text-lg text-white">Convert Zoya to Android APK</h3>
                  <p className="text-xs text-zinc-400">3 simple ways to install Zoya natively on your Android device</p>
                </div>
              </div>

              {/* Method 1: WebAPK 1-Tap Install */}
              <div className="p-4 rounded-xl bg-gradient-to-r from-pink-500/10 to-purple-500/10 border border-pink-500/30 space-y-3">
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-2">
                    <span className="w-6 h-6 rounded-full bg-pink-500 text-white text-xs font-bold flex items-center justify-center">1</span>
                    <p className="text-sm font-bold text-white">1-Tap Direct WebAPK Install (Recommended)</p>
                  </div>
                  <span className="text-[10px] uppercase font-mono px-2 py-0.5 rounded bg-emerald-500/20 text-emerald-300 border border-emerald-500/30">
                    Instant
                  </span>
                </div>
                <p className="text-xs text-zinc-300 leading-relaxed">
                  Android Chrome automatically compiles Zoya into a native system <strong>WebAPK</strong> app icon on your phone's app drawer with full screen, screen vision, and microphone access.
                </p>
                <button
                  onClick={handleInstallPWA}
                  className="w-full py-3 rounded-xl bg-gradient-to-r from-pink-500 to-purple-600 hover:from-pink-600 hover:to-purple-700 text-white font-bold text-xs transition-all shadow-lg shadow-pink-500/25 flex items-center justify-center gap-2"
                >
                  <DownloadCloud className="w-4 h-4 animate-bounce" />
                  <span>{isInstalled ? "Zoya App Installed!" : "Install WebAPK on Android Phone"}</span>
                </button>
              </div>

              {/* Method 2: PWABuilder APK Generator */}
              <div className="p-4 rounded-xl bg-black/40 border border-white/10 space-y-3">
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-2">
                    <span className="w-6 h-6 rounded-full bg-zinc-800 text-zinc-300 text-xs font-bold flex items-center justify-center">2</span>
                    <p className="text-sm font-bold text-white">Generate Standalone .APK File (PWABuilder)</p>
                  </div>
                  <span className="text-[10px] uppercase font-mono px-2 py-0.5 rounded bg-cyan-500/20 text-cyan-300 border border-cyan-500/30">
                    Online Tool
                  </span>
                </div>
                <p className="text-xs text-zinc-400 leading-relaxed">
                  Convert this app's URL on Microsoft PWABuilder or Web2APK to download a signed <strong>.apk</strong> file ready to install or publish to Google Play Store.
                </p>
                <a
                  href="https://www.pwabuilder.com"
                  target="_blank"
                  rel="noreferrer"
                  className="w-full py-2.5 rounded-xl bg-zinc-800 hover:bg-zinc-700 text-zinc-200 hover:text-white font-semibold text-xs transition-colors flex items-center justify-center gap-2 border border-white/10"
                >
                  <ExternalLink className="w-3.5 h-3.5 text-cyan-400" />
                  <span>Open PWABuilder.com APK Generator</span>
                </a>
              </div>

              {/* Method 3: Native Capacitor APK Build */}
              <div className="p-4 rounded-xl bg-black/40 border border-white/10 space-y-3">
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-2">
                    <span className="w-6 h-6 rounded-full bg-zinc-800 text-zinc-300 text-xs font-bold flex items-center justify-center">3</span>
                    <p className="text-sm font-bold text-white">Build Native APK via Capacitor (Dev Mode)</p>
                  </div>
                  <span className="text-[10px] uppercase font-mono px-2 py-0.5 rounded bg-purple-500/20 text-purple-300 border border-purple-500/30">
                    Android Studio
                  </span>
                </div>
                <p className="text-xs text-zinc-400">
                  Run these commands in your local terminal to build a native Android Studio `.apk` project:
                </p>
                <div className="p-3 rounded-lg bg-zinc-950 font-mono text-[11px] text-pink-300 space-y-1 overflow-x-auto border border-white/5 select-all">
                  <p>npm run build</p>
                  <p>npx cap add android</p>
                  <p>npx cap open android</p>
                </div>
              </div>

              <div className="flex justify-end pt-2">
                <button
                  onClick={() => setShowApkModal(false)}
                  className="px-5 py-2 rounded-xl bg-zinc-800 hover:bg-zinc-700 text-zinc-300 text-xs font-semibold transition-colors"
                >
                  Close
                </button>
              </div>
            </motion.div>
          </motion.div>
        )}
      </AnimatePresence>

      {/* Memory Modal */}
      {logSaveStatus && (
        <div className="fixed bottom-24 left-1/2 -translate-x-1/2 bg-black/90 border border-amber-500/40 text-amber-200 text-xs px-4 py-2 rounded-full z-50 backdrop-blur-md">
          {logSaveStatus}
        </div>
      )}

      <MemoryModal isOpen={showMemoryModal} onClose={() => setShowMemoryModal(false)} />
      {/* Voice Persona Selection Modal */}
      <VoicePersonaModal
        isOpen={showVoiceModal}
        onClose={() => setShowVoiceModal(false)}
        currentPersona={voicePersona}
        onSelectPersona={setVoicePersona}
      />
    </div>
  );
}

ZOYAFIXEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/bridge/ZoyaBridgePlugin.kt << 'ZOYAFIXEOF'
package com.zoya.ai.assistant.bridge

import android.Manifest
import android.content.Intent
import android.media.AudioManager
import android.media.projection.MediaProjectionManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import com.getcapacitor.annotation.Permission
import com.zoya.ai.assistant.accessibility.NodeFinder
import com.zoya.ai.assistant.camera.CameraController
import com.zoya.ai.assistant.ocr.OCRManager
import com.zoya.ai.assistant.scheduler.TaskScheduler
import com.zoya.ai.assistant.settings.SystemSettingsController
import com.zoya.ai.assistant.storage.LocalStore
import com.zoya.ai.assistant.workflow.Workflow
import com.zoya.ai.assistant.workflow.WorkflowEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * Every method here returns a structured {status, message, data} object to JS — never a bare
 * boolean, and never a fabricated success. See BridgeResult / ResultStatus.
 */
@CapacitorPlugin(
    name = "ZoyaBridge",
    permissions = [
        Permission(strings = [Manifest.permission.CAMERA], alias = "camera"),
        Permission(strings = [Manifest.permission.RECORD_AUDIO], alias = "microphone"),
        Permission(strings = [Manifest.permission.POST_NOTIFICATIONS], alias = "notifications")
    ]
)
class ZoyaBridgePlugin : Plugin() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var engine: AutomationEngine
    private lateinit var appManager: AppManager
    private lateinit var settingsController: SystemSettingsController
    private lateinit var scheduler: TaskScheduler
    private lateinit var store: LocalStore
    private lateinit var camera: CameraController
    private val ocr = OCRManager()
    private var workflowEngine: WorkflowEngine? = null

    override fun load() {
        engine = AutomationEngine(context)
        appManager = AppManager(context)
        settingsController = SystemSettingsController(context)
        scheduler = TaskScheduler(context)
        store = LocalStore(context)
        camera = CameraController(context)
    }

    private fun PluginCall.reply(result: BridgeResult) {
        val obj = JSObject()
        val json = result.toJson()
        json.keys().forEach { key -> obj.put(key, json.get(key)) }
        resolve(obj)
    }

    // ---------- Permissions ----------

    @PluginMethod
    fun requestPermission(call: PluginCall) {
        when (call.getString("permission")) {
            "camera" -> requestPermissionForAlias("camera", call, "cameraPermsCallback")
            "microphone" -> requestPermissionForAlias("microphone", call, "micPermsCallback")
            "notifications" -> requestPermissionForAlias("notifications", call, "notifPermsCallback")
            "accessibility" -> {
                context.startActivity(
                    Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
                call.reply(BridgeResult.success("Opened Accessibility settings; user must enable manually"))
            }
            else -> call.reply(BridgeResult.unsupported("Unknown permission key"))
        }
    }

    @com.getcapacitor.annotation.PermissionCallback
    private fun cameraPermsCallback(call: PluginCall) = call.reply(
        if (getPermissionState("camera") == com.getcapacitor.PermissionState.GRANTED)
            BridgeResult.success("camera granted") else BridgeResult.permissionRequired("CAMERA")
    )

    @com.getcapacitor.annotation.PermissionCallback
    private fun micPermsCallback(call: PluginCall) = call.reply(
        if (getPermissionState("microphone") == com.getcapacitor.PermissionState.GRANTED)
            BridgeResult.success("microphone granted") else BridgeResult.permissionRequired("RECORD_AUDIO")
    )

    @com.getcapacitor.annotation.PermissionCallback
    private fun notifPermsCallback(call: PluginCall) = call.reply(
        if (getPermissionState("notifications") == com.getcapacitor.PermissionState.GRANTED)
            BridgeResult.success("notifications granted") else BridgeResult.permissionRequired("POST_NOTIFICATIONS")
    )

    @PluginMethod
    fun getPermissionStatus(call: PluginCall) {
        val result = JSObject()
        result.put("camera", getPermissionState("camera").toString())
        result.put("microphone", getPermissionState("microphone").toString())
        result.put("notifications", getPermissionState("notifications").toString())
        result.put("accessibility", engine.isAccessibilityEnabled())
        call.resolve(result)
    }

    // ---------- App management ----------

    @PluginMethod
    fun launchApp(call: PluginCall) {
        val pkg = call.getString("packageName") ?: return call.reply(BridgeResult.failure("packageName is required"))
        call.reply(appManager.launchApp(pkg))
    }

    @PluginMethod
    fun getInstalledApps(call: PluginCall) = call.reply(appManager.getInstalledApps(call.getString("query")))

    @PluginMethod
    fun getCurrentApp(call: PluginCall) = call.reply(appManager.getCurrentApp())

    // ---------- Gestures / UI interaction ----------

    @PluginMethod
    fun tap(call: PluginCall) {
        val x = call.getFloat("x") ?: return call.reply(BridgeResult.failure("x is required"))
        val y = call.getFloat("y") ?: return call.reply(BridgeResult.failure("y is required"))
        scope.launch { call.reply(engine.tap(x, y)) }
    }

    @PluginMethod
    fun longPress(call: PluginCall) {
        val x = call.getFloat("x") ?: return call.reply(BridgeResult.failure("x is required"))
        val y = call.getFloat("y") ?: return call.reply(BridgeResult.failure("y is required"))
        val duration = call.getLong("durationMs") ?: 700L
        val service = com.zoya.ai.assistant.accessibility.ZoyaAccessibilityService.instance
            ?: return call.reply(BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE"))
        scope.launch {
            val ok = service.gestures.longPress(x, y, duration)
            call.reply(if (ok) BridgeResult.success() else BridgeResult.failure("Gesture rejected"))
        }
    }

    @PluginMethod
    fun swipe(call: PluginCall) {
        val x1 = call.getFloat("x1") ?: return call.reply(BridgeResult.failure("x1 is required"))
        val y1 = call.getFloat("y1") ?: return call.reply(BridgeResult.failure("y1 is required"))
        val x2 = call.getFloat("x2") ?: return call.reply(BridgeResult.failure("x2 is required"))
        val y2 = call.getFloat("y2") ?: return call.reply(BridgeResult.failure("y2 is required"))
        val duration = call.getLong("durationMs") ?: 300L
        scope.launch { call.reply(engine.swipe(x1, y1, x2, y2, duration)) }
    }

    @PluginMethod
    fun scroll(call: PluginCall) {
        val forward = call.getBoolean("forward") ?: true
        val selector = selectorFromCall(call)
        scope.launch {
            call.reply(engine.findAndAct(selector, { node ->
                com.zoya.ai.assistant.accessibility.ZoyaAccessibilityService.instance?.performScroll(node, forward) ?: false
            }))
        }
    }

    @PluginMethod
    fun gesture(call: PluginCall) {
        // Generic multi-point path gesture, e.g. for replaying a recorded gesture.
        val pointsArr = call.getArray("points") ?: return call.reply(BridgeResult.failure("points array is required"))
        val duration = call.getLong("durationMs") ?: 300L
        val service = com.zoya.ai.assistant.accessibility.ZoyaAccessibilityService.instance
            ?: return call.reply(BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE"))
        val points = mutableListOf<Pair<Float, Float>>()
        for (i in 0 until pointsArr.length()) {
            val p = pointsArr.getJSONObject(i)
            points.add(Pair(p.getDouble("x").toFloat(), p.getDouble("y").toFloat()))
        }
        scope.launch {
            val ok = service.gestures.customPath(points, duration)
            call.reply(if (ok) BridgeResult.success() else BridgeResult.failure("Gesture rejected"))
        }
    }

    @PluginMethod
    fun typeText(call: PluginCall) {
        val text = call.getString("text") ?: return call.reply(BridgeResult.failure("text is required"))
        val selector = selectorFromCall(call)
        scope.launch { call.reply(engine.typeText(selector, text)) }
    }

    @PluginMethod
    fun readScreen(call: PluginCall) = call.reply(engine.readScreen())

    @PluginMethod
    fun findUIElement(call: PluginCall) = call.reply(engine.findElement(selectorFromCall(call)))

    @PluginMethod
    fun pressBack(call: PluginCall) = call.reply(engine.pressBack())

    @PluginMethod
    fun pressHome(call: PluginCall) = call.reply(engine.pressHome())

    private fun selectorFromCall(call: PluginCall): NodeFinder.Selector = NodeFinder.Selector(
        text = call.getString("text"),
        partialText = call.getString("partialText"),
        regex = call.getString("regex")?.let { Regex(it) },
        contentDescription = call.getString("contentDescription"),
        resourceId = call.getString("resourceId"),
        className = call.getString("className")
    )

    // ---------- Settings / device controls ----------

    @PluginMethod
    fun openSettings(call: PluginCall) {
        val screen = call.getString("screen") ?: return call.reply(BridgeResult.failure("screen is required"))
        call.reply(settingsController.open(screen))
    }

    @PluginMethod
    fun setBrightness(call: PluginCall) {
        val value = call.getInt("value") ?: return call.reply(BridgeResult.failure("value is required"))
        call.reply(settingsController.setBrightness(value))
    }

    @PluginMethod
    fun setVolume(call: PluginCall) {
        val value = call.getInt("value") ?: return call.reply(BridgeResult.failure("value is required"))
        val stream = when (call.getString("stream")) {
            "ring" -> AudioManager.STREAM_RING
            "notification" -> AudioManager.STREAM_NOTIFICATION
            "alarm" -> AudioManager.STREAM_ALARM
            else -> AudioManager.STREAM_MUSIC
        }
        call.reply(settingsController.setVolume(stream, value))
    }

    // ---------- Camera ----------

    @PluginMethod
    fun takePhoto(call: PluginCall) {
        if (getPermissionState("camera") != com.getcapacitor.PermissionState.GRANTED) {
            return call.reply(BridgeResult.permissionRequired("CAMERA"))
        }
        val activity = activity ?: return call.reply(BridgeResult.failure("No active activity"))
        val useFront = call.getBoolean("front") ?: false
        scope.launch {
            val bindResult = camera.bind(activity as androidx.lifecycle.LifecycleOwner, useFront)
            if (bindResult.status != ResultStatus.SUCCESS) return@launch call.reply(bindResult)
            call.reply(camera.takePhoto())
        }
    }

    // ---------- Screen capture / OCR ----------

    @PluginMethod
    fun captureScreen(call: PluginCall) {
        val mgr = context.getSystemService(android.content.Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val activity = activity ?: return call.reply(BridgeResult.failure("No active activity"))
        // Requesting MediaProjection requires a startActivityForResult flow; wire this to your
        // MainActivity's onActivityResult and forward the resultCode/data Intent into
        // ScreenCaptureService (EXTRA_RESULT_CODE / EXTRA_DATA) before calling captureFrame().
        activity.startActivityForResult(mgr.createScreenCaptureIntent(), SCREEN_CAPTURE_REQUEST)
        call.reply(BridgeResult.success("Screen capture consent dialog shown"))
    }

    @PluginMethod
    fun performOCR(call: PluginCall) {
        // Expects a bitmap to already have been captured via captureScreen(); left as an
        // extension point wiring ScreenCaptureService.captureFrame() -> OCRManager.recognize().
        call.reply(BridgeResult.unsupported("Call captureScreen() first, then performOCR() reads that frame"))
    }

    // ---------- Workflow / automation control ----------

    @PluginMethod
    fun startAutomation(call: PluginCall) {
        val workflowJson = call.data.optJSONObject("workflow")
            ?: return call.reply(BridgeResult.failure("workflow object is required"))
        val workflow = Workflow.fromJson(workflowJson)
        store.upsert(LocalStore.WORKFLOWS, "id", workflowJson)
        val wfEngine = WorkflowEngine(engine)
        workflowEngine = wfEngine
        scope.launch {
            val result = wfEngine.run(workflow) { status ->
                notifyListeners("automationStatus", JSObject().apply {
                    put("type", status.optString("type"))
                    put("action", status.optString("action"))
                    put("status", status.optString("status"))
                    put("message", status.optString("message"))
                })
            }
            store.appendHistory(JSONObject().apply {
                put("workflowId", workflow.id)
                put("status", result.status.name.lowercase())
                put("message", result.message)
                put("timestamp", System.currentTimeMillis())
            })
            call.reply(result)
        }
    }

    @PluginMethod
    fun stopAutomation(call: PluginCall) {
        workflowEngine?.cancel()
        call.reply(BridgeResult.success("Automation stop requested"))
    }

    @PluginMethod
    fun getAutomationStatus(call: PluginCall) {
        val obj = JSObject()
        obj.put("running", workflowEngine != null)
        obj.put("accessibilityEnabled", engine.isAccessibilityEnabled())
        call.resolve(obj)
    }

    @PluginMethod
    fun scheduleTask(call: PluginCall) {
        val workflowId = call.getString("workflowId") ?: return call.reply(BridgeResult.failure("workflowId is required"))
        val kind = call.getString("kind") ?: "one_time"
        val taskId = if (kind == "recurring") {
            scheduler.scheduleRecurring(workflowId, call.getInt("intervalMinutes")?.toLong() ?: 60L)
        } else {
            scheduler.scheduleOneTime(workflowId, call.getInt("delayMs")?.toLong() ?: 0L)
        }
        call.reply(BridgeResult.success("Scheduled", JSONObject().put("taskId", taskId)))
    }

    @PluginMethod
    fun getExecutionLogs(call: PluginCall) {
        val logs = store.readAll(LocalStore.EXECUTION_HISTORY)
        val obj = JSObject()
        obj.put("logs", logs)
        call.resolve(obj)
    }

    // ---------- Debug log export ----------

    @PluginMethod
    fun saveDebugLog(call: PluginCall) {
        val content = call.getString("content") ?: return call.reply(BridgeResult.failure("content is required"))
        val filename = call.getString("filename") ?: "zoya_debug_log_${System.currentTimeMillis()}.txt"
        try {
            val values = android.content.ContentValues().apply {
                put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, filename)
                put(android.provider.MediaStore.MediaColumns.MIME_TYPE, "text/plain")
                put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, "Download")
            }
            val uri = context.contentResolver.insert(
                android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, values
            )
            if (uri == null) {
                return call.reply(BridgeResult.failure("Could not create file in Downloads"))
            }
            context.contentResolver.openOutputStream(uri)?.use { out ->
                out.write(content.toByteArray(Charsets.UTF_8))
            }
            call.reply(BridgeResult.success("Saved", JSONObject().put("uri", uri.toString()).put("filename", filename)))
        } catch (e: Exception) {
            call.reply(BridgeResult.failure("Failed to save log: ${e.message}"))
        }
    }

    companion object {
        const val SCREEN_CAPTURE_REQUEST = 9821
    }
}

ZOYAFIXEOF

echo ""
echo "== Files updated. Reviewing git status =="
git status
echo ""
echo "Now run:  git add . && git commit -m \"Fix mic error handling, add debug log export\" && git push"
