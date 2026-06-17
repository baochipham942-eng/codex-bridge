import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { z } from 'zod';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';
import { exec, execFileSync, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash } from 'node:crypto';
import type { BridgeConfig } from './config.js';
import { snapshotProject } from './project.js';
import { createCheckpoint, getChangedFiles, getRawDiff, parseUnifiedDiff } from './diffEngine.js';

const execAsync = promisify(exec);

const VERSION = '0.1.0';
const MAX_FILE_BYTES = 2 * 1024 * 1024;
const MAX_OUTPUT_BYTES = 200_000;
const MAX_READ_LINES = 2_000;
const DEFAULT_TEST_TIMEOUT_MS = 120_000;
const DEFAULT_PROCESS_LOG_LINES = 80;

interface ChangeRecord {
  id: string;
  title: string;
  projectPath: string;
  checkpoint?: string;
  status: 'active' | 'done' | 'blocked';
  notes: Array<{ ts: string; text: string }>;
  createdAt: string;
  updatedAt: string;
  finishedAt?: string;
  verification?: VerificationRecord;
}

interface VerificationRecord {
  status: 'passed' | 'failed' | 'not_run';
  command?: string;
  exitCode?: number;
  stdout?: string;
  stderr?: string;
  reason?: string;
}

interface ProcessRecord {
  id: string;
  projectPath: string;
  command: string;
  pid: number;
  logFile: string;
  status: 'running' | 'exited' | 'unknown';
  startedAt: string;
  updatedAt: string;
}

interface CommandResult {
  command: string;
  exitCode: number;
  stdout: string;
  stderr: string;
  durationMs: number;
  timedOut?: boolean;
}

const changedFileOutput = {
  path: z.string(),
  oldPath: z.string().optional(),
  status: z.enum(['added', 'modified', 'deleted', 'renamed']),
  insertions: z.number(),
  deletions: z.number(),
};

const commandResultOutput = {
  command: z.string(),
  exitCode: z.number(),
  stdout: z.string(),
  stderr: z.string(),
  durationMs: z.number(),
  timedOut: z.boolean().optional(),
};

const verificationOutput = {
  status: z.enum(['passed', 'failed', 'not_run']),
  command: z.string().optional(),
  exitCode: z.number().optional(),
  stdout: z.string().optional(),
  stderr: z.string().optional(),
  reason: z.string().optional(),
};

const processOutput = {
  id: z.string(),
  projectPath: z.string(),
  command: z.string(),
  pid: z.number(),
  logFile: z.string(),
  status: z.enum(['running', 'exited', 'unknown']),
  startedAt: z.string(),
  updatedAt: z.string(),
};

