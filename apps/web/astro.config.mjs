import node from '@astrojs/node';
import { defineConfig, passthroughImageService } from 'astro/config';

// Every page is rendered on the server (output: 'server'); pages that can be
// built ahead of time opt in with `export const prerender = true`.
export default defineConfig({
  output: 'server',
  adapter: node({ mode: 'standalone' }),
  server: { port: 4321 },
  // The site serves media from its own /media route and does not use astro:assets.
  // The passthrough service never resizes or re-encodes, so Astro's image optimiser
  // (sharp, AVIF) is unreachable. Defence in depth for GHSA-26w7-cxv4-gfx2.
  image: { service: passthroughImageService() },
});
