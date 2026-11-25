// unattended-guard.ts: budgets, command/path guard and PATH REPAIR for pi.
//
//   PI_GUARD=1    full guard (nightshift sets this): turn/time/repeat budgets, dangerous-command and
//                 protected-path blocks, plus path repair.
//   PI_PATHFIX=1  path repair only, for interactive use: pi -e <this file>
//
// Path repair: small local models garble paths ("k My-app-x/src/lib/a.ts", a stray project-folder
// prefix, wrong case, an absolute path into a different checkout). For read/edit/write the guard rewrites
// the path argument (event.input is mutable) to the file that really exists under the root: longest
// existing suffix, case-insensitive per segment, then a unique basename. A note is appended to the tool
// result so the model learns the correct path. Unfixable misses get suggestions; after
// PI_GUARD_MAX_PATH_MISSES misses the session ends early instead of burning the time budget.
// Repairs and misses are logged to PI_GUARD_LOG; nightshift feeds them into the next attempt's prompt.
//
// Pane mode (`ns run --tmux` runs pi's own interactive screen in a tmux pane):
//   PI_GUARD_FINAL=<file>      the last assistant message is written there after every run (the
//                              harness reads the DONE/STUCK line from it; print mode has stdout)
//   PI_GUARD_EXIT_ON_SETTLE=1  quit pi once the agent has settled, as `pi -p` would
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"; // type-only; erased at load
import { appendFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";

const env = process.env;
const num = (v: string | undefined, d: number) => (v && Number.isFinite(Number(v)) ? Number(v) : d);

const ACTIVE = env.PI_GUARD === "1";
const REPAIR = (ACTIVE || env.PI_PATHFIX === "1") && env.PI_GUARD_REPAIR_PATHS !== "0";
const MAX_TURNS = num(env.PI_GUARD_MAX_TURNS, 50);           // adapter was RL-trained with a 50-step cap
const MAX_MS = num(env.PI_GUARD_MAX_MINUTES, 65) * 60_000;   // keep below the runner's hard timeout
const BASH_TIMEOUT_S = num(env.PI_GUARD_BASH_TIMEOUT, 300);  // bash tool has no default timeout
const MAX_STREAK = num(env.PI_GUARD_MAX_REPEATS, 3);         // same call N times in a row = stuck
const MAX_PATH_MISSES = num(env.PI_GUARD_MAX_PATH_MISSES, 8); // unfixable wrong paths before giving up
const ALLOW_INSTALL = env.PI_GUARD_ALLOW_INSTALL === "1";
const ROOT = resolve(env.PI_GUARD_ROOT ?? process.cwd());
const LOG = env.PI_GUARD_LOG;
const FINAL = env.PI_GUARD_FINAL;
const EXIT_ON_SETTLE = env.PI_GUARD_EXIT_ON_SETTLE === "1";
const PROTECT = (env.PI_GUARD_PROTECT ?? "").split(",").map((s) => s.trim().replace(/\\/g, "/")).filter(Boolean);

const DANGEROUS: Array<[RegExp, string]> = [
  [/\brm\s+(-\S+\s+)*(\/|~|\$HOME|\.\.|[A-Za-z]:|\S*\.git\b|\*)/i, "rm outside the project or on .git; use relative paths"],
  [/\bgit\s+(push|commit|reset|rebase|clean|remote|config|filter-branch|update-ref|tag|stash|checkout\s+-f)\b/i, "git state is owned by the harness"],
  [/\b(curl|wget)\b(?![^|;&]*\b(localhost|127\.0\.0\.1|llm-gw)\b)/i, "network access is not allowed"],
  [/\b(Invoke-WebRequest|Invoke-RestMethod|iwr|irm|Start-BitsTransfer)\b/i, "network access is not allowed"],
  [/\b(sudo|runas|doas)\b/i, "privilege escalation"],
  [/\bchmod\s+(-R\s+)?0?777\b|\bchown\b/i, "permission change"],
  [/\b(ssh|scp|sftp|rsync|nc|ncat|netcat|telnet)\b/i, "remote access"],
  [/\b(npm|pnpm|yarn)\s+publish\b|\bdocker(\.exe)?\s+\w|\bwsl(\.exe)?\s|\bpodman\s+\w/i, "publishing or container control"],
  [/\b(taskkill|Stop-Process|pkill|killall|shutdown|Restart-Computer)\b/i, "process control (could kill llama-server)"],
  [/\bRemove-Item\b[^|;]*-Recurse|\b(del|erase)\s+\/[sq]|\b(rmdir|rd)\s+\/s|\bformat(\.com)?\s+[A-Za-z]:/i, "recursive delete"],
  [/\breg(\.exe)?\s+(add|delete)\b|\bSet-ExecutionPolicy\b|\bschtasks\b|\bsetx\b/i, "system configuration"],
  [/\|\s*(ba|z|da)?sh\b|\|\s*(iex|Invoke-Expression)\b/i, "piping into a shell"],
];
const INSTALL = /\b(npm|pnpm|yarn|bun)\s+(i|install|add)\b|\bpip3?\s+install\b|\buv\s+(add|pip)\b|\bcargo\s+(add|install)\b|\bgo\s+(get|install)\b/i;
const PROTECTED = [/(^|\/)\.git(\/|$)/i, /(^|\/)\.env(\.|$)/i, /(^|\/)\.pi(\/|$)/i, /(^|\/)\.github\/workflows\//i, /(^|\/)(AGENTS|CLAUDE)\.md$/i];
const BASH_PATH_ERR = /No such file or directory|ENOENT|cannot find path|cannot access '|The system cannot find the (file|path)/i;
const PATH_TOOLS = new Set(["read", "edit", "write"]);

// ------------------------------------------------------------------ path helpers
const SKIP_DIRS = new Set([".git", "node_modules", "dist", "build", ".next", "__pycache__", ".venv", "venv", "target", ".cache", "coverage"]);
const isFile = (a: string) => { try { return statSync(a).isFile(); } catch { return false; } };
const isDir = (a: string) => { try { return statSync(a).isDirectory(); } catch { return false; } };
const toRel = (a: string) => relative(ROOT, a).replace(/\\/g, "/");
const inside = (a: string) => { const r = relative(ROOT, a); return !r.startsWith("..") && !isAbsolute(r); };

let index: string[] | undefined;
function files(): string[] {
  if (index) return index;
  const out: string[] = [];
  const walk = (dir: string, depth: number) => {
    if (out.length > 20000 || depth > 12) return;
    let ents: any[];
    try { ents = readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      if (e.isDirectory()) { if (!SKIP_DIRS.has(e.name)) walk(join(dir, e.name), depth + 1); }
      else out.push(toRel(join(dir, e.name)));
    }
  };
  walk(ROOT, 0);
  return (index = out);
}

/** Split a garbled path into clean segments: drops drive letters, stray whitespace/newlines and ".". */
export function segments(p: string): string[] {
  return p.replace(/^\s*[A-Za-z]:/, "").split(/[\\/]+/).map((s) => s.trim()).filter((s) => s && s !== ".");
}

/** Resolve segments under ROOT, matching each segment case-insensitively when the exact name is missing. */
function walkCI(parts: string[]): string | undefined {
  let cur = ROOT;
  for (const part of parts) {
    if (part === "..") return undefined;
    const exact = join(cur, part);
    if (isFile(exact) || isDir(exact)) { cur = exact; continue; }
    let names: string[];
    try { names = readdirSync(cur); } catch { return undefined; }
    const m = names.filter((n) => n.toLowerCase() === part.toLowerCase());
    if (m.length !== 1) return undefined;
    cur = join(cur, m[0]);
  }
  return cur;
}

/** mode "existing": the file must exist (read/edit). mode "new": its parent directory must exist (write).
 *  fine = the path is usable as given; fixed = a corrected path relative to ROOT. */
export function repairPath(raw: string, mode: "existing" | "new"): { fixed?: string; fine: boolean } {
  const abs = resolve(process.cwd(), raw);
  if (inside(abs) && (mode === "existing" ? isFile(abs) || isDir(abs) : isDir(dirname(abs)))) return { fine: true };
  const parts = segments(raw);
  if (!parts.length) return { fine: false };
  // A new file in a new sub-directory of an existing top-level folder (src/lib/newdir/x.ts) is legitimate.
  if (mode === "new" && !isAbsolute(raw) && inside(abs) && isDir(join(ROOT, parts[0]))) return { fine: true };
  for (let i = 0; i < parts.length; i++) {
    const suf = parts.slice(i);
    if (mode === "existing") {
      const t = walkCI(suf);
      if (t && isFile(t)) return { fixed: toRel(t), fine: false };
    } else if (suf.length >= 2) {
      const parent = walkCI(suf.slice(0, -1));
      if (parent && isDir(parent)) return { fixed: toRel(join(parent, suf[suf.length - 1])), fine: false };
    }
  }
  if (mode === "existing") {
    const base = parts[parts.length - 1].toLowerCase();
    const hits = files().filter((f) => basename(f).toLowerCase() === base);
    if (hits.length === 1) return { fixed: hits[0], fine: false };
  }
  return { fine: false };
}

function lev(a: string, b: string): number {
  const d = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    let prev = d[0]; d[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const t = d[j];
      d[j] = Math.min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] === b[j - 1] ? 0 : 1));
      prev = t;
    }
  }
  return d[b.length];
}

