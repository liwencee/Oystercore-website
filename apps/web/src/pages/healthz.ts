import type { APIRoute } from 'astro';

// Server-rendered on every request: a health check must never be served from a build-time copy.
export const prerender = false;

export const GET: APIRoute = () => Response.json({ ok: true });
