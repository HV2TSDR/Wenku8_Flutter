import { mkdir, writeFile } from 'node:fs/promises';
import { HOME } from './worker.mjs';

// One authoritative template, served as a free static asset without a Worker invocation.
await mkdir(new URL('./public/', import.meta.url), { recursive: true });
await writeFile(new URL('./public/index.html', import.meta.url), HOME);
await writeFile(new URL('./public/_headers', import.meta.url), `/*
  Cache-Control: public, max-age=300
  Referrer-Policy: no-referrer
  X-Content-Type-Options: nosniff
  Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self' https://api.github.com; base-uri 'none'; frame-ancestors 'none'
`);
