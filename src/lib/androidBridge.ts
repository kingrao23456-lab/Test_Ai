// Thin, typed wrapper over the native "ZoyaBridge" Capacitor plugin.
// Import this from the existing web app instead of calling Capacitor.Plugins directly,
// so every native call has a consistent shape and works safely in a plain browser too
// (falls back to "unsupported" instead of throwing, per the PRD's browser-fallback rule).

import { Capacitor, registerPlugin } from '@capacitor/core';

export type BridgeStatus = 'success' | 'failure' | 'permission_required' | 'timeout' | 'unsupported';

export interface BridgeResult<T = any> {
  status: BridgeStatus;
  message: string;
  data: T;
}

interface ZoyaBridgePlugin {
  requestPermission(options: { permission: string }): Promise<BridgeResult>;
  getPermissionStatus(): Promise<Record<string, any>>;
  launchApp(options: { packageName: string }): Promise<BridgeResult>;
  getInstalledApps(options?: { query?: string }): Promise<BridgeResult>;
  getCurrentApp(): Promise<BridgeResult>;
  tap(options: { x: number; y: number }): Promise<BridgeResult>;
  longPress(options: { x: number; y: number; durationMs?: number }): Promise<BridgeResult>;
  swipe(options: { x1: number; y1: number; x2: number; y2: number; durationMs?: number }): Promise<BridgeResult>;
  scroll(options: { forward?: boolean; resourceId?: string; text?: string }): Promise<BridgeResult>;
  gesture(options: { points: { x: number; y: number }[]; durationMs?: number }): Promise<BridgeResult>;
  readScreen(): Promise<BridgeResult>;
  captureScreen(): Promise<BridgeResult>;
  performOCR(): Promise<BridgeResult>;
  findUIElement(options: {
    text?: string; partialText?: string; regex?: string; contentDescription?: string; resourceId?: string; className?: string;
  }): Promise<BridgeResult>;
  typeText(options: { text: string; resourceId?: string; targetText?: string }): Promise<BridgeResult>;
  pressBack(): Promise<BridgeResult>;
  pressHome(): Promise<BridgeResult>;
  openSettings(options: { screen: string }): Promise<BridgeResult>;
  setBrightness(options: { value: number }): Promise<BridgeResult>;
  setVolume(options: { value: number; stream?: string }): Promise<BridgeResult>;
  takePhoto(options?: { front?: boolean }): Promise<BridgeResult>;
  startAutomation(options: { workflow: any }): Promise<BridgeResult>;
  stopAutomation(): Promise<BridgeResult>;
  getAutomationStatus(): Promise<{ running: boolean; accessibilityEnabled: boolean }>;
  scheduleTask(options: { workflowId: string; kind?: 'one_time' | 'recurring'; delayMs?: number; intervalMinutes?: number }): Promise<BridgeResult>;
  getExecutionLogs(): Promise<{ logs: any[] }>;
  addListener(eventName: 'automationStatus', listenerFunc: (data: any) => void): Promise<{ remove: () => void }>;
}

const isNative = Capacitor.isNativePlatform();

const ZoyaBridgeNative = isNative ? registerPlugin<ZoyaBridgePlugin>('ZoyaBridge') : null;

function unsupported(message: string): BridgeResult {
  return { status: 'unsupported', message, data: {} };
}

/**
 * Safe wrapper: on a real Android build this calls into Kotlin; in a plain browser
 * (or during `npm run dev`) every call resolves to a structured "unsupported" result
 * instead of throwing, so the existing web UI keeps working unmodified.
 */
export const androidBridge = {
  isAvailable: () => isNative && !!ZoyaBridgeNative,

  requestPermission: (permission: string) =>
    ZoyaBridgeNative?.requestPermission({ permission }) ?? Promise.resolve(unsupported('Not running on Android')),

  getPermissionStatus: () =>
    ZoyaBridgeNative?.getPermissionStatus() ?? Promise.resolve({}),

  tap: (x: number, y: number) =>
    ZoyaBridgeNative?.tap({ x, y }) ?? Promise.resolve(unsupported('Not running on Android')),

  swipe: (x1: number, y1: number, x2: number, y2: number, durationMs = 300) =>
    ZoyaBridgeNative?.swipe({ x1, y1, x2, y2, durationMs }) ?? Promise.resolve(unsupported('Not running on Android')),

  readScreen: () => ZoyaBridgeNative?.readScreen() ?? Promise.resolve(unsupported('Not running on Android')),

  findUIElement: (selector: Parameters<ZoyaBridgePlugin['findUIElement']>[0]) =>
    ZoyaBridgeNative?.findUIElement(selector) ?? Promise.resolve(unsupported('Not running on Android')),

  typeText: (text: string, target?: { resourceId?: string; targetText?: string }) =>
    ZoyaBridgeNative?.typeText({ text, ...target }) ?? Promise.resolve(unsupported('Not running on Android')),

  launchApp: (packageName: string) =>
    ZoyaBridgeNative?.launchApp({ packageName }) ?? Promise.resolve(unsupported('Not running on Android')),

  getInstalledApps: (query?: string) =>
    ZoyaBridgeNative?.getInstalledApps({ query }) ?? Promise.resolve(unsupported('Not running on Android')),

  openSettings: (screen: string) =>
    ZoyaBridgeNative?.openSettings({ screen }) ?? Promise.resolve(unsupported('Not running on Android')),

  startAutomation: (workflow: any) =>
    ZoyaBridgeNative?.startAutomation({ workflow }) ?? Promise.resolve(unsupported('Not running on Android')),

  stopAutomation: () =>
    ZoyaBridgeNative?.stopAutomation() ?? Promise.resolve(unsupported('Not running on Android')),

  getAutomationStatus: () =>
    ZoyaBridgeNative?.getAutomationStatus() ?? Promise.resolve({ running: false, accessibilityEnabled: false }),

  onAutomationStatus: (callback: (data: any) => void) =>
    ZoyaBridgeNative?.addListener('automationStatus', callback) ?? Promise.resolve({ remove: () => {} }),
};
