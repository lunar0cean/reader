import { readFileSync, writeFileSync } from 'node:fs';
import { validate } from './configuration.mjs';

const flags = new Map(), args = process.argv.slice(2);
const allowed = ['--origin', '--database-id', '--kv-id', '--owner'];
for (let i = 0; i < args.length; i += 2) {
  if (!allowed.includes(args[i]) || !args[i + 1] || flags.has(args[i])) throw new Error('使用 --origin、--database-id、--kv-id、--owner，每项填写一次。');
  flags.set(args[i], args[i + 1]);
}
const path = new URL('../wrangler.jsonc', import.meta.url), configuration = JSON.parse(readFileSync(path, 'utf8'));
if (flags.has('--origin')) configuration.vars.PUBLIC_ORIGIN = flags.get('--origin').replace(/\/$/, '');
if (flags.has('--owner')) configuration.vars.OWNER_GITHUB_LOGIN = flags.get('--owner');
if (flags.has('--database-id')) configuration.d1_databases.find(x => x.binding === 'DB').database_id = flags.get('--database-id');
if (flags.has('--kv-id')) configuration.kv_namespaces.find(x => x.binding === 'OAUTH_KV').id = flags.get('--kv-id');
const errors = validate(configuration);
if (errors.length) throw new Error(errors.join('\n'));
const pluginPath = new URL('../plugin/mcp.json', import.meta.url), plugin = JSON.parse(readFileSync(pluginPath, 'utf8'));
plugin.mcpServers['yejian-reader'].url = configuration.vars.PUBLIC_ORIGIN + '/mcp';
writeFileSync(path, JSON.stringify(configuration, null, 2) + '\n');
writeFileSync(pluginPath, JSON.stringify(plugin, null, 2) + '\n');
console.log('服务地址与资源 ID 已配置。GitHub OAuth 凭证请通过 wrangler secret put 设置。');
