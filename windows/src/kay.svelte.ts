// What the window knows of Kay: a snapshot of its status and the history, read again whenever Kay says either
// changed. Kay owns all of it; the window only asks for changes (`call`).

import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import zh from './strings.zh.json';

export type Provider = 'qwen' | 'doubao';
export type Pane = 'dictations' | 'general' | 'speech' | 'correction';

export type Status =
  | { kind: 'notSet' | 'saved' | 'testing' }
  | { kind: 'connected'; ms: number }
  | { kind: 'failed'; message: string };

export interface KeyState {
  status: Status;
  maskedKey: string | null;
  candidateError: string | null;
}

export interface ProviderState extends KeyState {
  provider: Provider;
  hasKey: boolean;
  setting: string;
}

export interface Settings {
  triggers: number[];
  microphone: string;
  showInClipboardHistory: boolean;
  pauseMedia: boolean;
  correction: boolean;
  trayIcon: boolean;
  windowAtLaunch: boolean;
}

export interface Snapshot {
  chinese: boolean;
  version: string;
  state: 'idle' | 'recording' | 'processing';
  ready: boolean;
  microphoneAllowed: boolean;
  triggers: [number, string][];
  provider: Provider;
  providers: ProviderState[];
  correction: KeyState;
  settings: Settings;
  launchAtLogin: boolean;
}

export interface Entry {
  id: string;
  date: string;
  text: string;
  audioSeconds: number;
  latencyMs?: number;
  error?: string;
  engine: string;
  microphone?: string;
  heard?: string;
  correctionMs?: number;
}

export const kay = $state({ snapshot: null as unknown as Snapshot, history: [] as Entry[] });

export const call = <T = void>(command: string, args?: Record<string, unknown>) => invoke<T>(command, args);

export async function refresh() {
  kay.snapshot = await call<Snapshot>('snapshot');
}

/// Loads both, then keeps them current. Coming back to the window re-reads the status: the microphone permission
/// changes in Windows Settings, which says nothing.
export async function connect() {
  await Promise.all([refresh(), call<Entry[]>('history').then((h) => (kay.history = h))]);
  chinese = kay.snapshot.chinese;
  document.documentElement.lang = chinese ? 'zh-CN' : 'en';
  listen('changed', refresh);
  listen('history', async () => (kay.history = await call<Entry[]>('history')));
  window.addEventListener('focus', refresh);
}

export const settings = (patch: Partial<Settings>) => call('update_settings', { patch });
export const openURL = (url: string) => call('open_url', { url });
export const providerState = (p: Provider) => kay.snapshot.providers.find((s) => s.provider === p)!;

let chinese = false;

/// English, or Chinese from the table Kay's own messages use; each `{}` takes the next value.
export function t(english: string, ...values: (string | number)[]): string {
  let text = chinese ? ((zh as Record<string, string>)[english] ?? english) : english;
  for (const value of values) text = text.replace('{}', String(value));
  return text;
}

/// For the HUD, which needs the language and nothing else.
export async function loadLanguage() {
  chinese = (await call<Snapshot>('snapshot')).chinese;
}

/// "Right Alt or Left Ctrl", for sentences such as "Hold {} to Dictate".
export const triggerNames = () =>
  kay.snapshot.triggers.map(([, name]) => name).join(chinese ? ' 或 ' : ' or ');

export const providers: Record<
  Provider,
  { name: string; short: string; model: string; console: string; consoleURL: string; keysURL: string; prompt: string; hint: string; revoke: string }
> = {
  qwen: {
    name: 'Alibaba Qwen ASR',
    short: 'Qwen',
    model: 'Qwen Audio 3.1 · streaming',
    console: 'Alibaba Cloud Console',
    consoleURL: 'https://bailian.console.aliyun.com/',
    keysURL: 'https://bailian.console.aliyun.com/?tab=model#/api-key',
    prompt: 'Paste your Alibaba Cloud API Key',
    hint: 'Alibaba Cloud Model Studio → API Key. Use the key and URL for the same workspace.',
    revoke: 'It stays valid in Alibaba Cloud. If it was exposed, revoke it in the console.',
  },
  doubao: {
    name: 'Volcengine Doubao ASR',
    short: 'Doubao',
    model: 'Streaming ASR 2.0 · sentence mode',
    console: 'Volcengine Console',
    consoleURL: 'https://console.volcengine.com/speech/new/overview',
    keysURL: 'https://console.volcengine.com/speech/new/setting/apikeys',
    prompt: 'Paste your Volcengine API Key',
    hint: 'Volcengine console → Doubao Speech → API Key (new console).',
    revoke: 'It stays valid in Volcengine. If it was exposed, revoke it in the console.',
  },
};

export const doubaoResources = [
  ['volc.seedasr.sauc.duration', 'Hourly'],
  ['volc.seedasr.sauc.concurrent', 'Concurrent'],
] as const;

export const DEFAULT_WORKSPACE_URL = 'https://dashscope.aliyuncs.com';

export function statusSummary(state: KeyState, provider: Provider): string {
  const s = state.status;
  switch (s.kind) {
    case 'notSet':
      return t('Add an API key for {}.', t(providers[provider].name));
    case 'saved':
      return t('Key saved ({}).', state.maskedKey ?? '');
    case 'testing':
      return t('Testing…');
    case 'connected':
      return t('Connected · {} ms', s.ms);
    case 'failed':
      return s.message;
  }
}

export const isUsable = (s: Status) => s.kind === 'saved' || s.kind === 'connected';
