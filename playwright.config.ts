import { defineConfig, devices } from '@playwright/test';

const baseURL = process.env.BASE_URL ?? 'http://localhost:4321';

// The two servers run production builds against the oc_test database, never oc_dev.
// The secrets below are throwaway values for that disposable test database.
// The DATABASE_HOST, _PORT, _USERNAME and _PASSWORD values can be overridden from the shell
// (the CI database uses a different root password); the database name is always oc_test.
const cmsEnv = {
  NODE_ENV: 'production',
  STRAPI_TELEMETRY_DISABLED: 'true',
  HOST: '127.0.0.1',
  PORT: '1337',
  DATABASE_CLIENT: 'mysql',
  DATABASE_HOST: process.env.DATABASE_HOST ?? '127.0.0.1',
  DATABASE_PORT: process.env.DATABASE_PORT ?? '3307',
  DATABASE_NAME: 'oc_test',
  DATABASE_USERNAME: process.env.DATABASE_USERNAME ?? 'root',
  DATABASE_PASSWORD: process.env.DATABASE_PASSWORD ?? 'oc_dev_root',
  APP_KEYS: 'oc-test-app-key-1,oc-test-app-key-2',
  API_TOKEN_SALT: 'oc-test-api-token-salt',
  ADMIN_JWT_SECRET: 'oc-test-admin-jwt-secret',
  TRANSFER_TOKEN_SALT: 'oc-test-transfer-token-salt',
  JWT_SECRET: 'oc-test-jwt-secret',
  ENCRYPTION_KEY: 'oc-test-encryption-key',
};

const webEnv = {
  ASTRO_TELEMETRY_DISABLED: '1',
  HOST: '127.0.0.1',
  PORT: '4321',
  OC_CMS_URL: 'http://localhost:1337',
};

export default defineConfig({
  testDir: './apps/web/tests/e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [['github'], ['html', { open: 'never' }]] : 'list',
  use: {
    baseURL,
    trace: 'on-first-retry',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: [
    {
      command: 'pnpm --filter @oc/cms build && pnpm --filter @oc/cms start',
      url: 'http://localhost:1337/admin',
      env: cmsEnv,
      reuseExistingServer: !process.env.CI,
      timeout: 300_000,
    },
    {
      command: 'pnpm --filter @oc/web build && pnpm --filter @oc/web preview',
      // Waits for the port, not a URL: a URL check treats the 404 of an unbuilt route as "not ready".
      port: 4321,
      env: webEnv,
      reuseExistingServer: !process.env.CI,
      timeout: 120_000,
    },
  ],
});