export function createMcpServer(config: BridgeConfig): McpServer {
  const server = new McpServer(
    { name: 'codex-bridge', version: VERSION },
    { capabilities: { tools: {} } },
  );

  server.registerTool('bridge.status', {
    title: 'Bridge Status',
    description: 'Show the local bridge configuration, policy boundaries, and runtime state.',
    inputSchema: {},
    outputSchema: {
      service: z.string(),
      version: z.string(),
      dataDir: z.string(),
      logDir: z.string(),
      allowedProjectRoots: z.array(z.string()),
      authEnabled: z.boolean(),
      changeCount: z.number(),
      processCount: z.number(),
      tools: z.array(z.string()),
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, withToolLogging(config, 'bridge.status', async () => {
    const changes = readChanges(config);
    const processes = refreshProcesses(config);
    const tools = [
      'bridge.status',
      'workspace.inspect',
      'code.search',
      'code.read',
      'file.patch',
      'file.write',
      'test.run',
      'git.diff',
      'change.start',
      'change.note',
      'change.finish',
      'process.start',
      'process.list',
      'process.stop',
      'port.check',
    ];

    return ok(`codex-bridge ${VERSION}`, {
      service: 'codex-bridge',
      version: VERSION,
      dataDir: config.dataDir,
      logDir: config.logDir,
      allowedProjectRoots: config.policy.allowedProjectRoots.map(expandHome),
      authEnabled: Boolean(config.authToken),
      changeCount: changes.length,
      processCount: processes.length,
      tools,
    });
  }));

  server.registerTool('workspace.inspect', {
    title: 'Inspect Workspace',
    description: 'Inspect a local project before planning or editing. Returns git state, project type, scripts, tests, key files, and a bounded tree.',
    inputSchema: {
      projectPath: z.string().describe('Absolute path to the project directory'),
      maxDepth: z.number().int().min(1).max(8).default(3),
      maxFiles: z.number().int().min(20).max(500).default(160),
    },
    outputSchema: {
      path: z.string(),
      branch: z.string(),
      isGitRepo: z.boolean(),
      headCommit: z.string().optional(),
      isDirty: z.boolean(),
      entries: z.array(z.string()),
      language: z.string().optional(),
      packageManager: z.string().optional(),
      scripts: z.array(z.object({ name: z.string(), command: z.string() })),
      testCommands: z.array(z.object({ name: z.string(), command: z.string(), confidence: z.enum(['high', 'medium', 'low']) })),
      keyFiles: z.array(z.string()),
      fileTree: z.array(z.object({ path: z.string(), type: z.enum(['file', 'directory']), size: z.number(), lines: z.number().optional() })),
      totalFiles: z.number(),
      totalLines: z.number(),
      truncated: z.boolean(),
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, withToolLogging(config, 'workspace.inspect', async ({ projectPath, maxDepth, maxFiles }) => {
    const root = resolveProject(config, projectPath);
    const snapshot = snapshotProject(root);
    const scripts = readPackageScripts(root);
    const tree = buildFileTree(config, root, maxDepth, maxFiles);
    const testCommands = detectTestCommands(root, scripts);
    const keyFiles = detectKeyFiles(root);

    return ok(`${snapshot.language ?? 'project'} at ${root}: ${tree.totalFiles} files scanned`, {
      ...snapshot,
      scripts,
      testCommands,
      keyFiles,
      fileTree: tree.entries,
      totalFiles: tree.totalFiles,
      totalLines: tree.totalLines,
      truncated: tree.truncated,
    });
  }));

  server.registerTool('code.search', {
    title: 'Search Code',
    description: 'Search a project with ripgrep and return bounded matches.',
    inputSchema: {
      projectPath: z.string(),
      query: z.string().min(1),
      glob: z.string().optional().describe('Optional ripgrep glob, such as src/**/*.ts'),
      maxMatches: z.number().int().min(1).max(200).default(80),
    },
    outputSchema: {
      query: z.string(),
      matches: z.array(z.object({
        file: z.string(),
        line: z.number(),
        column: z.number(),
        text: z.string(),
      })),
      truncated: z.boolean(),
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, withToolLogging(config, 'code.search', async ({ projectPath, query, glob, maxMatches }) => {
    const root = resolveProject(config, projectPath);
    const matches = searchCode(config, root, query, glob, maxMatches + 1);
    const truncated = matches.length > maxMatches;
    const bounded = matches.slice(0, maxMatches);

    return ok(`${bounded.length}${truncated ? '+' : ''} matches for "${query}"`, {
      query,
      matches: bounded,
      truncated,
    });
  }));

  server.registerTool('code.read', {
    title: 'Read Code',
    description: 'Read one or more safe text files from a project, with optional line ranges.',
    inputSchema: {
      projectPath: z.string(),
      files: z.array(z.object({
        path: z.string(),
        startLine: z.number().int().min(1).optional(),
        endLine: z.number().int().min(1).optional(),
      })).min(1).max(20),
      maxLinesPerFile: z.number().int().min(1).max(MAX_READ_LINES).default(600),
    },
    outputSchema: {
      files: z.array(z.object({
        path: z.string(),
        startLine: z.number(),
        endLine: z.number(),
        totalLines: z.number(),
        content: z.string(),
        truncated: z.boolean(),
      })),
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, withToolLogging(config, 'code.read', async ({ projectPath, files, maxLinesPerFile }) => {
    const root = resolveProject(config, projectPath);
    const results = files.map((file) => readTextFileRange(config, root, file.path, file.startLine, file.endLine, maxLinesPerFile));
    const text = results.map((file) => `# ${file.path}:${file.startLine}-${file.endLine}\n${file.content}`).join('\n\n');
    return {
      content: [{ type: 'text' as const, text: text || 'No content.' }],
      structuredContent: { files: results },
    };
  }));

  server.registerTool('file.patch', {
    title: 'Patch File',
    description: 'Patch a safe text file by replacing exact text. Use after reading the target file.',
    inputSchema: {
      projectPath: z.string(),
      file: z.string(),
      oldText: z.string().min(1),
      newText: z.string(),
      replaceAll: z.boolean().default(false),
    },
    outputSchema: {
      file: z.string(),
      replacements: z.number(),
      sha256Before: z.string(),
      sha256After: z.string(),
      changedFiles: z.array(z.object(changedFileOutput)),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, withToolLogging(config, 'file.patch', async ({ projectPath, file, oldText, newText, replaceAll }) => {
    const root = resolveProject(config, projectPath);
    const target = resolveInsideProject(config, root, file);
    ensureTextFile(target);
    const before = fs.readFileSync(target, 'utf-8');
    const occurrences = countOccurrences(before, oldText);
    if (occurrences === 0) throw new Error(`oldText not found in ${file}`);
    if (!replaceAll && occurrences > 1) throw new Error(`oldText appears ${occurrences} times in ${file}; set replaceAll=true or use a more specific snippet`);

    const after = replaceAll ? before.split(oldText).join(newText) : before.replace(oldText, newText);
    fs.writeFileSync(target, after, 'utf-8');
    const sha256Before = sha256(before);
    const sha256After = sha256(after);
    auditFileOperation(config, 'file.patch', root, [file]);

    const changedFiles = getChangedFiles(root);
    return ok(`Patched ${file} (${replaceAll ? occurrences : 1} replacement${(replaceAll ? occurrences : 1) === 1 ? '' : 's'})`, {
      file: normalizeRel(file),
      replacements: replaceAll ? occurrences : 1,
      sha256Before,
      sha256After,
      changedFiles,
    });
  }));

  server.registerTool('file.write', {
    title: 'Write File',
    description: 'Create or overwrite a safe text file inside a project.',
    inputSchema: {
      projectPath: z.string(),
      file: z.string(),
      content: z.string(),
      overwrite: z.boolean().default(false),
      createDirs: z.boolean().default(true),
    },
    outputSchema: {
      file: z.string(),
      bytes: z.number(),
      created: z.boolean(),
      overwritten: z.boolean(),
      sha256: z.string(),
      changedFiles: z.array(z.object(changedFileOutput)),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, withToolLogging(config, 'file.write', async ({ projectPath, file, content, overwrite, createDirs }) => {
    if (Buffer.byteLength(content, 'utf-8') > MAX_FILE_BYTES) throw new Error(`content exceeds ${MAX_FILE_BYTES} bytes`);
    const root = resolveProject(config, projectPath);
    const target = resolveInsideProject(config, root, file);
    const existed = fs.existsSync(target);
    if (existed && !overwrite) throw new Error(`${file} already exists; set overwrite=true to replace it`);
    if (createDirs) fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, content, 'utf-8');
    auditFileOperation(config, 'file.write', root, [file]);

    const changedFiles = getChangedFiles(root);
    return ok(`${existed ? 'Wrote' : 'Created'} ${file}`, {
      file: normalizeRel(file),
      bytes: Buffer.byteLength(content, 'utf-8'),
      created: !existed,
      overwritten: existed,
      sha256: sha256(content),
      changedFiles,
    });
  }));

  server.registerTool('test.run', {
    title: 'Run Tests',
    description: 'Run a bounded test, build, lint, or typecheck command inside a project.',
    inputSchema: {
      projectPath: z.string(),
      command: z.string().optional().describe('Defaults to the best detected test command'),
      timeoutMs: z.number().int().min(1_000).max(900_000).default(DEFAULT_TEST_TIMEOUT_MS),
      maxOutputBytes: z.number().int().min(1_000).max(1_000_000).default(MAX_OUTPUT_BYTES),
    },
    outputSchema: commandResultOutput,
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, withToolLogging(config, 'test.run', async ({ projectPath, command, timeoutMs, maxOutputBytes }) => {
    const root = resolveProject(config, projectPath);
    const selected = command ?? detectTestCommands(root, readPackageScripts(root))[0]?.command;
    if (!selected) throw new Error('No test command detected. Pass command explicitly.');
    const result = await runProjectCommand(config, root, selected, timeoutMs, maxOutputBytes);
    return commandResponse(result);
  }));

  server.registerTool('git.diff', {
    title: 'Git Diff',
    description: 'Return current git changes for the project, with bounded text and structured file stats.',
    inputSchema: {
      projectPath: z.string(),
      checkpoint: z.string().optional(),
      maxPatchBytes: z.number().int().min(1_000).max(1_000_000).default(120_000),
    },
    outputSchema: {
      changedFiles: z.array(z.object(changedFileOutput)),
      stats: z.object({ files: z.number(), insertions: z.number(), deletions: z.number() }),
      patch: z.string(),
      truncated: z.boolean(),
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, withToolLogging(config, 'git.diff', async ({ projectPath, checkpoint, maxPatchBytes }) => {
    const root = resolveProject(config, projectPath);
    const changedFiles = getChangedFiles(root, checkpoint);
    const rawPatch = getRawDiff(root, checkpoint);
    const patch = truncate(rawPatch, maxPatchBytes);
    const stats = diffStats(changedFiles);
    return ok(`${stats.files} changed file${stats.files === 1 ? '' : 's'}, +${stats.insertions}/-${stats.deletions}`, {
      changedFiles,
      stats,
      patch,
      truncated: patch.length < rawPatch.length,
    }, { structuredDiff: parseUnifiedDiff(rawPatch) });
  }));

  server.registerTool('change.start', {
    title: 'Start Change Session',
    description: 'Start a tracked local change session before edits. Records git checkpoint and project path.',
    inputSchema: {
      projectPath: z.string(),
      title: z.string().min(1),
      note: z.string().optional(),
    },
    outputSchema: {
      id: z.string(),
      title: z.string(),
      projectPath: z.string(),
      checkpoint: z.string().optional(),
      status: z.enum(['active', 'done', 'blocked']),
      notes: z.array(z.object({ ts: z.string(), text: z.string() })),
      createdAt: z.string(),
      updatedAt: z.string(),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, withToolLogging(config, 'change.start', async ({ projectPath, title, note }) => {
    const root = resolveProject(config, projectPath);
    const now = new Date().toISOString();
    const change: ChangeRecord = {
      id: makeId('chg'),
      title,
      projectPath: root,
      checkpoint: createCheckpoint(root),
      status: 'active',
      notes: note ? [{ ts: now, text: note }] : [],
      createdAt: now,
      updatedAt: now,
    };
    const changes = readChanges(config);
    changes.unshift(change);
    writeChanges(config, changes);
    auditEvent(config, 'change.start', { id: change.id, projectPath: root, title });

    return ok(`Change ${change.id} started for ${root}`, change as unknown as Record<string, unknown>);
  }));

  server.registerTool('change.note', {
    title: 'Add Change Note',
    description: 'Append a note to an active or completed change session.',
    inputSchema: {
      changeId: z.string(),
      note: z.string().min(1),
    },
    outputSchema: {
      id: z.string(),
      title: z.string(),
      status: z.enum(['active', 'done', 'blocked']),
      notes: z.array(z.object({ ts: z.string(), text: z.string() })),
      updatedAt: z.string(),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, withToolLogging(config, 'change.note', async ({ changeId, note }) => {
    const changes = readChanges(config);
    const change = findChange(changes, changeId);
    const now = new Date().toISOString();
    change.notes.push({ ts: now, text: note });
    change.updatedAt = now;
    writeChanges(config, changes);
    auditEvent(config, 'change.note', { id: changeId });

    return ok(`Note added to ${changeId}`, {
      id: change.id,
      title: change.title,
      status: change.status,
      notes: change.notes,
      updatedAt: change.updatedAt,
    });
  }));

  server.registerTool('change.finish', {
    title: 'Finish Change Session',
    description: 'Close a change session with current diff and optional verification command. Use this when the local work is done or blocked.',
    inputSchema: {
      changeId: z.string(),
      status: z.enum(['done', 'blocked']).default('done'),
      note: z.string().optional(),
      runTests: z.boolean().default(true),
      testCommand: z.string().optional(),
      timeoutMs: z.number().int().min(1_000).max(900_000).default(DEFAULT_TEST_TIMEOUT_MS),
      maxPatchBytes: z.number().int().min(1_000).max(1_000_000).default(160_000),
    },
    outputSchema: {
      id: z.string(),
      title: z.string(),
      projectPath: z.string(),
      status: z.enum(['done', 'blocked']),
      changedFiles: z.array(z.object(changedFileOutput)),
      stats: z.object({ files: z.number(), insertions: z.number(), deletions: z.number() }),
      verification: z.object(verificationOutput),
      patch: z.string(),
      truncated: z.boolean(),
      finishedAt: z.string(),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, withToolLogging(config, 'change.finish', async ({ changeId, status, note, runTests, testCommand, timeoutMs, maxPatchBytes }) => {
    const changes = readChanges(config);
    const change = findChange(changes, changeId);
    const now = new Date().toISOString();
    if (note) change.notes.push({ ts: now, text: note });

    const verification = await verifyChange(config, change.projectPath, runTests, testCommand, timeoutMs);
    const changedFiles = getChangedFiles(change.projectPath, change.checkpoint);
    const rawPatch = getRawDiff(change.projectPath, change.checkpoint);
    const patch = truncate(rawPatch, maxPatchBytes);
    const stats = diffStats(changedFiles);

    change.status = status;
    change.updatedAt = now;
    change.finishedAt = now;
    change.verification = verification;
    writeChanges(config, changes);
    auditEvent(config, 'change.finish', { id: change.id, status, verification: verification.status, stats });

    return {
      content: [{
        type: 'text' as const,
        text: [
          `Change ${change.id} ${status}.`,
          `Files: ${stats.files}, +${stats.insertions}/-${stats.deletions}.`,
          `Verification: ${verification.status}${verification.command ? ` (${verification.command})` : ''}.`,
        ].join('\n'),
      }],
      structuredContent: {
        id: change.id,
        title: change.title,
        projectPath: change.projectPath,
        status,
        changedFiles,
        stats,
        verification,
        patch,
        truncated: patch.length < rawPatch.length,
        finishedAt: now,
      },
      isError: verification.status === 'failed',
      _meta: { structuredDiff: parseUnifiedDiff(rawPatch) },
    };
  }));

  server.registerTool('process.start', {
    title: 'Start Process',
    description: 'Start a long-running local process for a project and capture logs.',
    inputSchema: {
      projectPath: z.string(),
      command: z.string().min(1),
      name: z.string().optional(),
    },
    outputSchema: processOutput,
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, withToolLogging(config, 'process.start', async ({ projectPath, command, name }) => {
    const root = resolveProject(config, projectPath);
    const record = startManagedProcess(config, root, command, name);
    auditEvent(config, 'process.start', { id: record.id, projectPath: root, command });
    return ok(`Started ${record.id} pid=${record.pid}`, record as unknown as Record<string, unknown>);
  }));

  server.registerTool('process.list', {
    title: 'List Processes',
    description: 'List processes started by the bridge.',
    inputSchema: {
      projectPath: z.string().optional(),
      logLines: z.number().int().min(0).max(500).default(DEFAULT_PROCESS_LOG_LINES),
    },
    outputSchema: {
      processes: z.array(z.object({
        ...processOutput,
        recentLog: z.array(z.string()),
      })),
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, withToolLogging(config, 'process.list', async ({ projectPath, logLines }) => {
    const root = projectPath ? resolveProject(config, projectPath) : undefined;
    const processes = refreshProcesses(config)
      .filter((processRecord) => !root || processRecord.projectPath === root)
      .map((processRecord) => ({
        ...processRecord,
        recentLog: logLines > 0 ? tailLines(processRecord.logFile, logLines) : [],
      }));

    return ok(`${processes.length} managed process${processes.length === 1 ? '' : 'es'}`, { processes });
  }));

  server.registerTool('process.stop', {
    title: 'Stop Process',
    description: 'Stop a process previously started by the bridge.',
    inputSchema: {
      processId: z.string(),
      signal: z.enum(['SIGTERM', 'SIGINT', 'SIGKILL']).default('SIGTERM'),
    },
    outputSchema: {
      id: z.string(),
      stopped: z.boolean(),
      status: z.enum(['running', 'exited', 'unknown']),
    },
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
  }, withToolLogging(config, 'process.stop', async ({ processId, signal }) => {
    const processes = refreshProcesses(config);
    const record = processes.find((item) => item.id === processId);
    if (!record) throw new Error(`Process ${processId} not found`);
    let stopped = false;
    try {
      process.kill(-record.pid, signal);
      stopped = true;
    } catch {
      try {
        process.kill(record.pid, signal);
        stopped = true;
      } catch {
        stopped = false;
      }
    }
    record.status = stopped ? 'exited' : getProcessStatus(record.pid);
    record.updatedAt = new Date().toISOString();
    writeProcesses(config, processes);
    auditEvent(config, 'process.stop', { id: processId, signal, stopped });

    return ok(`${stopped ? 'Stopped' : 'Could not stop'} ${processId}`, {
      id: processId,
      stopped,
      status: record.status,
    });
  }));

  server.registerTool('port.check', {
    title: 'Check Port',
    description: 'Check whether localhost port accepts TCP connections.',
    inputSchema: {
      port: z.number().int().min(1).max(65_535),
      host: z.string().default('127.0.0.1'),
      timeoutMs: z.number().int().min(100).max(10_000).default(1_000),
    },
    outputSchema: {
      host: z.string(),
      port: z.number(),
      open: z.boolean(),
      error: z.string().optional(),
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, withToolLogging(config, 'port.check', async ({ host, port, timeoutMs }) => {
    const result = await checkPort(host, port, timeoutMs);
    return ok(`${host}:${port} ${result.open ? 'open' : 'closed'}`, result);
  }));

  return server;
}

export async function startStdioServer(config: BridgeConfig): Promise<void> {
  const server = createMcpServer(config);
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

function withToolLogging<T>(
  config: BridgeConfig,
  toolName: string,
  handler: (args: T) => Promise<CallToolResult> | CallToolResult,
): (args: T) => Promise<CallToolResult> {
  return async (args: T) => {
    const startedAt = Date.now();
    try {
      const result = await handler(args);
      auditEvent(config, 'tool.call', { tool: toolName, ok: true, durationMs: Date.now() - startedAt });
      return result;
    } catch (err) {
      auditEvent(config, 'tool.call', {
        tool: toolName,
        ok: false,
        durationMs: Date.now() - startedAt,
        error: err instanceof Error ? err.message : String(err),
      });
      throw err;
    }
  };
}

function ok(text: string, structuredContent: Record<string, unknown>, meta?: Record<string, unknown>): CallToolResult {
  return {
    content: [{ type: 'text' as const, text }],
    structuredContent,
    ...(meta ? { _meta: meta } : {}),
  };
}

function commandResponse(result: CommandResult): CallToolResult {
  const text = [
    `$ ${result.command}`,
    `exit=${result.exitCode} duration=${result.durationMs}ms`,
    result.stdout ? `stdout:\n${result.stdout}` : '',
    result.stderr ? `stderr:\n${result.stderr}` : '',
  ].filter(Boolean).join('\n\n');

  return {
    content: [{ type: 'text' as const, text }],
    structuredContent: result as unknown as Record<string, unknown>,
    isError: result.exitCode !== 0,
  };
}

function resolveProject(config: BridgeConfig, projectPath: string): string {
  const resolved = path.resolve(expandHome(projectPath));
  assertAllowedProjectRoot(config, resolved);
  const stat = fs.existsSync(resolved) ? fs.statSync(resolved) : undefined;
  if (!stat?.isDirectory()) throw new Error(`Project path is not a directory: ${projectPath}`);
  return resolved;
}

function resolveInsideProject(config: BridgeConfig, projectPath: string, filePath: string): string {
  const rel = normalizeRel(filePath);
  const resolved = path.resolve(projectPath, rel);
  const relative = path.relative(projectPath, resolved);
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new Error(`Path escapes project: ${filePath}`);
  }
  assertAllowedProjectRoot(config, resolved);
  assertNotDenied(config, relative);
  return resolved;
}

function assertAllowedProjectRoot(config: BridgeConfig, candidate: string): void {
  const allowedRoots = config.policy.allowedProjectRoots.map((root) => path.resolve(expandHome(root)));
  const okRoot = allowedRoots.some((root) => {
    const relative = path.relative(root, candidate);
    return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
  });
  if (!okRoot) {
    throw new Error(`Path outside allowed roots: ${candidate}. Allowed roots: ${allowedRoots.join(', ')}`);
  }
}

function assertNotDenied(config: BridgeConfig, relativePath: string): void {
  const normalized = normalizeRel(relativePath);
  if (isDeniedByBuiltIns(normalized)) throw new Error(`Access denied by policy: ${relativePath}`);
  for (const pattern of config.policy.denyGlobs) {
    if (matchesDenyGlob(pattern, normalized)) throw new Error(`Access denied by policy (${pattern}): ${relativePath}`);
  }
}

function isDeniedByBuiltIns(relativePath: string): boolean {
  const base = path.basename(relativePath);
  return (
    base === '.env'
    || base.startsWith('.env.')
    || base.endsWith('.pem')
    || base.endsWith('.key')
    || base.endsWith('.p12')
    || base.endsWith('.pfx')
    || relativePath.includes('/.ssh/')
    || relativePath.startsWith('.ssh/')
    || base === '.npmrc'
    || base === '.netrc'
  );
}

function matchesDenyGlob(pattern: string, relativePath: string): boolean {
  const normalizedPattern = pattern.replaceAll('\\', '/');
  if (normalizedPattern === '**/.env') return relativePath === '.env' || relativePath.endsWith('/.env');
  if (normalizedPattern === '**/.env.*') return path.basename(relativePath).startsWith('.env.');
  if (normalizedPattern === '**/.ssh/**') return relativePath.startsWith('.ssh/') || relativePath.includes('/.ssh/');
  if (normalizedPattern.startsWith('**/*.')) {
    return relativePath.endsWith(normalizedPattern.slice(4));
  }
  const escaped = normalizedPattern
    .split('**').map((part) => part.replace(/[.+^${}()|[\]\\]/g, '\\$&').replaceAll('*', '[^/]*')).join('.*');
  return new RegExp(`^${escaped}$`).test(relativePath);
}

function expandHome(value: string): string {
  if (value === '~') return os.homedir();
  if (value.startsWith('~/')) return path.join(os.homedir(), value.slice(2));
  return value;
}

function normalizeRel(filePath: string): string {
  return filePath.replaceAll('\\', '/').replace(/^\/+/, '');
}

function readPackageScripts(projectPath: string): Array<{ name: string; command: string }> {
  const packageJson = path.join(projectPath, 'package.json');
  if (!fs.existsSync(packageJson)) return [];
  try {
    const raw = JSON.parse(fs.readFileSync(packageJson, 'utf-8')) as { scripts?: Record<string, string> };
    return Object.entries(raw.scripts ?? {}).map(([name, command]) => ({ name, command }));
  } catch {
    return [];
  }
}

function detectTestCommands(projectPath: string, scripts = readPackageScripts(projectPath)): Array<{ name: string; command: string; confidence: 'high' | 'medium' | 'low' }> {
  const commands: Array<{ name: string; command: string; confidence: 'high' | 'medium' | 'low' }> = [];
  const scriptNames = new Set(scripts.map((script) => script.name));
  const packageManager = detectPackageManager(projectPath);

  for (const name of ['test', 'typecheck', 'lint', 'build']) {
    if (scriptNames.has(name)) commands.push({ name, command: `${packageManager} run ${name}`.replace('npm run test', 'npm test'), confidence: name === 'test' ? 'high' : 'medium' });
  }
  if (fs.existsSync(path.join(projectPath, 'Cargo.toml'))) commands.push({ name: 'cargo test', command: 'cargo test', confidence: 'high' });
  if (fs.existsSync(path.join(projectPath, 'go.mod'))) commands.push({ name: 'go test', command: 'go test ./...', confidence: 'high' });
  if (fs.existsSync(path.join(projectPath, 'pyproject.toml'))) commands.push({ name: 'pytest', command: 'pytest', confidence: 'medium' });
  if (fs.existsSync(path.join(projectPath, 'requirements.txt'))) commands.push({ name: 'pytest', command: 'pytest', confidence: 'low' });

  return commands;
}

function detectPackageManager(projectPath: string): string {
  if (fs.existsSync(path.join(projectPath, 'pnpm-lock.yaml'))) return 'pnpm';
  if (fs.existsSync(path.join(projectPath, 'yarn.lock'))) return 'yarn';
  if (fs.existsSync(path.join(projectPath, 'bun.lockb')) || fs.existsSync(path.join(projectPath, 'bun.lock'))) return 'bun';
  return 'npm';
}

function detectKeyFiles(projectPath: string): string[] {
  const candidates = [
    'AGENTS.md',
    'CLAUDE.md',
    'README.md',
    'package.json',
    'tsconfig.json',
    'vite.config.ts',
    'next.config.js',
    'src/index.ts',
    'src/main.ts',
    'src/App.tsx',
    'Cargo.toml',
    'go.mod',
    'pyproject.toml',
  ];
  return candidates.filter((file) => fs.existsSync(path.join(projectPath, file)));
}

function buildFileTree(config: BridgeConfig, projectPath: string, maxDepth: number, maxFiles: number): {
  entries: Array<{ path: string; type: 'file' | 'directory'; size: number; lines?: number }>;
  totalFiles: number;
  totalLines: number;
  truncated: boolean;
} {
  const entries: Array<{ path: string; type: 'file' | 'directory'; size: number; lines?: number }> = [];
  let totalFiles = 0;
  let totalLines = 0;
  let truncated = false;

  const walk = (dir: string, depth: number) => {
    if (depth > maxDepth || entries.length >= maxFiles) {
      truncated = true;
      return;
    }
    let dirents: fs.Dirent[];
    try {
      dirents = fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name));
    } catch {
      return;
    }

    for (const dirent of dirents) {
      if (entries.length >= maxFiles) {
        truncated = true;
        return;
      }
      if (shouldSkipTreeEntry(dirent.name)) continue;
      const full = path.join(dir, dirent.name);
      const rel = path.relative(projectPath, full).replaceAll('\\', '/');
      if (isDeniedByBuiltIns(rel)) continue;
      try {
        assertNotDenied(config, rel);
      } catch {
        continue;
      }

      if (dirent.isDirectory()) {
        entries.push({ path: rel, type: 'directory', size: 0 });
        walk(full, depth + 1);
      } else if (dirent.isFile()) {
        totalFiles++;
        const stat = fs.statSync(full);
        const lines = isLikelyTextFile(full) && stat.size <= MAX_FILE_BYTES ? countLinesSafe(full) : undefined;
        if (typeof lines === 'number') totalLines += lines;
        entries.push({ path: rel, type: 'file', size: stat.size, lines });
      }
    }
  };

  walk(projectPath, 0);
  return { entries, totalFiles, totalLines, truncated };
}

function shouldSkipTreeEntry(name: string): boolean {
  return new Set([
    '.git',
    'node_modules',
    'dist',
    'build',
    '.next',
    'coverage',
    '.cache',
    '.turbo',
    'target',
    '.venv',
    'venv',
    '__pycache__',
  ]).has(name);
}

function countLinesSafe(file: string): number | undefined {
  try {
    return fs.readFileSync(file, 'utf-8').split('\n').length;
  } catch {
    return undefined;
  }
}

function searchCode(config: BridgeConfig, projectPath: string, query: string, glob: string | undefined, maxMatches: number): Array<{ file: string; line: number; column: number; text: string }> {
  const args = ['--line-number', '--column', '--max-count', String(maxMatches), '--no-heading', '--color', 'never'];
  if (glob) args.push('--glob', glob);
  args.push(query, '.');
  try {
    const output = execFileSync('rg', args, { cwd: projectPath, encoding: 'utf-8', maxBuffer: MAX_OUTPUT_BYTES });
    return parseRgOutput(config, output);
  } catch (err) {
    const status = typeof err === 'object' && err && 'status' in err ? (err as { status?: number }).status : undefined;
    if (status === 1) return [];
    return manualSearch(config, projectPath, query, maxMatches);
  }
}

function parseRgOutput(config: BridgeConfig, output: string): Array<{ file: string; line: number; column: number; text: string }> {
  return output.split('\n').filter(Boolean).flatMap((line) => {
    const match = line.match(/^(.+?):(\d+):(\d+):(.*)$/);
    if (!match) return [];
    const file = normalizeRel(match[1]);
    try {
      assertNotDenied(config, file);
    } catch {
      return [];
    }
    return [{
      file,
      line: parseInt(match[2], 10),
      column: parseInt(match[3], 10),
      text: match[4],
    }];
  });
}

function manualSearch(config: BridgeConfig, projectPath: string, query: string, maxMatches: number): Array<{ file: string; line: number; column: number; text: string }> {
  const matches: Array<{ file: string; line: number; column: number; text: string }> = [];
  const walk = (dir: string) => {
    if (matches.length >= maxMatches) return;
    let dirents: fs.Dirent[];
    try {
      dirents = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const dirent of dirents) {
      if (matches.length >= maxMatches || shouldSkipTreeEntry(dirent.name)) continue;
      const full = path.join(dir, dirent.name);
      const rel = path.relative(projectPath, full).replaceAll('\\', '/');
      if (dirent.isDirectory()) {
        walk(full);
      } else if (dirent.isFile() && isLikelyTextFile(full)) {
        try {
          assertNotDenied(config, rel);
          const lines = fs.readFileSync(full, 'utf-8').split('\n');
          lines.forEach((text, index) => {
            const column = text.indexOf(query);
            if (column >= 0 && matches.length < maxMatches) {
              matches.push({ file: rel, line: index + 1, column: column + 1, text });
            }
          });
        } catch {
          // Skip unreadable or denied files.
        }
      }
    }
  };
  walk(projectPath);
  return matches;
}

function readTextFileRange(
  config: BridgeConfig,
  projectPath: string,
  filePath: string,
  startLine: number | undefined,
  endLine: number | undefined,
  maxLines: number,
): { path: string; startLine: number; endLine: number; totalLines: number; content: string; truncated: boolean } {
  const target = resolveInsideProject(config, projectPath, filePath);
  ensureTextFile(target);
  const raw = fs.readFileSync(target, 'utf-8');
  const lines = raw.split('\n');
  const start = Math.max(1, startLine ?? 1);
  const requestedEnd = Math.min(lines.length, endLine ?? lines.length);
  const boundedEnd = Math.min(requestedEnd, start + maxLines - 1);
  const content = lines.slice(start - 1, boundedEnd).join('\n');
  return {
    path: normalizeRel(filePath),
    startLine: start,
    endLine: boundedEnd,
    totalLines: lines.length,
    content,
    truncated: boundedEnd < requestedEnd,
  };
}

function ensureTextFile(filePath: string): void {
  const stat = fs.existsSync(filePath) ? fs.statSync(filePath) : undefined;
  if (!stat?.isFile()) throw new Error(`Not a file: ${filePath}`);
  if (stat.size > MAX_FILE_BYTES) throw new Error(`File too large: ${filePath}`);
  if (!isLikelyTextFile(filePath)) throw new Error(`Refusing to read binary file: ${filePath}`);
}

function isLikelyTextFile(filePath: string): boolean {
  try {
    const stat = fs.statSync(filePath);
    if (stat.size > MAX_FILE_BYTES) return false;
    const buffer = Buffer.alloc(Math.min(stat.size, 4096));
    const fd = fs.openSync(filePath, 'r');
    fs.readSync(fd, buffer, 0, buffer.length, 0);
    fs.closeSync(fd);
    return !buffer.includes(0);
  } catch {
    return false;
  }
}

function countOccurrences(text: string, needle: string): number {
  if (!needle) return 0;
  let count = 0;
  let index = text.indexOf(needle);
  while (index !== -1) {
    count++;
    index = text.indexOf(needle, index + needle.length);
  }
  return count;
}

async function runProjectCommand(config: BridgeConfig, projectPath: string, command: string, timeoutMs: number, maxOutputBytes: number): Promise<CommandResult> {
  validateShellCommand(config, command);
  const startedAt = Date.now();
  try {
    const { stdout, stderr } = await execAsync(command, {
      cwd: projectPath,
      env: process.env,
      timeout: timeoutMs,
      maxBuffer: maxOutputBytes,
    });
    return {
      command,
      exitCode: 0,
      stdout: truncate(stdout, maxOutputBytes),
      stderr: truncate(stderr, maxOutputBytes),
      durationMs: Date.now() - startedAt,
    };
  } catch (err) {
    const error = err as { code?: number | string; stdout?: string; stderr?: string; killed?: boolean; signal?: string };
    return {
      command,
      exitCode: typeof error.code === 'number' ? error.code : 1,
      stdout: truncate(error.stdout ?? '', maxOutputBytes),
      stderr: truncate(error.stderr ?? String(err), maxOutputBytes),
      durationMs: Date.now() - startedAt,
      timedOut: Boolean(error.killed && error.signal === 'SIGTERM'),
    };
  }
}

function validateShellCommand(config: BridgeConfig, command: string): void {
  if (!config.policy.shell.enabled) throw new Error('Shell commands are disabled by policy');
  for (const pattern of config.policy.shell.denyPatterns) {
    try {
      if (new RegExp(pattern, 'i').test(command)) throw new Error(`Command denied by policy (${pattern}): ${command}`);
    } catch (err) {
      if (err instanceof Error && err.message.startsWith('Command denied')) throw err;
    }
  }
}

async function verifyChange(config: BridgeConfig, projectPath: string, runTests: boolean, testCommand: string | undefined, timeoutMs: number): Promise<VerificationRecord> {
  if (!runTests) return { status: 'not_run', reason: 'runTests=false' };
  const command = testCommand ?? detectTestCommands(projectPath, readPackageScripts(projectPath))[0]?.command;
  if (!command) return { status: 'not_run', reason: 'No test command detected' };
  const result = await runProjectCommand(config, projectPath, command, timeoutMs, MAX_OUTPUT_BYTES);
  return {
    status: result.exitCode === 0 ? 'passed' : 'failed',
    command,
    exitCode: result.exitCode,
    stdout: result.stdout,
    stderr: result.stderr,
  };
}

function diffStats(changedFiles: Array<{ insertions: number; deletions: number }>): { files: number; insertions: number; deletions: number } {
  return {
    files: changedFiles.length,
    insertions: changedFiles.reduce((sum, file) => sum + file.insertions, 0),
    deletions: changedFiles.reduce((sum, file) => sum + file.deletions, 0),
  };
}

function startManagedProcess(config: BridgeConfig, projectPath: string, command: string, name?: string): ProcessRecord {
  validateShellCommand(config, command);
  const id = name ? `${slugify(name)}-${Date.now().toString(36)}` : makeId('proc');
  const logDir = path.join(config.dataDir, 'process-logs');
  fs.mkdirSync(logDir, { recursive: true });
  const logFile = path.join(logDir, `${id}.log`);
  const out = fs.openSync(logFile, 'a');
  const child = spawn(command, {
    cwd: projectPath,
    env: process.env,
    shell: true,
    detached: true,
    stdio: ['ignore', out, out],
  });
  child.unref();

  const now = new Date().toISOString();
  const record: ProcessRecord = {
    id,
    projectPath,
    command,
    pid: child.pid ?? 0,
    logFile,
    status: 'running',
    startedAt: now,
    updatedAt: now,
  };
  const processes = refreshProcesses(config);
  processes.unshift(record);
  writeProcesses(config, processes);
  return record;
}

function refreshProcesses(config: BridgeConfig): ProcessRecord[] {
  const processes = readProcesses(config);
  const now = new Date().toISOString();
  const refreshed = processes.map((record) => ({
    ...record,
    status: getProcessStatus(record.pid),
    updatedAt: now,
  }));
  writeProcesses(config, refreshed);
  return refreshed;
}

function getProcessStatus(pid: number): ProcessRecord['status'] {
  if (!pid) return 'unknown';
  try {
    process.kill(pid, 0);
    return 'running';
  } catch {
    return 'exited';
  }
}

function tailLines(filePath: string, lines: number): string[] {
  try {
    return fs.readFileSync(filePath, 'utf-8').split('\n').slice(-lines).filter(Boolean);
  } catch {
    return [];
  }
}

async function checkPort(host: string, port: number, timeoutMs: number): Promise<{ host: string; port: number; open: boolean; error?: string }> {
  return new Promise((resolve) => {
    const socket = net.createConnection({ host, port });
    const done = (open: boolean, error?: string) => {
      socket.destroy();
      resolve({ host, port, open, ...(error ? { error } : {}) });
    };
    socket.setTimeout(timeoutMs);
    socket.once('connect', () => done(true));
    socket.once('timeout', () => done(false, 'timeout'));
    socket.once('error', (err) => done(false, err.message));
  });
}

function readChanges(config: BridgeConfig): ChangeRecord[] {
  return readJsonFile<ChangeRecord[]>(path.join(config.dataDir, 'changes.json'), []);
}

function writeChanges(config: BridgeConfig, changes: ChangeRecord[]): void {
  writeJsonFile(path.join(config.dataDir, 'changes.json'), changes);
}

function findChange(changes: ChangeRecord[], changeId: string): ChangeRecord {
  const change = changes.find((item) => item.id === changeId);
  if (!change) throw new Error(`Change ${changeId} not found`);
  return change;
}

function readProcesses(config: BridgeConfig): ProcessRecord[] {
  return readJsonFile<ProcessRecord[]>(path.join(config.dataDir, 'processes.json'), []);
}

function writeProcesses(config: BridgeConfig, processes: ProcessRecord[]): void {
  writeJsonFile(path.join(config.dataDir, 'processes.json'), processes);
}

function readJsonFile<T>(filePath: string, fallback: T): T {
  try {
    if (!fs.existsSync(filePath)) return fallback;
    return JSON.parse(fs.readFileSync(filePath, 'utf-8')) as T;
  } catch {
    return fallback;
  }
}

function writeJsonFile(filePath: string, data: unknown): void {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(data, null, 2)}\n`, 'utf-8');
}

function auditEvent(config: BridgeConfig, event: string, data: Record<string, unknown>): void {
  try {
    fs.mkdirSync(config.dataDir, { recursive: true });
    const line = JSON.stringify({ ts: new Date().toISOString(), event, ...data });
    fs.appendFileSync(path.join(config.dataDir, 'audit.jsonl'), `${line}\n`, 'utf-8');
  } catch {
    // Audit should not break the tool call.
  }
}

function auditFileOperation(config: BridgeConfig, operation: string, projectPath: string, files: string[]): void {
  auditEvent(config, operation, {
    projectPath,
    files: files.map(normalizeRel),
  });
}

function sha256(text: string): string {
  return createHash('sha256').update(text).digest('hex');
}

function truncate(text: string, maxBytes: number): string {
  const buffer = Buffer.from(text);
  if (buffer.length <= maxBytes) return text;
  return `${buffer.subarray(0, maxBytes).toString('utf-8')}\n[truncated ${buffer.length - maxBytes} bytes]`;
}

function makeId(prefix: string): string {
  return `${prefix}_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

function slugify(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'process';
}
