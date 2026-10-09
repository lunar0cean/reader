import { readFileSync } from 'node:fs';
import { validate } from './configuration.mjs';
const errors = validate(JSON.parse(readFileSync(new URL('../wrangler.jsonc', import.meta.url), 'utf8')));
if (errors.length) { console.error('部署前需要完成配置：\n' + errors.join('\n')); process.exitCode = 1; }
else console.log('配置检查通过；本入口不会购买订阅或调用模型 API。');