export function suggestions(raw: string, n = 5): string[] {
  const parts = segments(raw);
  const base = (parts[parts.length - 1] ?? "").toLowerCase();
  if (!base) return [];
  const all = files();
  const same = all.filter((f) => basename(f).toLowerCase() === base);
  if (same.length) return same.slice(0, n);
  const cap = Math.max(2, Math.floor(base.length / 4));
  return all.map((f) => [f, lev(basename(f).toLowerCase(), base)] as [string, number])
    .filter(([, d]) => d <= cap).sort((x, y) => x[1] - y[1]).slice(0, n).map(([f]) => f);
}

function topLevel(): string {
  try { return readdirSync(ROOT).filter((x) => !SKIP_DIRS.has(x)).slice(0, 25).join(", "); } catch { return ""; }
}

/** The text of the last assistant message in an agent_end message list, or undefined if there is none. */
export function lastAssistantText(messages: unknown): string | undefined {
  if (!Array.isArray(messages)) return undefined;
  for (let i = messages.length - 1; i >= 0; i--) {
    const m: any = messages[i];
    if (m?.role !== "assistant") continue;
    if (typeof m.content === "string") return m.content;
    if (Array.isArray(m.content)) {
      return m.content.filter((c: any) => c?.type === "text" && typeof c.text === "string").map((c: any) => c.text).join("\n");
    }
  }
  return undefined;
}

