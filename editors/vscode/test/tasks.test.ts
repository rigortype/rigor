// The `rigor: check` task wiring: the provider, `resolveTask`, and the
// pseudoterminal's rule for when a run replaces a folder's results. The
// `vscode` stub records the provider, the commands and the collection.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";

import { syncClientsNow } from "../src/extension";
import { forgetResolutions } from "../src/resolve";
import { registerTasks, shellCheckTask } from "../src/tasks";
import { CustomExecution, ExtensionMode, ProcessExecution, ShellExecution, Task, Uri, addFolder, stub } from "./vscode-stub";
import { Sandbox, fakeContext, fakeOutput, sandbox, script } from "./helpers";

type Provider = import("vscode").TaskProvider;
type Folder = import("vscode").WorkspaceFolder;

let sb: Sandbox;
let folderA: Folder;
let folderB: Folder;
let rigor: string;
/** What the fake `rigor check` prints and exits with. */
let fixtureDir: string;

beforeEach(() => {
  stub.reset();
  sb = sandbox();
  fixtureDir = path.join(sb.dir, "fixture");
  fs.mkdirSync(fixtureDir);
  const dirB = path.join(sb.home, "projB");
  fs.mkdirSync(dirB);
  folderA = addFolder(sb.project);
  folderB = addFolder(dirB);
  rigor = script(
    path.join(sb.bin, "rigor"),
    `case "$1" in
  version) echo "rigor 0.4.7" ;;
  check) sh "${fixtureDir}/check.sh" ;;
esac`,
  );
  stub.set("rigor.server.path", rigor);
  registerTasks(fakeContext(path.join(sb.dir, "storage"), ExtensionMode.Production), fakeOutput() as never);
});

afterEach(() => {
  forgetResolutions();
  sb.dispose();
});

const provider = (): Provider => stub.taskProviders.get("rigor")!;
const collection = () => stub.collections[stub.collections.length - 1];
const files = (): string[] => [...collection().entries.keys()].sort();

/** Make the fake `rigor check` run `body` (a shell script). */
function checkDoes(body: string): void {
  fs.writeFileSync(path.join(fixtureDir, "check.sh"), body);
}

/** The finding line the fake prints for `file` in `dir`. */
const finding = (dir: string, file = "lib/a.rb", msg = "boom"): string =>
  `echo "${path.join(dir, file)}:2:3: error: ${msg} [r-x]"`;

interface Ran {
  code: number | undefined;
  out: string;
  closes: number;
}

/** Run the provided task for `folder` as VS Code does, to its close. */
async function runTask(task: Task, cancelAfterMs?: number, cancelOnFirstOutput = false): Promise<Ran> {
  const execution = task.execution as { callback: (d: unknown) => Promise<import("vscode").Pseudoterminal> };
  const pty = await execution.callback(task.definition);
  const ran: Ran = { code: undefined, out: "", closes: 0 };
  const done = new Promise<void>((resolve) => {
    pty.onDidClose!((code) => {
      ran.code = code as number;
      ran.closes += 1;
      resolve();
    });
  });
  let cancelled = false;
  pty.onDidWrite((text) => {
    ran.out += text;
    if (cancelOnFirstOutput && !cancelled) {
      cancelled = true;
      // Block until rigor has exited, so the cancel races its natural end.
      const until = Date.now() + 300;
      while (Date.now() < until) {
        /* spin */
      }
      pty.close();
    }
  });
  pty.open(undefined);
  if (cancelAfterMs !== undefined) {
    await new Promise((r) => setTimeout(r, cancelAfterMs));
    pty.close();
  }
  await done;
  return ran;
}

const taskFor = (folder: Folder): Task =>
  (provider().provideTasks!({} as never) as Task[]).find((t) => t.scope === folder)!;

