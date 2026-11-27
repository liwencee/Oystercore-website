// Health check for the container. A distroless image has no curl or shell, so the image
// carries this script and the Quadlet file runs it: node /app/healthcheck.mjs
//
// Exit 0 only when the website's own /healthz answers 2xx on its localhost port within 2 s;
// every other outcome (no answer, a refusal, a redirect, 3xx, 4xx, 5xx, a bad PORT) exits 1.
// The port is PORT, as the app reads it (4321 production, 4322 staging in the Quadlet files).
const path = '/healthz';
const defaultPort = '4321';

const port = process.env.PORT || defaultPort;
if (!/^\d{1,5}$/.test(port) || Number(port) < 1 || Number(port) > 65535) {
  console.error(`healthcheck: PORT "${port}" is not a port number`);
  process.exit(1);
}

try {
  // A redirect is not a healthy answer, so it is not followed.
  const response = await fetch(`http://localhost:${port}${path}`, {
    redirect: 'manual',
    signal: AbortSignal.timeout(2000),
  });
  await response.body?.cancel();
  if (response.status >= 200 && response.status < 300) {
    process.exit(0);
  }
  console.error(`healthcheck: ${path} answered ${response.status}`);
} catch (error) {
  console.error(`healthcheck: ${path} did not answer: ${error instanceof Error ? error.message : error}`);
}
process.exit(1);
