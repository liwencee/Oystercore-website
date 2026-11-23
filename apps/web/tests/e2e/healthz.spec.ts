import { expect, test } from '@playwright/test';

test('healthz returns ok', async ({ request }) => {
  const response = await request.get('/healthz');
  expect(response.status()).toBe(200);

  const body = await response.json();
  expect(body.ok).toBe(true);
});