describe("the provided tasks", () => {
  it("one per managed folder, each with its own definition and no problem matcher", () => {
    const tasks = provider().provideTasks!({} as never) as Task[];
    assert.deepEqual(tasks.map((t) => t.name), [`check (${folderA.name})`, `check (${folderB.name})`]);
    assert.equal(new Set(tasks.map((t) => JSON.stringify(t.definition))).size, 2);
    for (const t of tasks) {
      assert.equal(t.definition.type, "rigor");
      assert.equal(t.definition.command, "check");
      assert.equal((t as unknown as { problemMatchers?: unknown }).problemMatchers, undefined);
    }
  });

  it("none in an untrusted workspace", () => {
    stub.trusted = false;
    assert.deepEqual(provider().provideTasks!({} as never), []);
  });
});

describe("the folder key of a provided task", () => {
  const keys = () =>
    (provider().provideTasks!({} as never) as Task[]).map((t) => t.definition.folder);

  it("is the folder's name when no other folder has it", () => {
    assert.deepEqual(keys(), [folderA.name, folderB.name]);
  });

  it("is the path relative to the workspace file when names collide", () => {
    stub.folders = [];
    const x = addFolder(path.join(sb.dir, "x", "app"));
    const y = addFolder(path.join(sb.dir, "y", "app"));
    fs.mkdirSync(x.uri.fsPath, { recursive: true });
    fs.mkdirSync(y.uri.fsPath, { recursive: true });
    stub.workspaceFile = Uri.file(path.join(sb.dir, "ws", "my.code-workspace"));
    assert.deepEqual(keys(), ["../x/app", "../y/app"]);
    stub.workspaceFile = undefined;
    assert.deepEqual(keys(), [x.uri.fsPath, y.uri.fsPath]);
  });
});

