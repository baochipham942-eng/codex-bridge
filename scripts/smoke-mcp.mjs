#!/usr/bin/env node
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-bridge-smoke-'));
const project = path.join(tmpRoot, 'test-project');
const dataDir = path.join(tmpRoot, 'data');
const logDir = path.join(tmpRoot, 'logs');
const policyPath = path.join(tmpRoot, 'bridge.policy.json');

const expectedTools = [
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

function writeJson(file, value) {
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, 'utf-8');
}

function run(command, args, options = {}) {
  execFileSync(command, args, {
    stdio: 'pipe',
    encoding: 'utf-8',
    ...options,
  });
}

async function mcpExchange(messages) {
  const child = spawn(process.execPath, ['dist/index.js'], {
    cwd: root,
    env: {
      ...process.env,
      CODEX_BRIDGE_DATA_DIR: dataDir,
      CODEX_BRIDGE_LOG_DIR: logDir,
      CODEX_BRIDGE_POLICY_PATH: policyPath,
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => { stdout += chunk.toString(); });
  child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });

  for (const message of messages) {
    child.stdin.write(`${JSON.stringify(message)}\n`);
  }
  child.stdin.end();

  const exitCode = await new Promise((resolve) => {
    child.on('close', resolve);
  });
  if (exitCode !== 0) {
    throw new Error(`MCP server exited ${exitCode}\n${stderr}`);
  }
  return stdout
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function initMessages(extra = []) {
  return [
    {
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {
        protocolVersion: '2025-06-18',
        capabilities: {},
        clientInfo: { name: 'smoke', version: '0.1.0' },
      },
    },
    { jsonrpc: '2.0', method: 'notifications/initialized' },
    ...extra,
  ];
}

async function callTool(name, args) {
  const messages = await mcpExchange(initMessages([{
    jsonrpc: '2.0',
    id: 2,
    method: 'tools/call',
    params: { name, arguments: args },
  }]));
  return messages.find((message) => message.id === 2);
}

try {
  fs.mkdirSync(project, { recursive: true });
  fs.mkdirSync(dataDir, { recursive: true });
  fs.mkdirSync(logDir, { recursive: true });
  writeJson(policyPath, {
    allowedProjectRoots: [tmpRoot],
    denyGlobs: ['**/.env', '**/.env.*', '**/*.pem', '**/*.key', '**/.ssh/**'],
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
        'curl\\s+[^|;]*\\|\\s*(sh|bash|zsh)',
        'wget\\s+[^|;]*\\|\\s*(sh|bash|zsh)',
      ],
    },
  });

  writeJson(path.join(project, 'package.json'), {
    type: 'module',
    scripts: {
      test: 'node test.js',
      typecheck: 'node -e "console.log(\'typecheck ok\')"',
    },
  });
  fs.writeFileSync(path.join(project, 'math.js'), [
    'export function add(a, b) {',
    '  return a + b;',
    '}',
    '',
  ].join('\n'));
  fs.writeFileSync(path.join(project, 'test.js'), [
    "import { add } from './math.js';",
    "if (add('2', 3) !== 5) throw new Error('add failed');",
    "console.log('test ok');",
    '',
  ].join('\n'));

  run('git', ['init', '-q'], { cwd: project });
  run('git', ['config', 'user.email', 'test@example.com'], { cwd: project });
  run('git', ['config', 'user.name', 'test'], { cwd: project });
  run('git', ['add', '.'], { cwd: project });
  run('git', ['commit', '-q', '-m', 'init'], { cwd: project });

  console.log('== tools/list ==');
  const listMessages = await mcpExchange(initMessages([{
    jsonrpc: '2.0',
    id: 2,
    method: 'tools/list',
    params: {},
  }]));
  const serverInfo = listMessages.find((message) => message.id === 1).result.serverInfo;
  assert.equal(serverInfo.name, 'codex-bridge');
  console.log(`server=${serverInfo.name} version=${serverInfo.version}`);
  const tools = listMessages.find((message) => message.id === 2).result.tools.map((tool) => tool.name);
  for (const expected of expectedTools) assert.ok(tools.includes(expected), `missing ${expected}`);
  for (const oldName of ['shell.exec', 'codex_app_start', 'workspace.add', 'task.start', 'project.snapshot']) {
    assert.ok(!tools.includes(oldName), `old/high-risk tool still exposed: ${oldName}`);
  }
  console.log(`tools=${tools.sort().join(', ')}`);

  console.log('== inspect/read/patch/test/diff/change ==');
  const changeStart = await callTool('change.start', { projectPath: project, title: 'smoke change', note: 'start' });
  const changeId = changeStart.result.structuredContent.id;

  const inspect = await callTool('workspace.inspect', { projectPath: project, maxDepth: 3, maxFiles: 80 });
  const inspectContent = inspect.result.structuredContent;
  assert.equal(inspectContent.isGitRepo, true);
  assert.ok(inspectContent.testCommands.some((item) => item.command === 'npm test'));
  console.log(`inspect files=${inspectContent.totalFiles} scripts=${inspectContent.scripts.length} tests=${inspectContent.testCommands.length}`);

  const read = await callTool('code.read', { projectPath: project, files: [{ path: 'math.js' }], maxLinesPerFile: 20 });
  const content = read.result.structuredContent.files[0].content;
  assert.match(content, /return a \+ b/);
  console.log(content);

  const patch = await callTool('file.patch', {
    projectPath: project,
    file: 'math.js',
    oldText: '  return a + b;',
    newText: '  return Number(a) + Number(b);',
  });
  assert.equal(patch.result.structuredContent.replacements, 1);
  console.log(`patched replacements=${patch.result.structuredContent.replacements} changed=${patch.result.structuredContent.changedFiles.length}`);

  const test = await callTool('test.run', { projectPath: project });
  assert.equal(test.result.structuredContent.exitCode, 0);
  assert.match(test.result.structuredContent.stdout, /test ok/);
  console.log(`test exit=${test.result.structuredContent.exitCode}`);

  const diff = await callTool('git.diff', { projectPath: project });
  assert.equal(diff.result.structuredContent.stats.files, 1);
  assert.match(diff.result.structuredContent.patch, /Number\(a\)/);
  console.log(`diff files=${diff.result.structuredContent.stats.files} insertions=${diff.result.structuredContent.stats.insertions} deletions=${diff.result.structuredContent.stats.deletions}`);

  const finish = await callTool('change.finish', { changeId, status: 'done', note: 'finish', runTests: true });
  assert.equal(finish.result.structuredContent.status, 'done');
  assert.equal(finish.result.structuredContent.verification.status, 'passed');
  console.log(`finish status=${finish.result.structuredContent.status} verification=${finish.result.structuredContent.verification.status}`);

  console.log('== policy denial ==');
  fs.writeFileSync(path.join(project, '.env'), 'SECRET=1\n');
  const denied = await callTool('code.read', { projectPath: project, files: [{ path: '.env' }] });
  const deniedText = denied.result.content.map((item) => item.text ?? '').join('\n');
  assert.equal(denied.result.isError, true);
  assert.match(deniedText, /Access denied/);
  console.log(`denied=${deniedText}`);

  console.log('== bridge.status ==');
  const status = await callTool('bridge.status', {});
  assert.equal(status.result.structuredContent.service, 'codex-bridge');
  console.log(`status service=${status.result.structuredContent.service} changes=${status.result.structuredContent.changeCount} processes=${status.result.structuredContent.processCount}`);

  console.log('Codex Bridge MCP smoke passed.');
} finally {
  fs.rmSync(tmpRoot, { recursive: true, force: true });
}
