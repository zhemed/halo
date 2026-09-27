#!/usr/bin/env node
/**
 * Trellis PreToolUse 闸门 —— 强制"任何工具动作之前，本轮必须先建 Trellis 任务"。
 *
 * 由来：2026-09-26 用户抓出"先动手、后补任务"（TRELLIS-MANDATORY 第 1/6/7 条）。
 *       仅靠自觉不牢靠，故做成机器可强制的闸门。
 *
 * 契约（读 @deepseek-ai/dsh-hook-protocol 与 dsh-hooks-claude-code 得出）：
 *   - stdin  = {session_id, turn, cwd, hook_event_name:"PreToolUse", tool_name, tool_input, tool_use_id}
 *   - exit 0 = 放行
 *   - exit 2 = **阻断**，stderr 内容作为阻断理由回给模型
 *   - 任何内部错误一律放行（fail-open），绝不让闸门本身破坏会话
 *
 * 判定逻辑（刻意做成确定性的，不交给模型判断）：
 *   1. 从 cwd 向上找 .trellis/；没有 → 放行（非 Trellis 项目）
 *   2. 命令本身是 `task.py create`（或 start）→ 放行（这正是我们要鼓励的动作）
 *   3. 本轮（按 turn）是否已建过任务？判据：.trellis/tasks/<slug>/prd.md 的 mtime
 *      晚于本 turn 的起始时间。是 → 放行；否 → 阻断
 *
 * 关闭开关：export TRELLIS_GATE=off，或 touch ~/.dsh/hooks/trellis-gate-disabled
 * 自查一次：node trellis-pre-tool-gate.mjs --selftest
 */