describe("resolveTask", () => {
  const resolve = async (task: Task) =>
    (await provider().resolveTask!(task as never, {} as never)) as Task | undefined;
  const entry = (scope: unknown, extra: object = {}) =>
    new Task({ type: "rigor", command: "check", ...extra }, scope, "mine", "Workspace");

  it("a folder-less entry runs as before #2747: a process in its own folder with $rigor", async () => {
    const original = entry(folderB);
    const resolved = (await resolve(original))!;
    assert.equal(resolved.definition, original.definition);
    assert.equal(resolved.scope, folderB);
    assert.equal(resolved.name, "mine");
    assert.equal(resolved.problemMatchers, "$rigor");
    const exec = resolved.execution as ProcessExecution;
    assert.ok(exec instanceof ProcessExecution);
    assert.equal(exec.process, rigor);
    assert.deepEqual(exec.args, ["check"]);
    assert.equal(exec.options.cwd, folderB.uri.fsPath);
    assert.deepEqual(original.definition, { type: "rigor", command: "check" });
  });

  it("two folder-less entries with one definition each run in their own folder", async () => {
    const a = (await resolve(entry(folderA)))!;
    const b = (await resolve(entry(folderB)))!;
    assert.equal((a.execution as ProcessExecution).options.cwd, folderA.uri.fsPath);
    assert.equal((b.execution as ProcessExecution).options.cwd, folderB.uri.fsPath);
  });

  it("a server that needs a shell (a Windows .cmd shim) gets a shell execution", () => {
    const server = { command: "rigor.cmd", prefixArgs: ["x"], shell: true } as never;
    const task = shellCheckTask(folderA, "mine", server, { type: "rigor", command: "check" });
    const exec = task.execution as ShellExecution;
    assert.ok(exec instanceof ShellExecution);
    assert.deepEqual(exec.args, ["x", "check"]);
    assert.equal(exec.options.cwd, folderA.uri.fsPath);
    assert.equal(task.problemMatchers, "$rigor");
  });

  it("an entry with a folder is the per-folder pseudoterminal, no matcher, own definition kept", async () => {
    const original = entry(folderB, { folder: folderB.name });
    const resolved = (await resolve(original))!;
    assert.equal(resolved.definition, original.definition);
    assert.ok(resolved.execution instanceof CustomExecution);
    assert.equal(resolved.problemMatchers, undefined);
  });

  it("the folder entry's pseudoterminal runs the check in its own folder", async () => {
    checkDoes(`pwd; ${finding(sb.project)}; exit 1`);
    const ran = await runTask((await resolve(entry(folderA, { folder: folderA.name })))!);
    assert.equal(ran.code, 1);
    assert.match(ran.out, new RegExp(sb.project.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  });

  it("a folder-less entry whose rigor does not run is a process that says why and exits 1, not a pseudoterminal", async () => {
    stub.set("rigor.server.path", path.join(sb.dir, "missing", "rigor"));
    forgetResolutions();
    const resolved = (await resolve(entry(folderA)))!;
    assert.ok(!(resolved.execution instanceof CustomExecution));
    const exec = resolved.execution as ProcessExecution;
    assert.ok(exec instanceof ProcessExecution);
    const ran = spawnSync(exec.process, exec.args, { env: { ...process.env, ...exec.options.env }, cwd: exec.options.cwd, encoding: "utf8" });
    assert.equal(ran.status, 1);
    assert.match(ran.stderr, /could not run Rigor in/);
    assert.match(ran.stderr, /Restart Server/);
    assert.equal(resolved.problemMatchers, undefined);
  });

  it("an entry whose folder names another folder is treated as folder-less, and says so once", async () => {
    const out = fakeOutput();
    registerTasks(fakeContext(path.join(sb.dir, "storage"), ExtensionMode.Production), out as never);
    const p = stub.taskProviders.get("rigor")!;
    const stale = () => entry(folderA, { folder: folderB.name });
    const first = (await p.resolveTask!(stale() as never, {} as never)) as Task;
    assert.ok(first.execution instanceof ProcessExecution);
    assert.equal(first.problemMatchers, "$rigor");
    assert.equal(first.definition.folder, folderB.name);
    await p.resolveTask!(stale() as never, {} as never);
    assert.equal(out.lines.filter((l) => /not this folder's key/.test(l)).length, 1);
  });

  it("declines other commands, other scopes, unmanaged folders and untrusted workspaces", async () => {
    assert.equal(await resolve(entry(folderA, { command: "other" })), undefined);
    assert.equal(await resolve(new Task({ type: "rigor", command: "check" }, 1, "x", "Workspace")), undefined);
    stub.set("rigor.enable", false);
    assert.equal(await resolve(entry(folderA)), undefined);
    stub.set("rigor.enable", true);
    stub.trusted = false;
    assert.equal(await resolve(entry(folderA)), undefined);
  });
});

describe("when a run replaces a folder's results", () => {
  const A = () => sb.project;

  it("a finished run with findings (exit 1) publishes them, and one with none (exit 0) clears them", async () => {
    checkDoes(`${finding(A())}; exit 1`);
    await runTask(taskFor(folderA));
    assert.deepEqual(files(), [path.join(A(), "lib/a.rb")]);
    checkDoes("exit 0");
    await runTask(taskFor(folderA));
    assert.deepEqual(files(), []);
  });

  for (const code of [64, 70, 127, 137, 2]) {
    it(`exit ${code} keeps the earlier results`, async () => {
      checkDoes(`${finding(A())}; exit 1`);
      await runTask(taskFor(folderA));
      checkDoes(`${finding(A(), "lib/other.rb")}; exit ${code}`);
      const ran = await runTask(taskFor(folderA));
      assert.equal(ran.code, code);
      assert.deepEqual(files(), [path.join(A(), "lib/a.rb")]);
    });
  }

  it("a failed discovery keeps them and exits 1", async () => {
    checkDoes(`${finding(A())}; exit 1`);
    await runTask(taskFor(folderA));
    stub.set("rigor.server.path", path.join(sb.dir, "missing", "rigor"));
    forgetResolutions();
    const ran = await runTask(taskFor(folderA));
    assert.equal(ran.code, 1);
    assert.match(ran.out, /could not run Rigor/);
    assert.deepEqual(files(), [path.join(A(), "lib/a.rb")]);
  });

  it("a cancelled run closes with 130 once and keeps them", async () => {
    checkDoes(`${finding(A())}; exit 1`);
    await runTask(taskFor(folderA));
    checkDoes("sleep 5");
    const ran = await runTask(taskFor(folderA), 500);
    assert.equal(ran.code, 130);
    assert.equal(ran.closes, 1);
    assert.deepEqual(files(), [path.join(A(), "lib/a.rb")]);
  });

  it("a run cancelled as rigor finishes on its own (exit 1) still keeps them", async () => {
    checkDoes(`${finding(A())}; exit 1`);
    await runTask(taskFor(folderA));
    checkDoes(`${finding(A(), "lib/late.rb")}; exit 1`);
    const ran = await runTask(taskFor(folderA), undefined, true);
    assert.equal(ran.code, 130);
    assert.equal(ran.closes, 1);
    await new Promise((r) => setTimeout(r, 200));
    assert.deepEqual(files(), [path.join(A(), "lib/a.rb")]);
  });

  it("only stdout is read for findings; stderr is echoed", async () => {
    checkDoes(`${finding(A(), "lib/a.rb")} >&2; exit 1`);
    const ran = await runTask(taskFor(folderA));
    assert.match(ran.out, /boom/);
    assert.deepEqual(files(), []);
  });

  it("a multi-byte character split across output chunks arrives whole", async () => {
    checkDoes(`printf '${A()}/lib/a.rb:1:1: error: \\343\\201'; sleep 0.4; printf '\\202x\\n'; exit 1`);
    await runTask(taskFor(folderA));
    const d = collection().entries.get(path.join(A(), "lib/a.rb"))!;
    assert.equal(d[0].message, "あx");
  });

  it("a run for folder B keeps folder A's results", async () => {
    checkDoes(`${finding(A())}; exit 1`);
    await runTask(taskFor(folderA));
    checkDoes(`${finding(folderB.uri.fsPath)}; exit 1`);
    await runTask(taskFor(folderB));
    assert.equal(files().length, 2);
  });
});

describe("pruning and the clear command", () => {
  it("results of a folder that left the workspace are dropped, the others stay", async () => {
    checkDoes(`${finding(sb.project)}; exit 1`);
    await runTask(taskFor(folderA));
    checkDoes(`${finding(folderB.uri.fsPath)}; exit 1`);
    await runTask(taskFor(folderB));
    stub.folders = stub.folders.filter((f) => f !== folderA);
    stub.folderListeners.forEach((l) => l());
    assert.deepEqual(files(), [path.join(folderB.uri.fsPath, "lib/a.rb")]);
  });

  it("results of a folder that is no longer managed are dropped", async () => {
    checkDoes(`${finding(sb.project)}; exit 1`);
    await runTask(taskFor(folderA));
    stub.set("rigor.enable", false);
    stub.folderListeners.forEach((l) => l());
    assert.deepEqual(files(), []);
  });

  it("Rigor: Clear Check Results clears every folder", async () => {
    checkDoes(`${finding(sb.project)}; exit 1`);
    await runTask(taskFor(folderA));
    checkDoes(`${finding(folderB.uri.fsPath)}; exit 1`);
    await runTask(taskFor(folderB));
    stub.commandHandlers.get("rigor.clearCheckResults")!();
    assert.deepEqual(files(), []);
  });
});

describe("syncing the clients", () => {
  it("prunes the check results of a folder that is gone", async () => {
    checkDoes(`${finding(sb.project)}; exit 1`);
    await runTask(taskFor(folderA));
    assert.equal(files().length, 1);
    stub.folders = stub.folders.filter((f) => f !== folderA);
    stub.trusted = false;
    try {
      await syncClientsNow();
    } catch {
      // The untrusted branch then touches the status bar, which only
      // `activate` creates. The prune runs first.
    }
    assert.deepEqual(files(), []);
  });
});
