import { Webhook } from 'standardwebhooks';
import { timingSafeEqual } from 'node:crypto';
import { BridgeError, CallbackEndpointError, canonical, digest, id, object, string, type Env, type Principal, type StoredRequest, type Subscription } from './types';

export const eventDefinition = {
  name: 'message.created', description: '用户在页间向指定角色发送了一条消息。按用户在 Work 对话中设置的角色及回传要求处理。',
  delivery: ['webhook'],
  inputSchema: { type: 'object', properties: { session_id: { type: 'string' }, character_id: { type: 'string' } }, required: ['session_id', 'character_id'], additionalProperties: false },
  payloadSchema: { type: 'object', properties: { request_id: { type: 'string' }, session_id: { type: 'string' }, character_id: { type: 'string' }, text: { type: 'string' }, url: { type: 'string' } }, required: ['request_id', 'session_id', 'character_id', 'text', 'url'], additionalProperties: false },
};

export function callbackURL(value: unknown, env: Env): URL {
  let url: URL;
  try { url = new URL(string(value, '回调网址', 4096)); } catch { throw new BridgeError(400, '回调网址无效。'); }
  const allowed = env.CALLBACK_HOSTS.split(',').map(h => h.trim().toLowerCase()).filter(Boolean);
  const host = url.hostname.toLowerCase();
  if (url.protocol !== 'https:' || url.username || url.password || url.hash || (url.port && url.port !== '443') ||
      !allowed.some(root => host === root || host.endsWith('.' + root))) {
    throw new BridgeError(400, '回调主机不在批准范围内：' + host);
  }
  return url;
}
function signedHeaders(subscription: Pick<Subscription, 'secret' | 'id' | 'previous_secret' | 'rotation_until'>, eventID: string, bytes: string): HeadersInit {
  const now = new Date();
  let signature = new Webhook(subscription.secret).sign(eventID, now, bytes);
  if (subscription.previous_secret && subscription.rotation_until && Date.parse(subscription.rotation_until) > Date.now()) signature += ' ' + new Webhook(subscription.previous_secret).sign(eventID, now, bytes);
  return { 'Content-Type': 'application/json', 'webhook-id': eventID,
    'webhook-timestamp': String(Math.floor(now.getTime() / 1000)),
    'webhook-signature': signature,
    'X-MCP-Subscription-Id': subscription.id };
}
export async function subscribe(env: Env, principal: Principal, params: Record<string, unknown>, origin: string, send: typeof fetch = fetch) {
  if (params.name !== eventDefinition.name) throw new BridgeError(400, '未知事件。');
  const args = object(params.arguments), delivery = object(params.delivery);
  const session = id(args.session_id), character = id(args.character_id);
  const known = await env.DB.prepare('SELECT character_id FROM sessions WHERE owner=? AND id=?').bind(principal.userId, session).first<{character_id: string}>();
  if (!known || known.character_id !== character) throw new BridgeError(404, '先在 App 创建该角色会话，再订阅事件。');
  if (delivery.mode !== 'webhook') throw new BridgeError(400, '仅支持 webhook。');
  const url = callbackURL(delivery.url, env), secret = string(delivery.secret, '签名密钥', 256);
  try {
    if (!secret.startsWith('whsec_')) throw new Error();
    const length = atob(secret.slice(6)).length; if (length < 24 || length > 64) throw new Error();
    new Webhook(secret);
  } catch { throw new BridgeError(400, '签名密钥格式无效。'); }
  const subscriptionId = 'sub_' + (await digest(canonical([principal.userId, url.href, params.name, session, character]))).slice(0,40);
  const previous = await env.DB.prepare('SELECT * FROM subscriptions WHERE id=?').bind(subscriptionId).first<Subscription>();
  let verifiedAt = previous?.verified_at ?? null;
  if (!previous?.verified_at || previous.secret !== secret || Date.parse(previous.verified_at) < Date.now() - 15 * 60000) {
    const challenge = crypto.randomUUID(), eventID = 'verify_' + crypto.randomUUID(), bytes = JSON.stringify({ type: 'verification', challenge });
    try {
      const verified = await send(url, { method: 'POST', body: bytes, headers: signedHeaders({ id: subscriptionId, secret }, eventID, bytes), redirect: 'error', signal: AbortSignal.timeout(10000) });
      const echoed = (await verified.json() as {challenge?: unknown}).challenge;
      if (!verified.ok || typeof echoed !== 'string' || echoed.length !== challenge.length || !timingSafeEqual(new TextEncoder().encode(echoed), new TextEncoder().encode(challenge))) throw new CallbackEndpointError('challenge_failed');
      verifiedAt = new Date().toISOString();
    } catch (error) {
      if (error instanceof CallbackEndpointError) throw error;
      throw new CallbackEndpointError(error instanceof Error && error.name === 'TimeoutError' ? 'timeout' : 'unreachable');
    }
  }
  const configured = Math.max(60, Math.min(86400, Number(env.SUBSCRIPTION_TTL_SECONDS) || 86400));
  const requested = params.ttlMs == null ? configured : Number(params.ttlMs) / 1000;
  if (!Number.isFinite(requested) || requested <= 0) throw new BridgeError(400, '订阅时长无效。');
  const expires = new Date(Date.now() + Math.min(configured, requested) * 1000).toISOString();
  const rotated = previous && previous.secret !== secret;
  await env.DB.prepare('INSERT INTO subscriptions(id,owner,session_id,character_id,callback_url,secret,expires_at,active,oauth_client_id,verified_at,previous_secret,rotation_until) VALUES(?,?,?,?,?,?,?,1,?,?,?,?) ON CONFLICT(id) DO UPDATE SET secret=excluded.secret,expires_at=excluded.expires_at,active=1,oauth_client_id=excluded.oauth_client_id,verified_at=excluded.verified_at,previous_secret=excluded.previous_secret,rotation_until=excluded.rotation_until')
    .bind(subscriptionId, principal.userId, session, character, url.href, secret, expires, principal.clientId ?? null, verifiedAt, rotated ? previous.secret : previous?.previous_secret ?? null, rotated ? new Date(Date.now() + 5 * 60000).toISOString() : previous?.rotation_until ?? null).run();
  // Queue previously unsent messages as well; creating a subscription must not lose the first question.
  await env.DB.prepare('INSERT OR IGNORE INTO deliveries(subscription_id,request_id,owner,next_attempt_at) SELECT ?,r.id,r.owner,? FROM requests r WHERE r.owner=? AND r.session_id=? AND r.character_id=? AND NOT EXISTS(SELECT 1 FROM results x WHERE x.owner=r.owner AND x.request_id=r.id AND x.kind=\'reply\')')
    .bind(subscriptionId, new Date().toISOString(), principal.userId, session, character).run();
  await flushDeliveries(env, origin, send);
  return { id: subscriptionId, refreshBefore: expires, cursor: null, truncated: false };
}
export async function unsubscribe(env: Env, principal: Principal, params: Record<string, unknown>) {
  if (params.name !== eventDefinition.name) throw new BridgeError(400, '未知事件。');
  const args = object(params.arguments), delivery = object(params.delivery), url = callbackURL(delivery.url, env);
  await env.DB.prepare('UPDATE subscriptions SET active=0 WHERE owner=? AND session_id=? AND character_id=? AND callback_url=?')
    .bind(principal.userId, id(args.session_id), id(args.character_id), url.href).run();
  return {};
}
export async function flushDeliveries(env: Env, origin: string, send: typeof fetch = fetch): Promise<void> {
  const now = new Date().toISOString();
  const items = await env.DB.prepare('SELECT d.request_id,d.attempts,s.* FROM deliveries d JOIN subscriptions s ON s.id=d.subscription_id WHERE d.accepted=0 AND d.attempts<5 AND d.next_attempt_at<=? AND s.active=1 AND s.expires_at>? ORDER BY d.next_attempt_at LIMIT 10')
    .bind(now, now).all<Subscription & {request_id: string; attempts: number}>();
  for (const sub of items.results) {
    let accepted = 0, error: string | null = null, next = new Date(Date.now() + Math.min(300, 2 ** sub.attempts * 5) * 1000).toISOString();
    try {
      if (sub.oauth_client_id) {
        if (!env.OAUTH_PROVIDER) throw new Error('OAuth verifier unavailable');
        let cursor: string | undefined, authorized = false;
        do {
          const grants = await env.OAUTH_PROVIDER.listUserGrants(sub.owner, { limit: 100, cursor });
          authorized = grants.items.some(g => g.clientId === sub.oauth_client_id && (!g.expiresAt || g.expiresAt * 1000 > Date.now()) && g.scope.includes('bridge:write'));
          cursor = grants.cursor;
        } while (!authorized && cursor);
        if (!authorized) { await env.DB.prepare('UPDATE subscriptions SET active=0 WHERE id=?').bind(sub.id).run(); continue; }
      }
      callbackURL(sub.callback_url, env);
      const r = await env.DB.prepare('SELECT * FROM requests WHERE owner=? AND id=?').bind(sub.owner, sub.request_id).first<StoredRequest>();
      if (!r) continue;
      const eventID = 'message_' + r.id;
      const bytes = JSON.stringify({ eventId: eventID, name: 'message.created', timestamp: r.created_at,
        data: { request_id: r.id, session_id: r.session_id, character_id: r.character_id, text: r.text.slice(0,1000), url: origin + '/messages/' + encodeURIComponent(r.id) }, cursor: null });
      const response = await send(sub.callback_url, { method: 'POST', headers: signedHeaders(sub, eventID, bytes), body: bytes, redirect: 'error', signal: AbortSignal.timeout(10000) });
      accepted = response.ok ? 1 : 0; error = response.ok ? null : 'HTTP ' + response.status;
      if (response.status === 410 || response.status === 413) {
        next = '9999-01-01T00:00:00.000Z';
        if (response.status === 410) await env.DB.prepare('UPDATE subscriptions SET active=0 WHERE id=?').bind(sub.id).run();
      }
    } catch { error = '回调暂时无法访问'; }
    await env.DB.prepare('UPDATE deliveries SET attempts=attempts+1,accepted=?,last_error=?,next_attempt_at=? WHERE subscription_id=? AND request_id=?')
      .bind(accepted, error, next, sub.id, sub.request_id).run();
  }
}
