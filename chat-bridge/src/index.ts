import OAuthProvider, { getOAuthApi, type OAuthHelpers, type OAuthProviderOptions, type OAuthResourceContext } from '@cloudflare/workers-oauth-provider';
import { BridgeError, json, string, type Env, type Principal } from './types';
import { api } from './service';
import { mcp } from './mcp';
import { flushDeliveries } from './events';

type AuthEnv = Env & { OAUTH_PROVIDER: OAuthHelpers };
const scopes = ['bridge:read','bridge:write','offline_access'];
function escape(value: string) { return value.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!)); }
function page(content: string, headers = new Headers(), status = 200) {
  headers.set('Content-Type','text/html; charset=utf-8'); headers.set('Cache-Control','no-store');
  headers.set('Content-Security-Policy',"default-src 'none'; style-src 'unsafe-inline'; form-action 'self' https://github.com; frame-ancestors 'none'; base-uri 'none'");
  headers.set('X-Content-Type-Options','nosniff');
  return new Response('<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>页间连接</title><style>body{font:17px/1.7 system-ui;max-width:620px;margin:60px auto;padding:24px;color:#202124}button,a{color:#075e73}button{font:inherit;padding:10px 20px}code{overflow-wrap:anywhere}small{color:#666}</style>'+content+'</html>',{headers,status});
}
const publicHandler = {
  async fetch(request: Request, bindings: Env): Promise<Response> {
    const env = bindings as AuthEnv;
    const url=new URL(request.url);
    if (url.pathname==='/health') return json({service:'yejian-chat-bridge',version:'0.1.0',modelAPI:false,configured:!!env.GITHUB_CLIENT_ID&&!!env.GITHUB_CLIENT_SECRET&&!env.PUBLIC_ORIGIN.includes('YOUR-SUBDOMAIN')});
    if (url.pathname==='/') return page('<h1>页间 × ChatGPT</h1><p>在 iPad 的“连接 ChatGPT”里填入此服务地址并授权。随后在 ChatGPT Work 中连接私人插件：</p><code>'+escape(env.PUBLIC_ORIGIN)+'/mcp</code><p>网页保留登录入口，消息通过插件事件传递。十轮真实对话验证通过后再接入完整书房。</p><a href="https://chatgpt.com/" rel="noreferrer">打开 ChatGPT</a>');
    if (url.pathname==='/authorize' && request.method==='GET') {
      const auth=await env.OAUTH_PROVIDER.parseAuthRequest(request), consent=await env.OAUTH_PROVIDER.beginConsent(auth), info=await env.OAUTH_PROVIDER.describeConsent(auth);
      return page('<h1>连接页间</h1><p>应用：'+escape(info.clientName)+'</p><p>回到：'+escape(info.redirectHost)+'</p><p>权限：'+escape(info.scope.join(', '))+'</p><p>可读取明确共享的消息和书摘、回传角色回复及笔记草稿。仅允许 GitHub 用户 '+escape(env.OWNER_GITHUB_LOGIN)+'。</p><form action="/consent" method="post"><input type="hidden" name="handle" value="'+escape(consent.handle)+'"><button type="submit">同意并使用 GitHub 登录</button></form>',consent.headers);
    }
    if (url.pathname==='/consent' && request.method==='POST') {
      const form=await request.formData(), consent=await env.OAUTH_PROVIDER.approveConsent(request,string(form.get('handle'),'授权请求',1000));
      const upstream=await env.OAUTH_PROVIDER.beginUpstream(consent.request,{headers:consent.headers});
      const target=new URL('https://github.com/login/oauth/authorize');
      target.searchParams.set('client_id',env.GITHUB_CLIENT_ID); target.searchParams.set('redirect_uri',env.PUBLIC_ORIGIN+'/github/callback');
      target.searchParams.set('scope','read:user'); target.searchParams.set('state',upstream.state);
      upstream.headers.set('Location',target.href); return new Response(null,{status:302,headers:upstream.headers});
    }
    if (url.pathname==='/github/callback') {
      const upstream=await env.OAUTH_PROVIDER.finishUpstream(request), code=string(url.searchParams.get('code'),'GitHub 授权码',1000);
      const tokenResponse=await fetch('https://github.com/login/oauth/access_token',{method:'POST',headers:{Accept:'application/json','Content-Type':'application/json'},body:JSON.stringify({client_id:env.GITHUB_CLIENT_ID,client_secret:env.GITHUB_CLIENT_SECRET,code,redirect_uri:env.PUBLIC_ORIGIN+'/github/callback'}),signal:AbortSignal.timeout(10000)});
      const token=await tokenResponse.json() as {access_token?:string};
      if (!tokenResponse.ok || !token.access_token) throw new BridgeError(401,'GitHub 授权未完成。');
      const profile=await fetch('https://api.github.com/user',{headers:{Authorization:'Bearer '+token.access_token,'User-Agent':'YeJian-Chat-Bridge',Accept:'application/vnd.github+json'},signal:AbortSignal.timeout(10000)});
      const user=await profile.json() as {id?:number;login?:string};
      if (!profile.ok || !user.id || user.login?.toLowerCase()!==env.OWNER_GITHUB_LOGIN.toLowerCase()) throw new BridgeError(403,'这个 GitHub 账号没有访问权限。');
      const granted=upstream.request.scope.filter(scope=>scopes.includes(scope));
      const result=await env.OAUTH_PROVIDER.completeAuthorization({request:upstream.request,userId:String(user.id),metadata:{label:user.login},scope:granted,props:{userId:String(user.id),login:user.login},revokeExistingGrants:false});
      upstream.headers.set('Location',result.redirectTo); return new Response(null,{status:302,headers:upstream.headers});
    }
    return page('<h1>找不到页面</h1>',new Headers(),404);
  }
};
export function providerOptions(env: Env): OAuthProviderOptions<Env> {
  return {apiRoute:['/mcp','/api/'],apiHandler:{
    async fetch(request,bindings,context) {
      const ctx=context as OAuthResourceContext<Principal>, p=ctx.props;
      if (!p?.userId || !ctx.auth.clientId || p.login?.toLowerCase()!==bindings.OWNER_GITHUB_LOGIN.toLowerCase()) throw new BridgeError(403,'账号未授权。');
      p.clientId = ctx.auth.clientId;
      const needed=request.method==='GET'?'bridge:read':'bridge:write';
      if (!ctx.auth.scope.includes(needed)) throw new BridgeError(403,'缺少权限：'+needed);
      return new URL(request.url).pathname==='/mcp'?mcp(request,bindings,p):api(request,bindings,p,ctx);
    }
  },defaultHandler:publicHandler,authorizeEndpoint:'/authorize',tokenEndpoint:'/token',clientRegistrationEndpoint:'/register',
    scopesSupported:scopes,requiredScopes:['bridge:read','bridge:write'],
    resourceMetadata:{resource:env.PUBLIC_ORIGIN,authorization_servers:[env.PUBLIC_ORIGIN]},
    allowPrivateUseRedirectUris:true,clientIdMetadataDocumentEnabled:true,accessTokenTTL:3600};
}
export function provider(env: Env) { return new OAuthProvider<Env>(providerOptions(env)); }
export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext) {
    try { return await provider(env).fetch(request,env,ctx); }
    catch(error) { return json({error:error instanceof BridgeError?error.message:'服务请求失败，请检查部署配置和授权。'},error instanceof BridgeError?error.status:500); }
  },
  async scheduled(_controller: ScheduledController,env: Env,ctx: ExecutionContext) {
    ctx.waitUntil(flushDeliveries({...env,OAUTH_PROVIDER:getOAuthApi(providerOptions(env),env)},env.PUBLIC_ORIGIN));
  }
};