import { existsSync, readFileSync, writeFileSync, statSync, readdirSync, appendFileSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';

const KILL_SWITCH = join(homedir(), '.dsh/hooks/trellis-gate-disabled');
const LOG = join(homedir(), '.dsh/hooks/trellis-gate.log');
const STATE_FILE = join(homedir(), '.dsh/hooks/trellis-gate-state.json');

const ALLOW = 0;
const BLOCK = 2;

function log(entry) {
  try {
    appendFileSync(LOG, `${new Date().toISOString()} ${JSON.stringify(entry)}\n`);
  } catch {
    /* 日志失败不影响判定 */
  }
}

function findTrellisRoot(start) {
  let dir = resolve(start || process.cwd());
  for (let i = 0; i < 12; i += 1) {
    if (existsSync(join(dir, '.trellis'))) return dir;
    const up = dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  return null;
}

/** 最近一次"建任务"的迹象：任一任务目录下 prd.md 的 mtime。 */
function latestPrdMtime(root) {
  const tasksDir = join(root, '.trellis/tasks');
  let newest = 0;
  try {
    for (const name of readdirSync(tasksDir)) {
      if (name === 'archive') continue;
      const prd = join(tasksDir, name, 'prd.md');
      try {
        const st = statSync(prd);
        if (st.mtimeMs > newest) newest = st.mtimeMs;
      } catch {
        /* 没有 prd 的任务不算 */
      }
    }
  } catch {
    /* 无 tasks 目录 */
  }
  return newest;
}

function loadState() {
  try {
    return JSON.parse(readFileSync(STATE_FILE, 'utf8'));
  } catch {
    return {};
  }
}

function saveState(state) {
  try {
    mkdirSync(dirname(STATE_FILE), { recursive: true });
    writeFileSync(STATE_FILE, JSON.stringify(state));
  } catch {
    /* 状态写不了就退化为"每次调用都算新轮次"，宁可多提醒不放过 */
  }
}

function commandText(toolInput) {
  if (!toolInput || typeof toolInput !== 'object') return '';
  const cmd = toolInput.command ?? toolInput.cmd ?? '';
  return typeof cmd === 'string' ? cmd : JSON.stringify(toolInput);
}

function isTaskCreation(cmd) {
  return /task\.py\s+(create|start)\b/.test(cmd);
}

/** 返回 {decision, reason} —— 决策与理由分离，便于测试与日志。 */
function decide(payload, now) {
  const cwd = payload.cwd || process.cwd();
  const root = findTrellisRoot(cwd);
  if (!root) return { decision: 'allow', reason: 'not-trellis-project' };

  const cmd = commandText(payload.tool_input);
  if (isTaskCreation(cmd)) return { decision: 'allow', reason: 'task-creation' };

  const sessionId = payload.session_id || 'unknown';
  const turn = String(payload.turn ?? 0);
  const state = loadState();
  const prev = state[sessionId];
  const isNewTurn = !prev || String(prev.turn) !== turn;
  const turnStart = isNewTurn ? now : prev.since;

  state[sessionId] = { turn, since: turnStart };
  saveState(state);

  const prdMtime = latestPrdMtime(root);
  if (prdMtime > turnStart) return { decision: 'allow', reason: 'task-created-this-turn', root };

  return { decision: 'block', reason: 'no-task-this-turn', root, turn };
}

const BLOCK_MESSAGE = `
[trellis-gate] 本轮还没有建 Trellis 任务，工具调用被拦截。

规则（TRELLIS-MANDATORY 第 1/6/7 条）：任何会话工作——包括只读调查、包括"我只是问一句"——
第一步永远是建任务，且不得后补。请按顺序做：

  python3 .trellis/scripts/task.py create "<标题>" --slug <slug> -d "<描述>"

然后立刻把 .trellis/tasks/<MM-DD-slug>/prd.md 的内容写完整，再继续原本要做的事。

若本轮用户明确说"跳过 Trellis"，或确认这是误判：export TRELLIS_GATE=off 后重试，
并告知用户闸门被关闭。
`.trim();

// ---------- 自测：不依赖 DSH，直接喂构造载荷 ----------
const args = process.argv.slice(2);
if (args[0] === '--selftest') {
  const now = Date.now();
  const cases = [
    ['非 Trellis 项目', { cwd: '/tmp', session_id: 's1', turn: 1, tool_input: { command: 'ls' } }, 'allow'],
    ['建任务命令', { cwd: process.cwd(), session_id: 's2', turn: 1, tool_input: { command: 'python3 .trellis/scripts/task.py create "x"' } }, 'allow'],
    ['新轮次首个其它命令', { cwd: process.cwd(), session_id: 's3', turn: 9, tool_input: { command: 'docker ps' } }, 'block'],
  ];
  let failed = 0;
  for (const [name, payload, expected] of cases) {
    const { decision, reason } = decide(payload, now);
    const pass = decision === expected;
    if (!pass) failed += 1;
    console.log(`  ${pass ? '✓' : '✗'} ${name} → ${decision} (${reason})，期望 ${expected}`);
  }
  console.log(failed === 0 ? '自测通过' : `自测失败 ${failed} 项`);
  process.exit(failed === 0 ? 0 : 1);
}

// ---------- 正常模式：读 stdin 载荷 ----------
let raw = '';
try {
  raw = readFileSync(0, 'utf8');
} catch {
  process.exit(ALLOW);
}

try {
  if (existsSync(KILL_SWITCH) || process.env.TRELLIS_GATE === 'off') {
    log({ skipped: true, by: 'kill-switch-or-env' });
    process.exit(ALLOW);
  }
  // 埋点：证明钩子被真实调用过（与手工模拟区分开）
  try { appendFileSync('/root/.dsh/hooks/pre-tool-fired.log', `${new Date().toISOString()} ${raw.slice(0,200)}\n`); } catch {}
  const payload = JSON.parse(raw || '{}');
  if (payload.hook_event_name && payload.hook_event_name !== 'PreToolUse') process.exit(ALLOW);

  const { decision, reason, root, turn } = decide(payload, Date.now());
  log({
    decision,
    reason,
    turn,
    tool: payload.tool_name,
    root,
    cmd: commandText(payload.tool_input).slice(0, 160),
  });

  if (decision === 'block') {
    process.stderr.write(`${BLOCK_MESSAGE}\n`);
    process.exit(BLOCK);
  }
  process.exit(ALLOW);
} catch (err) {
  // fail-open：闸门自身出错绝不阻塞会话
  log({ decision: 'allow', reason: 'gate-error', error: String(err && err.message) });
  process.exit(ALLOW);
}
