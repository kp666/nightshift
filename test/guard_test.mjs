// Tests adapters/pi/unattended-guard.ts without a model: loads the extension with a fake `pi` object and
// fires the tool_call / tool_result events pi would. Run: node --experimental-strip-types test/guard_test.mjs
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";

const here = fileURLToPath(new URL(".", import.meta.url));
const root = mkdtempSync(join(tmpdir(), "ns-guard-"));
for (const f of ["src/lib/horoscope-generator.ts", "src/lib/dasha.ts", "src/components/Chart.tsx",
                 "spec/test/acceptance/t01.test.ts", "package.json"]) {
  mkdirSync(join(root, f, ".."), { recursive: true });
  writeFileSync(join(root, f), "// x\n");
}
const log = join(root, "..", `guard-${Date.now()}.jsonl`);
Object.assign(process.env, { PI_GUARD: "1", PI_GUARD_ROOT: root, PI_GUARD_LOG: log,
  PI_GUARD_PROTECT: "spec/test/acceptance/,package.json", PI_GUARD_MAX_PATH_MISSES: "3" });
process.chdir(root);

const mod = await import(pathToFileURL(join(here, "..", "adapters", "pi", "unattended-guard.ts")).href);
const h = {};
mod.default({ on: (name, fn) => { h[name] = fn; } });
await h.agent_start({}, {});

let id = 0, failed = 0, passed = 0;
async function call(toolName, input, content = [{ type: "text", text: "ok" }]) {
  const ev = { toolName, toolCallId: `c${++id}`, input };
  await h.turn_start({}, { abort() {} });
  const res = await h.tool_call(ev, { cwd: root });
  const out = res?.block ? undefined : await h.tool_result({ ...ev, content }, { cwd: root });
  const text = (out?.content ?? content).map((c) => c.text).join("");
  return { input: ev.input, res, text };
}
function check(name, cond, info = "") {
  if (cond) { passed++; console.log("ok   " + name); }
  else { failed++; console.log("FAIL " + name + "  " + info); }
}

let r = await call("read", { path: "k Myapp-version-3/src/lib/horoscope-generator.ts" });
check("garbled project-folder prefix is repaired", r.input.path === "src/lib/horoscope-generator.ts", r.input.path);
check("model is told the right path", r.text.includes("Use exactly 'src/lib/horoscope-generator.ts'"), r.text);

r = await call("read", { path: "C:\\path\\to\\other-checkout\\src\\lib\\dasha.ts" });
check("absolute path into another checkout is redirected into the root", r.input.path === "src/lib/dasha.ts" && !r.res, r.input.path);

r = await call("read", { path: "lib/horoscope-generator.ts" });
check("missing leading folder fixed by unique basename", r.input.path === "src/lib/horoscope-generator.ts", r.input.path);

r = await call("read", { path: " src/lib/dasha.ts\n" });
check("stray whitespace/newline in path is fixed", r.input.path === "src/lib/dasha.ts", JSON.stringify(r.input.path));

r = await call("edit", { path: "astro/spec/test/acceptance/t01.test.ts", oldText: "a", newText: "b" });
check("repaired path still goes through protection", r.res?.block === true && /read-only/.test(r.res.reason), JSON.stringify(r.res));

r = await call("write", { path: "k Kerala-astro/src/lib/navamsa.ts", content: "x" });
check("write under a garbled prefix goes to the real folder", r.input.path === "src/lib/navamsa.ts", r.input.path);

r = await call("write", { path: "src/lib/vargas/d9.ts", content: "x" });
check("new sub-directory of a real folder is left alone", r.input.path === "src/lib/vargas/d9.ts", r.input.path);

r = await call("read", { path: "src/components/Chart.tsx" });
check("correct path is untouched and gets no note", r.input.path === "src/components/Chart.tsx" && r.text === "ok", r.text);

r = await call("bash", { command: "cat src/lib/nope.ts" }, [{ type: "text", text: "cat: src/lib/nope.ts: No such file or directory" }]);
check("bash path error gets a root hint", r.text.includes("repository root"), r.text);

r = await call("read", { path: "src/lib/horoscop-generator.ts" });
check("unfixable typo gets suggestions", r.text.includes("Did you mean: src/lib/horoscope-generator.ts"), r.text);

await call("read", { path: "zzz/one.ts" });
r = await call("read", { path: "zzz/two.ts" });
r = await call("read", { path: "src/lib/dasha.ts" });
check("too many path misses ends the session", r.res?.terminate === true, JSON.stringify(r.res));

const events = readFileSync(log, "utf8").trim().split("\n").map((l) => JSON.parse(l));
check("repairs and misses are logged", events.filter((e) => e.kind === "path_repaired").length >= 5 &&
      events.some((e) => e.kind === "path_miss") && events.some((e) => e.kind === "stop"));

process.chdir(tmpdir()); // Windows cannot remove the current directory
rmSync(root, { recursive: true, force: true });
rmSync(log, { force: true });
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
