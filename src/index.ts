#!/usr/bin/env node

import { loadConfig } from './config.js';
import { startStdioServer } from './mcpServer.js';
import { startHttpServer } from './httpServer.js';
import fs from 'node:fs';

// ── CLI Bridge Entry Point ──────────────────────────────────────────────────
//
// Transport modes:
//   stdio  (default)  — for ChatGPT Desktop / local MCP clients
//   http               — for hosted ChatGPT MCP connectors via a tunnel
//
// Usage:
//   node dist/index.js                 → stdio mode
//   node dist/index.js --http 3848     → MCP HTTP mode on port 3848
//   CODEX_BRIDGE_PORT=3848 node dist/index.js --http  → MCP HTTP via env

async function main() {
  const config = loadConfig();

  // Parse args
  const args = process.argv.slice(2);
  const httpMode = args.includes('--http') || args.includes('-h') || !!process.env.CODEX_BRIDGE_PORT || !!process.env.LOCAL_DEV_BRIDGE_PORT || !!process.env.CODEX_WEB_PORT;
  let httpPort = config.port;

  const httpIdx = args.indexOf('--http');
  if (httpIdx !== -1 && args[httpIdx + 1]) {
    httpPort = parseInt(args[httpIdx + 1], 10);
  } else if (process.env.CODEX_BRIDGE_PORT || process.env.LOCAL_DEV_BRIDGE_PORT || process.env.CODEX_WEB_PORT) {
    httpPort = config.port;
  }

  // Ensure data directory exists
  fs.mkdirSync(config.dataDir, { recursive: true });

  // Graceful shutdown
  const shutdown = (signal: string) => {
    console.error(`[bridge] Received ${signal}, shutting down...`);
    process.exit(0);
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));

  console.error(`[bridge] codex-bridge v0.1.0 starting`);
  console.error(`[bridge] Data dir: ${config.dataDir}`);

  if (httpMode) {
    console.error(`[bridge] Mode: MCP Streamable HTTP`);
    await startHttpServer({ config }, httpPort);
  } else {
    console.error(`[bridge] Mode: MCP stdio`);
    console.error(`[bridge] Waiting for MCP client connection...`);
    await startStdioServer(config);
  }
}

main().catch((err) => {
  console.error('[bridge] Fatal error:', err);
  process.exit(1);
});
