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

