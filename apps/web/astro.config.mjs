import node from '@astrojs/node';
import { defineConfig } from 'astro/config';

// Every page is rendered on the server (output: 'server'); pages that can be
// built ahead of time opt in with `export const prerender = true`.
export default defineConfig({
  output: 'server',
  adapter: node({ mode: 'standalone' }),
  server: { port: 4321 },
});
