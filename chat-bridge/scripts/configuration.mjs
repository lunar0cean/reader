export function validate(configuration) {
  const errors = [], vars = configuration.vars ?? {};
  let origin;
  try {
    origin = new URL(vars.PUBLIC_ORIGIN);
    if (origin.protocol !== 'https:' || origin.username || origin.password || origin.search || origin.hash || origin.pathname !== '/' || origin.hostname.includes('your-subdomain')) throw new Error();
  } catch { errors.push('PUBLIC_ORIGIN 必须是实际部署服务的 HTTPS 根地址。'); }
  if (!/^[a-z\d](?:[a-z\d-]{0,37}[a-z\d])?$/i.test(vars.OWNER_GITHUB_LOGIN ?? '')) errors.push('填写本人 GitHub 用户名。');
  const db = configuration.d1_databases?.find(x => x.binding === 'DB')?.database_id;
  const kv = configuration.kv_namespaces?.find(x => x.binding === 'OAUTH_KV')?.id;
  if (!/^[\da-f]{8}-(?:[\da-f]{4}-){3}[\da-f]{12}$/i.test(db ?? '') || /^0+-0+-0+-0+-0+$/.test(db)) errors.push('填写实际 D1 database_id。');
  if (!/^[\da-f]{32}$/i.test(kv ?? '') || /^0+$/.test(kv)) errors.push('填写实际 OAuth KV namespace id。');
  return errors;
}
