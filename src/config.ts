import path from 'node:path';
import os from 'node:os';
import fs from 'node:fs';

export interface BridgePolicy {
  allowedProjectRoots: string[];
  denyGlobs: string[];
  shell: {
    enabled: boolean;
    denyPatterns: string[];
  };
}

export interface BridgeConfig {
  /** Where to store run data on disk */
  dataDir: string;
  /** Where launchd/stdout logs are written */
  logDir: string;
  /** Optional bearer/header token for HTTP MCP requests */
  authToken?: string;
  /** Policy controlling filesystem and shell boundaries */
  policy: BridgePolicy;
  port: number;
}

export function loadConfig(): BridgeConfig {
  const dataDir = process.env.CODEX_BRIDGE_DATA_DIR
    ?? process.env.LOCAL_DEV_BRIDGE_DATA_DIR
    ?? process.env.CODEX_WEB_DATA_DIR
    ?? path.join(os.homedir(), '.codex-bridge');
  const logDir = process.env.CODEX_BRIDGE_LOG_DIR
    ?? process.env.LOCAL_DEV_BRIDGE_LOG_DIR
    ?? process.env.CODEX_WEB_LOG_DIR
    ?? path.join(dataDir, 'logs');
  const authToken = (process.env.CODEX_BRIDGE_AUTH_TOKEN ?? process.env.LOCAL_DEV_BRIDGE_AUTH_TOKEN ?? process.env.CODEX_WEB_AUTH_TOKEN) || undefined;
  const port = parseInt(process.env.CODEX_BRIDGE_PORT ?? process.env.LOCAL_DEV_BRIDGE_PORT ?? process.env.CODEX_WEB_PORT ?? '3848', 10);
  const policy = loadPolicy(process.env.CODEX_BRIDGE_POLICY_PATH ?? process.env.LOCAL_DEV_BRIDGE_POLICY_PATH ?? process.env.CODEX_WEB_POLICY_PATH);

  return {
    dataDir,
    logDir,
    authToken,
    policy,
    port,
  };
}

function loadPolicy(policyPath?: string): BridgePolicy {
  const defaults: BridgePolicy = {
    allowedProjectRoots: [path.join(os.homedir(), 'Downloads', 'ai')],
    denyGlobs: [
      '**/.env',
      '**/.env.*',
      '**/*.pem',
      '**/*.key',
      '**/*.p12',
      '**/*.pfx',
      '**/.npmrc',
      '**/.netrc',
      '**/.ssh/**',
      '**/id_rsa',
      '**/id_ed25519',
    ],
    shell: {
      enabled: true,
      denyPatterns: [
        'sudo',
        'rm\\s+-rf\\s+/',
        'rm\\s+-rf\\s+~',
        'rm\\s+-rf\\s+\\$HOME',
        'chmod\\s+-R',
        'chown\\s+-R',
        'security\\s+find-',
        'launchctl\\s+bootout\\s+system',
        'curl\\s+[^|;]*\\|\\s*(sh|bash|zsh)',
        'wget\\s+[^|;]*\\|\\s*(sh|bash|zsh)',
      ],
    },
  };

  const resolved = policyPath ?? path.resolve(process.cwd(), 'bridge.policy.json');
  if (!fs.existsSync(resolved)) return defaults;

  try {
    const raw = JSON.parse(fs.readFileSync(resolved, 'utf-8')) as Partial<BridgePolicy>;
    return {
      allowedProjectRoots: raw.allowedProjectRoots ?? defaults.allowedProjectRoots,
      denyGlobs: raw.denyGlobs ?? defaults.denyGlobs,
      shell: {
        enabled: raw.shell?.enabled ?? defaults.shell.enabled,
        denyPatterns: raw.shell?.denyPatterns ?? defaults.shell.denyPatterns,
      },
    };
  } catch (err) {
    console.error(`[bridge] Failed to load policy ${resolved}:`, err);
    return defaults;
  }
}