// ------------------------------------------------------------------ extension
export default function (pi: ExtensionAPI) {
  if (!ACTIVE && !REPAIR && !FINAL && !EXIT_ON_SETTLE) return;
  let turns = 0;
  let startedAt = Date.now();
  let stopped: string | undefined;
  let lastKey = "";
  let streak = 0;
  let misses = 0;
  const notes = new Map<string, string>(); // toolCallId (or tool name) -> note appended to that result

  const log = (rec: Record<string, unknown>) => {
    if (!LOG) return;
    try { appendFileSync(LOG, JSON.stringify({ t: new Date().toISOString(), turn: turns, ...rec }) + "\n"); } catch { /* never break the run */ }
  };
  const stop = (reason: string) => { if (!stopped) { stopped = reason; log({ kind: "stop", reason }); } };
  const short = (input: Record<string, unknown>) =>
    Object.fromEntries(Object.entries(input).map(([k, v]) => [k, typeof v === "string" && v.length > 300 ? v.slice(0, 300) + "..." : v]));
  const rootHint = () => `Your working directory is the repository root. Use paths relative to it (like src/...), ` +
    `never the project folder name or an absolute path. Top-level entries: ${topLevel()}`;
  const keyOf = (event: any) => String(event.toolCallId ?? event.toolName);

  pi.on("agent_start", async () => { startedAt = Date.now(); log({ kind: "start", root: ROOT, maxTurns: MAX_TURNS, active: ACTIVE, repair: REPAIR }); });

  // Pane mode: keep the final answer where the harness can read it, and quit like `pi -p` does.
  pi.on("agent_end", async (event: any) => {
    if (!FINAL) return;
    const text = lastAssistantText(event.messages);
    if (text === undefined) return;
    try { writeFileSync(FINAL, text + "\n"); } catch { /* never break the run */ }
  });
  pi.on("agent_settled", async (event: any, ctx) => {
    if (!EXIT_ON_SETTLE) return;
    log({ kind: "exit_on_settle", aborted: Boolean(event?.aborted) });
    ctx.shutdown();
  });

  pi.on("turn_start", async (_event, ctx) => {
    turns += 1;
    if (!ACTIVE) return;
    if (turns > MAX_TURNS) stop(`turn budget of ${MAX_TURNS} exhausted`);
    else if (Date.now() - startedAt > MAX_MS) stop(`wall-clock budget of ${MAX_MS / 60_000} min exhausted`);
    if (stopped) ctx.abort();
  });

  pi.on("tool_call", async (event: any, _ctx) => {
    const name = String(event.toolName);
    const input = (event.input ?? {}) as Record<string, any>;
    if (ACTIVE) log({ kind: "tool_call", tool: name, input: short(input) });

    if (stopped) return { block: true, reason: `Harness: ${stopped}. Stop now and reply with a line starting STUCK:.`, terminate: true };

    if (ACTIVE) {
      const key = name + ":" + JSON.stringify(input);
      streak = key === lastKey ? streak + 1 : 1;
      lastKey = key;
      if (streak >= MAX_STREAK) {
        stop(`identical ${name} call repeated ${streak} times in a row`);
        return { block: true, reason: `Harness: ${stopped}.`, terminate: true };
      }
      if (name === "bash" || name === "powershell") {
        const cmd = String(input.command ?? "");
        for (const [re, why] of DANGEROUS) {
          if (re.test(cmd)) { log({ kind: "blocked", tool: name, why, cmd }); return { block: true, reason: `Blocked by harness: ${why}.` }; }
        }
        if (!ALLOW_INSTALL && INSTALL.test(cmd)) {
          log({ kind: "blocked", tool: name, why: "install", cmd });
          return { block: true, reason: "Blocked by harness: dependencies are pre-installed and there is no network. Use what is already available." };
        }
        const t = Number(input.timeout);
        if (!Number.isFinite(t) || t <= 0 || t > BASH_TIMEOUT_S) input.timeout = BASH_TIMEOUT_S; // event.input is mutable
      }
    }

    // ---- path repair (before the path policy, so a repaired path is still checked against it)
    const pkey = typeof input.path === "string" ? "path" : typeof input.file_path === "string" ? "file_path" : undefined;
    if (REPAIR && pkey && PATH_TOOLS.has(name)) {
      const raw = String(input[pkey]);
      const r = repairPath(raw, name === "write" ? "new" : "existing");
      if (r.fixed) {
        input[pkey] = r.fixed;
        log({ kind: "path_repaired", tool: name, from: raw, to: r.fixed });
        notes.set(keyOf(event), `[harness] '${raw}' does not exist; used '${r.fixed}' instead. Use exactly '${r.fixed}' from now on.`);
      } else if (!r.fine && name !== "write") {
        misses += 1;
        const sug = suggestions(raw);
        log({ kind: "path_miss", tool: name, path: raw, suggestions: sug });
        notes.set(keyOf(event), `[harness] '${raw}' does not exist.` + (sug.length ? ` Did you mean: ${sug.join(", ")}?` : "") + ` ${rootHint()}`);
        if (ACTIVE && misses >= MAX_PATH_MISSES) stop(`${misses} reads/edits of files that do not exist`);
      }
    }

    if (ACTIVE && pkey) {
      const rel = toRel(resolve(process.cwd(), String(input[pkey])));
      if (rel.startsWith("..") || isAbsolute(rel)) {
        log({ kind: "blocked", tool: name, why: "outside root", rel });
        return { block: true, reason: `Blocked by harness: stay inside the project directory. ${rootHint()}` };
      }
      if ((name === "write" || name === "edit") &&
          (PROTECTED.some((re) => re.test(rel)) || PROTECT.some((pre) => rel.startsWith(pre)))) {
        log({ kind: "blocked", tool: name, why: "protected", rel });
        return { block: true, reason: `Blocked by harness: ${rel} is read-only. Change the implementation, not the tests or config.` };
      }
    }
    if (name === "write") index = undefined; // file list changed
    return undefined;
  });

  // Append repair notes and hints to the result the model sees (tool_result handlers may patch content).
  pi.on("tool_result", async (event: any, _ctx) => {
    const name = String(event.toolName);
    let note = notes.get(keyOf(event));
    notes.delete(keyOf(event));
    if (!note && (name === "bash" || name === "powershell")) {
      const text = (event.content ?? []).map((c: any) => (typeof c?.text === "string" ? c.text : "")).join("\n");
      if (BASH_PATH_ERR.test(text)) {
        note = `[harness] A path was not found. ${rootHint()}`;
        log({ kind: "bash_path_error", cmd: String(event.input?.command ?? "").slice(0, 200) });
      }
    }
    if (!note) return undefined;
    return { content: [...(event.content ?? []), { type: "text", text: "\n" + note }] };
  });
}
