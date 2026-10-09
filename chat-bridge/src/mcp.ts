import { BridgeError, CallbackEndpointError, body, json, object, string, type Env, type Principal } from './types';
import { eventDefinition, subscribe, unsubscribe } from './events';
import { callTool, tools } from './service';

export async function mcp(request: Request, env: Env, p: Principal): Promise<Response> {
  if (request.method === 'GET' || request.method === 'DELETE') return new Response(null,{status:405,headers:{Allow:'POST'}});
  if (request.method !== 'POST') throw new BridgeError(405,'使用 POST。');
  let rpc: Record<string, unknown>;
  try { rpc = await body(request); }
  catch(error) { if (error instanceof BridgeError && error.status === 413) throw error; return json({jsonrpc:'2.0',id:null,error:{code:-32700,message:'JSON 无法解析。'}}); }
  if (rpc.jsonrpc !== '2.0' || typeof rpc.method !== 'string' || (rpc.id != null && typeof rpc.id !== 'string' && typeof rpc.id !== 'number')) return json({jsonrpc:'2.0',id:null,error:{code:-32600,message:'JSON-RPC 请求无效。'}});
  const method = rpc.method;
  if (method.startsWith('notifications/')) return new Response(null,{status:202});
  try {
    const params = rpc.params == null ? {} : object(rpc.params);
    let result: unknown;
    switch (method) {
      case 'server/discover': result={resultType:'complete',supportedVersions:['2026-07-28'],capabilities:{tools:{},events:{}},serverInfo:{name:'yejian-chat-bridge',version:'0.1.0'}}; break;
      case 'initialize': result={protocolVersion:params.protocolVersion === '2026-07-28' ? '2026-07-28' : '2025-11-25',capabilities:params.protocolVersion === '2026-07-28' ? {tools:{},events:{}} : {tools:{}},serverInfo:{name:'yejian-chat-bridge',version:'0.1.0'},instructions:'角色回复必须调用 publish_reply 才能回到页间。订阅需在支持 MCP Events 的 Work 环境完成。'}; break;
      case 'ping': result={}; break;
      case 'tools/list': result={tools}; break;
      case 'events/list': result={events:[eventDefinition]}; break;
      case 'events/subscribe': result=await subscribe(env,p,params,env.PUBLIC_ORIGIN); break;
      case 'events/unsubscribe': result=await unsubscribe(env,p,params); break;
      case 'tools/call': {
        try { const value=await callTool(env,p,string(params.name,'工具',100),object(params.arguments??{})); result={content:[{type:'text',text:JSON.stringify(value)}],structuredContent:value,isError:false}; }
        catch(error) { if (!(error instanceof BridgeError)) throw error; result={content:[{type:'text',text:error.message}],isError:true}; }
        break;
      }
      default: return json({jsonrpc:'2.0',id:rpc.id??null,error:{code:-32601,message:'未知方法'}});
    }
    return json({jsonrpc:'2.0',id:rpc.id??null,result});
  } catch(error) {
    if (error instanceof CallbackEndpointError) return json({jsonrpc:'2.0',id:rpc.id??null,error:{code:-32015,message:error.message,data:{reason:error.reason}}});
    return json({jsonrpc:'2.0',id:rpc.id??null,error:{code:error instanceof BridgeError?-32602:-32603,message:error instanceof BridgeError?error.message:'服务暂时无法完成请求。'}});
  }
}
