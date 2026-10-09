import { env, applyD1Migrations, createExecutionContext, waitOnExecutionContext } from 'cloudflare:test';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Webhook } from 'standardwebhooks';
import worker, { provider, providerOptions } from '../src/index';
import { getOAuthApi } from '@cloudflare/workers-oauth-provider';
import { api, callTool, connectionStatus, createMessage, createSession } from '../src/service';
import { callbackURL, flushDeliveries, subscribe, unsubscribe } from '../src/events';
import { mcp } from '../src/mcp';
import { body, type Env, type Principal } from '../src/types';

const bindings = env as unknown as Env & {TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1]};
const owner: Principal = {userId:'123',login:'lunar0cean'}, other: Principal = {userId:'456',login:'other'};
const secret = 'whsec_' + btoa('a'.repeat(32));
const input = (key = crypto.randomUUID()) => ({id:key,sessionId:'room-default',characterId:'room-companion',characterName:'书房伙伴',persona:'中文阅读伙伴',text:'解释这段文字',excerpts:[{id:'source-1',text:'明确共享的原文',title:'测试书',anchor:{bookID:'book-1',chapterID:'chapter-1',paragraph:2,utf16Offset:0}}]});
const params = () => ({name:'message.created',arguments:{session_id:'room-default',character_id:'room-companion'},delivery:{mode:'webhook',url:'https://chatgpt.com/mcp-events/test',secret}});
const acceptMock = vi.fn(async (url: RequestInfo | URL, init?: RequestInit) => {
  const bytes = String(init?.body), headers = new Headers(init?.headers);
  const value = new Webhook(secret).verify(bytes,{ 'webhook-id':headers.get('webhook-id')!, 'webhook-timestamp':headers.get('webhook-timestamp')!, 'webhook-signature':headers.get('webhook-signature')! }) as {type?:string;challenge?:string};
  return Response.json(value.type==='verification'?{challenge:value.challenge}:{accepted:true});
});
const accept = acceptMock as unknown as typeof fetch;
beforeEach(async () => {
  await applyD1Migrations(bindings.DB,bindings.TEST_MIGRATIONS);
  await bindings.DB.batch(['deliveries','subscriptions','results','requests','sessions'].map(table=>bindings.DB.prepare('DELETE FROM '+table)));
  vi.clearAllMocks();
});
describe('真实 Workers / D1 本地集成（没有连接 ChatGPT 模型）',()=>{
  it('原生 OAuth 注册、PKCE 授权、刷新和撤销通过官方 Provider；身份使用本地测试值',async()=>{
    const ctx=createExecutionContext(), send=(path:string,body?:Record<string,string>)=>worker.fetch(new Request(bindings.PUBLIC_ORIGIN+path,body?{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams(body)}:{}),bindings,ctx);
    const registered=await worker.fetch(new Request(bindings.PUBLIC_ORIGIN+'/register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({client_name:'页间测试',redirect_uris:['yejian://oauth/chat'],grant_types:['authorization_code','refresh_token'],response_types:['code'],token_endpoint_auth_method:'none'})}),bindings,ctx);
    expect(registered.status).toBe(201);
    const client=await registered.json() as {client_id:string};
    const verifier='a'.repeat(43), hashed=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier));
    const challenge=btoa(String.fromCharCode(...new Uint8Array(hashed))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=/g,'');
    const url=new URL(bindings.PUBLIC_ORIGIN+'/authorize');
    for(const [key,value] of Object.entries({client_id:client.client_id,redirect_uri:'yejian://oauth/chat',response_type:'code',state:'test-state',scope:'bridge:read bridge:write offline_access',resource:bindings.PUBLIC_ORIGIN,code_challenge:challenge,code_challenge_method:'S256'})) url.searchParams.set(key,value);
    const helpers=getOAuthApi(providerOptions(bindings),bindings), auth=await helpers.parseAuthRequest(new Request(url));
    const completed=await helpers.completeAuthorization({request:auth,userId:owner.userId,scope:auth.scope,metadata:{test:true},props:owner});
    const code=new URL(completed.redirectTo).searchParams.get('code')!;
    const tokens=await send('/token',{grant_type:'authorization_code',client_id:client.client_id,redirect_uri:'yejian://oauth/chat',code,code_verifier:verifier,resource:bindings.PUBLIC_ORIGIN});
    expect(tokens.status).toBe(200);
    const token=await tokens.json() as {access_token:string;refresh_token:string};expect(token.refresh_token).toBeTruthy();
    const apiResponse=await worker.fetch(new Request(bindings.PUBLIC_ORIGIN+'/api/sessions',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+token.access_token},body:JSON.stringify(input())}),bindings,ctx);
    expect(apiResponse.status).toBe(200);
    const rpc=await worker.fetch(new Request(bindings.PUBLIC_ORIGIN+'/mcp',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+token.access_token},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'server/discover'})}),bindings,ctx);
    expect((await rpc.json() as any).result.capabilities.events).toEqual({});
    const refreshed=await send('/token',{grant_type:'refresh_token',client_id:client.client_id,refresh_token:token.refresh_token,resource:bindings.PUBLIC_ORIGIN});expect(refreshed.status).toBe(200);
    const next=await refreshed.json() as {access_token:string;refresh_token:string};
    await subscribe({...bindings,OAUTH_PROVIDER:helpers},{...owner,clientId:client.client_id},params(),bindings.PUBLIC_ORIGIN,accept);
    const revoked=await send('/token',{client_id:client.client_id,token:next.refresh_token,token_type_hint:'refresh_token'});expect(revoked.status).toBe(200);
    await createMessage(bindings,owner,input('after-revoke'));
    const calls=acceptMock.mock.calls.length;await flushDeliveries({...bindings,OAUTH_PROVIDER:helpers},bindings.PUBLIC_ORIGIN,accept);
    expect(acceptMock.mock.calls.length).toBe(calls);expect((await connectionStatus(bindings,owner,'room-default')).state).toBe('awaiting_subscription');
    await waitOnExecutionContext(ctx);
  });
  it('未授权请求收到 OAuth challenge，健康页不需要授权',async()=>{
    const ctx=createExecutionContext();
    const health=await provider(bindings).fetch(new Request('https://bridge.example.com/health'),bindings,ctx);
    expect((await health.json() as {modelAPI:boolean}).modelAPI).toBe(false);
    const response=await worker.fetch(new Request('https://bridge.example.com/api/status?sessionId=room-default'),bindings,ctx);
    expect(response.status).toBe(401); expect(response.headers.get('www-authenticate')).toContain('oauth-protected-resource');
    await waitOnExecutionContext(ctx);
  });
  it('十轮模拟事件签名、插件回传、游标同步；不代表真实 GPT 耗时',async()=>{
    await createSession(bindings,owner,input());
    await subscribe(bindings,owner,params(),bindings.PUBLIC_ORIGIN,accept);
    for (let i=0;i<10;i++) {
      const message=input('round-'+i); await createMessage(bindings,owner,message);
      await flushDeliveries(bindings,bindings.PUBLIC_ORIGIN,accept);
      await callTool(bindings,owner,'publish_reply',{request_id:message.id,text:'本地模拟回复 '+i,citations:['source-1']});
    }
    const ctx=createExecutionContext(), result=await api(new Request('https://bridge.example.com/api/results?sessionId=room-default&after=0'),bindings,owner,ctx);
    const data=await result.json() as {results:unknown[];cursor:number}; expect(data.results).toHaveLength(10);expect(data.cursor).toBeGreaterThan(0);
    expect((await connectionStatus(bindings,owner,'room-default')).pending).toHaveLength(0);
  });
  it('断线前的首条消息在建立订阅后得到投递',async()=>{
    await createMessage(bindings,owner,input('before-subscription'));
    await subscribe(bindings,owner,params(),bindings.PUBLIC_ORIGIN,accept);
    const row=await bindings.DB.prepare('SELECT accepted FROM deliveries WHERE request_id=?').bind('before-subscription').first<{accepted:number}>();
    expect(row?.accepted).toBe(1);
  });
  it('重发消息不复制，不允许相同 ID 更换内容',async()=>{
    const value=input('same');await createMessage(bindings,owner,value);
    expect((await createMessage(bindings,owner,value)).duplicate).toBe(true);
    await expect(createMessage(bindings,owner,{...value,text:'替换'})).rejects.toThrow('不同消息');
  });
  it('重复回传和重复笔记草稿保持一次结果，引用只允许共享出处',async()=>{
    const message=input('reply');await createMessage(bindings,owner,message);
    await callTool(bindings,owner,'publish_reply',{request_id:'reply',text:'第一条',citations:['source-1']});
    await callTool(bindings,owner,'publish_reply',{request_id:'reply',text:'重复第二条'});
    await callTool(bindings,owner,'create_note_draft',{request_id:'reply',text:'草稿',citations:['source-1']});
    await expect(callTool(bindings,owner,'publish_reply',{request_id:'reply',text:'错误引用',citations:['invented']})).rejects.toThrow('未共享');
    const rows=await bindings.DB.prepare('SELECT kind,payload_json FROM results').all<{kind:string;payload_json:string}>();
    expect(rows.results).toHaveLength(2);expect(rows.results.find(r=>r.kind==='reply')?.payload_json).toContain('第一条');
  });
  it('不同身份不能读取请求或写回回复',async()=>{
    await createMessage(bindings,owner,input('private'));
    await expect(callTool(bindings,other,'get_context',{request_id:'private'})).rejects.toThrow('找不到');
    await expect(callTool(bindings,other,'publish_reply',{request_id:'private',text:'串话'})).rejects.toThrow('找不到');
  });
  it('一个会话不能改绑到其他角色，订阅不能串角色',async()=>{
    await createSession(bindings,owner,input());
    await expect(createSession(bindings,owner,{...input(),characterId:'other'})).rejects.toThrow('其他角色');
    const p=params();p.arguments.character_id='other';
    await expect(subscribe(bindings,owner,p,bindings.PUBLIC_ORIGIN,accept)).rejects.toThrow('先在 App');
  });
  it('回调仅接受批准的 HTTPS 域名，不允许重定向或内网',()=>{
    for (const value of ['http://chatgpt.com/a','https://127.0.0.1','https://chatgpt.com.attacker.example/a','https://user:pass@chatgpt.com/a','https://chatgpt.com:444/a']) expect(()=>callbackURL(value,bindings)).toThrow();
    expect(callbackURL('https://events.chatgpt.com/a',bindings).protocol).toBe('https:');
  });
  it('回调验证不通过时不建立订阅',async()=>{
    await createSession(bindings,owner,input());
    await expect(subscribe(bindings,owner,params(),bindings.PUBLIC_ORIGIN,async()=>Response.json({challenge:'wrong'}))).rejects.toThrow('验证失败');
    expect((await connectionStatus(bindings,owner,'room-default')).state).toBe('awaiting_subscription');
  });
  it('取消订阅和到期后不再投递，续期沿用订阅 ID',async()=>{
    await createSession(bindings,owner,input());
    const first=await subscribe(bindings,owner,params(),bindings.PUBLIC_ORIGIN,accept), refreshed=await subscribe(bindings,owner,params(),bindings.PUBLIC_ORIGIN,accept);
    expect(first.id).toBe(refreshed.id);
    await unsubscribe(bindings,owner,params()); await unsubscribe(bindings,owner,params());
    await createMessage(bindings,owner,input('stopped')); expect((await connectionStatus(bindings,owner,'room-default')).state).toBe('awaiting_subscription');
    await subscribe(bindings,owner,params(),bindings.PUBLIC_ORIGIN,accept);
    await bindings.DB.prepare('UPDATE subscriptions SET expires_at=?').bind('2020-01-01T00:00:00.000Z').run();
    expect((await connectionStatus(bindings,owner,'room-default')).state).toBe('awaiting_subscription');
  });
  it('410 停止重试，临时失败保留投递状态',async()=>{
    await createSession(bindings,owner,input());await subscribe(bindings,owner,params(),bindings.PUBLIC_ORIGIN,accept);
    await createMessage(bindings,owner,input('failure'));
    await flushDeliveries(bindings,bindings.PUBLIC_ORIGIN,async()=>new Response(null,{status:503}));
    let row=await bindings.DB.prepare('SELECT attempts,accepted FROM deliveries').first<{attempts:number;accepted:number}>();expect(row?.attempts).toBe(1);expect(row?.accepted).toBe(0);
    await bindings.DB.prepare('UPDATE deliveries SET next_attempt_at=?').bind('2020-01-01T00:00:00.000Z').run();
    await flushDeliveries(bindings,bindings.PUBLIC_ORIGIN,async()=>new Response(null,{status:410}));
    expect((await connectionStatus(bindings,owner,'room-default')).state).toBe('awaiting_subscription');
  });
  it('模型回复和笔记草稿不会触发新的用户消息事件',async()=>{
    await createMessage(bindings,owner,input('loop'));
    await callTool(bindings,owner,'publish_reply',{request_id:'loop',text:'回复'});await callTool(bindings,owner,'create_note_draft',{request_id:'loop',text:'草稿'});
    const count=await bindings.DB.prepare('SELECT COUNT(*) AS n FROM requests').first<{n:number}>();expect(count?.n).toBe(1);
  });
  it('MCP 事件发现、工具错误及方法发现使用标准响应',async()=>{
    const rpc=async(method:string,params={})=>{const response=await mcp(new Request('https://bridge.example.com/mcp',{method:'POST',body:JSON.stringify({jsonrpc:'2.0',id:1,method,params})}),bindings,owner);return response.json() as Promise<any>;};
    expect((await rpc('server/discover')).result.supportedVersions).toContain('2026-07-28');
    expect((await rpc('events/list')).result.events[0].name).toBe('message.created');
    expect((await rpc('tools/list')).result.tools).toHaveLength(4);
    expect((await rpc('tools/call',{name:'get_context',arguments:{request_id:'missing'}})).result.isError).toBe(true);
    expect((await rpc('unknown')).error.code).toBe(-32601);
    expect((await rpc('initialize',{protocolVersion:'2026-07-28'})).result.capabilities.events).toEqual({});
    const malformed=await mcp(new Request('https://bridge.example.com/mcp',{method:'POST',body:'broken'}),bindings,owner);
    expect((await malformed.json() as any).error.code).toBe(-32700);
    const invalid=await mcp(new Request('https://bridge.example.com/mcp',{method:'POST',body:JSON.stringify({method:'tools/list',id:1})}),bindings,owner);
    expect((await invalid.json() as any).error.code).toBe(-32600);
  });
  it('续订缓存验证，密钥轮换短暂同时签名',async()=>{
    await createSession(bindings,owner,input());const old=await subscribe(bindings,owner,params(),bindings.PUBLIC_ORIGIN,accept);
    const verifiedAt=new Date(Date.now()-5*60000).toISOString();
    await bindings.DB.prepare('UPDATE subscriptions SET verified_at=? WHERE id=?').bind(verifiedAt,old.id).run();
    const calls=acceptMock.mock.calls.length;await subscribe(bindings,owner,params(),bindings.PUBLIC_ORIGIN,accept);expect(acceptMock.mock.calls.length).toBe(calls);
    expect((await bindings.DB.prepare('SELECT verified_at FROM subscriptions WHERE id=?').bind(old.id).first<{verified_at:string}>())?.verified_at).toBe(verifiedAt);
    await bindings.DB.prepare('UPDATE subscriptions SET verified_at=? WHERE id=?').bind(new Date(Date.now()-16*60000).toISOString(),old.id).run();
    await subscribe(bindings,owner,params(),bindings.PUBLIC_ORIGIN,accept);expect(acceptMock.mock.calls.length).toBe(calls+1);
    const changed=params(), rotated='whsec_'+btoa('b'.repeat(32));changed.delivery.secret=rotated;
    await subscribe(bindings,owner,changed,bindings.PUBLIC_ORIGIN,async(_url,init)=>{
      const headers=new Headers(init?.headers), bytes=String(init?.body);
      const value=new Webhook(rotated).verify(bytes,{'webhook-id':headers.get('webhook-id')!,'webhook-timestamp':headers.get('webhook-timestamp')!,'webhook-signature':headers.get('webhook-signature')!}) as {challenge:string};
      return Response.json({challenge:value.challenge});
    });
    await createMessage(bindings,owner,input('rotated'));
    await flushDeliveries(bindings,bindings.PUBLIC_ORIGIN,async(_url,init)=>{
      const headers=new Headers(init?.headers), bytes=String(init?.body), signed={'webhook-id':headers.get('webhook-id')!,'webhook-timestamp':headers.get('webhook-timestamp')!,'webhook-signature':headers.get('webhook-signature')!};
      expect(signed['webhook-signature'].split(' ')).toHaveLength(2);new Webhook(secret).verify(bytes,signed);new Webhook(rotated).verify(bytes,signed);
      return new Response(null,{status:204});
    });
    expect((await connectionStatus(bindings,owner,'room-default')).subscriptions[0].id).toBe(old.id);
  });
  it('限制消息尺寸并拒绝伪造笔记来源和动作',async()=>{
    await expect(body(new Request('https://x',{method:'POST',body:'x'.repeat(262145)}))).rejects.toThrow('太大');
    await createMessage(bindings,owner,input('action'));
    await expect(callTool(bindings,owner,'publish_reply',{request_id:'action',text:'执行',action:'eval'})).rejects.toThrow('允许清单');
    await expect(callTool(bindings,owner,'publish_reply',{request_id:'action',text:'拿书',action:'fetchBook',book_id:'not-shared'})).rejects.toThrow('没有');
  });
});
