import { defineConfig } from 'vitest/config';
import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-pool-workers';

export default defineConfig({
  plugins: [cloudflareTest({
    wrangler: { configPath: './wrangler.jsonc' },
    miniflare: { bindings: {
      TEST_MIGRATIONS: await readD1Migrations('./migrations'),
      PUBLIC_ORIGIN: 'https://bridge.example.com',
      GITHUB_CLIENT_ID: 'test-client', GITHUB_CLIENT_SECRET: 'test-only-secret',
    } },
  })],
  test: { include: ['test/**/*.test.ts'] },
});
