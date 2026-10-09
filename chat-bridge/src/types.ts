import type { OAuthHelpers } from '@cloudflare/workers-oauth-provider';
export interface Env {
  OAUTH_PROVIDER?: OAuthHelpers;
  PUBLIC_ORIGIN: string;
  DB: D1Database;
  OAUTH_KV: KVNamespace;
  OWNER_GITHUB_LOGIN: string;
  GITHUB_CLIENT_ID: string;
  GITHUB_CLIENT_SECRET: string;
  CALLBACK_HOSTS: string;
  SUBSCRIPTION_TTL_SECONDS: string;
}
export interface Principal { userId: string; login: string; clientId?: string }
export interface Anchor {
  bookID: string; chapterID: string; paragraph: number; utf16Offset?: number;
  href?: string; pdfPage?: number; quote?: string;
}
export interface Excerpt { id: string; text: string; title: string; anchor: Anchor }
export interface Message {
  id: string; sessionId: string; characterId: string; characterName: string;
  persona: string; text: string; excerpts: Excerpt[];
}
export interface StoredRequest {
  owner: string; id: string; session_id: string; character_id: string;
  text: string; excerpts_json: string; created_at: string;
}
export interface Subscription {
  id: string; owner: string; session_id: string; character_id: string;
  callback_url: string; secret: string; expires_at: string; active: number;
  oauth_client_id?: string; verified_at?: string; previous_secret?: string; rotation_until?: string;
}
export class BridgeError extends Error {
  constructor(public status: number, message: string) { super(message); }
}
export class CallbackEndpointError extends BridgeError {
  constructor(public reason: 'challenge_failed' | 'timeout' | 'unreachable') { super(502, '回调验证失败：' + reason); }
}
export function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: {
    'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  } });
}
export function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new BridgeError(400, '需要 JSON 对象。');
  return value as Record<string, unknown>;
}
export function string(value: unknown, label: string, max = 128): string {
  if (typeof value !== 'string' || !value.trim() || value.length > max) throw new BridgeError(400, label + '无效。');
  return value;
}
export function id(value: unknown, label = 'ID'): string {
  const result = string(value, label);
  if (!/^[a-zA-Z0-9_.:-]+$/.test(result)) throw new BridgeError(400, label + '格式无效。');
  return result;
}
export function integer(value: unknown, label: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) throw new BridgeError(400, label + '无效。');
  return value as number;
}
export async function body(request: Request): Promise<Record<string, unknown>> {
  if (Number(request.headers.get('content-length')) > 262144) throw new BridgeError(413, '消息太大。');
  const reader = request.body?.getReader();
  if (!reader) throw new BridgeError(400, '消息为空。');
  const chunks: Uint8Array[] = []; let size = 0;
  while (true) {
    const chunk = await reader.read(); if (chunk.done) break;
    size += chunk.value.byteLength;
    if (size > 262144) { await reader.cancel(); throw new BridgeError(413, '消息太大。'); }
    chunks.push(chunk.value);
  }
  const data = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { data.set(chunk, offset); offset += chunk.length; }
  try { return object(JSON.parse(new TextDecoder().decode(data))); }
  catch (error) { if (error instanceof BridgeError) throw error; throw new BridgeError(400, 'JSON 无法解析。'); }
}
export function validateMessage(value: Record<string, unknown>): Message {
  const excerpts = value.excerpts ?? [];
  if (!Array.isArray(excerpts) || excerpts.length > 20) throw new BridgeError(400, '最多共享 20 条书摘。');
  const seen = new Set<string>();
  const shared = excerpts.map(entry => {
    const e = object(entry), a = object(e.anchor), key = id(e.id, '出处 ID');
    if (seen.has(key)) throw new BridgeError(400, '出处 ID 重复。'); seen.add(key);
    const anchor: Anchor = {
      bookID: id(a.bookID, '书籍 ID'), chapterID: id(a.chapterID, '章节 ID'),
      paragraph: integer(a.paragraph, '段落'), utf16Offset: integer(a.utf16Offset ?? 0, '文字偏移'),
    };
    if (a.pdfPage != null) anchor.pdfPage = integer(a.pdfPage, 'PDF 页码');
    if (a.href != null) anchor.href = string(a.href, '章节路径', 2000);
    if (a.quote != null) anchor.quote = string(a.quote, '引用原文', 16000);
    return { id: key, text: string(e.text, '书摘', 16000), title: string(e.title, '书名', 500), anchor };
  });
  return {
    id: id(value.id, '请求 ID'), sessionId: id(value.sessionId, '会话 ID'),
    characterId: id(value.characterId, '角色 ID'), characterName: string(value.characterName, '角色名', 100),
    persona: string(value.persona, '角色设定', 4000), text: string(value.text, '问题', 16000), excerpts: shared,
  };
}
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value && typeof value === 'object') return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical((value as Record<string, unknown>)[key])).join(',') + '}';
  return JSON.stringify(value);
}
export async function digest(value: string): Promise<string> {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return Array.from(new Uint8Array(bytes)).map(b => b.toString(16).padStart(2, '0')).join('');
}
