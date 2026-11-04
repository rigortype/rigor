// The `rigor: check` task wiring: the provider, `resolveTask`, and the
// pseudoterminal's rule for when a run replaces a folder's results. The
// `vscode` stub records the provider, the commands and the collection.

import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";

import { forgetResolutions } from "../src/resolve";
import { registerTasks } from "../src/tasks";
import { ExtensionMode, Task, addFolder, stub } from "./vscode-stub";
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
async function runTask(task: Task, cancelAfterMs?: number): Promise<Ran> {
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
  pty.onDidWrite((text) => (ran.out += text));
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

describe("resolveTask", () => {
  const resolve = (task: Task) => provider().resolveTask!(task as never, {} as never) as Task | undefined;
  const entry = (scope: unknown, extra: object = {}) =>
    new Task({ type: "rigor", command: "check", ...extra }, scope, "mine", "Workspace");

  it("resolves a tasks.json entry to a task that keeps the entry's own definition object", () => {
    const original = entry(folderB);
    const resolved = resolve(original)!;
    assert.ok(resolved);
    assert.equal(resolved.definition, original.definition);
    assert.equal(resolved.scope, folderB);
    assert.equal(resolved.name, "mine");
    assert.deepEqual(original.definition, { type: "rigor", command: "check" });
  });

  it("the resolved task runs the check in its own folder", async () => {
    checkDoes(`pwd; ${finding(sb.project)}; exit 1`);
    const ran = await runTask(resolve(entry(folderA))!);
    assert.equal(ran.code, 1);
    assert.match(ran.out, new RegExp(sb.project.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  });

  it("declines other commands, other scopes, unmanaged folders and untrusted workspaces", () => {
    assert.equal(resolve(entry(folderA, { command: "other" })), undefined);
    assert.equal(resolve(new Task({ type: "rigor", command: "check" }, 1, "x", "Workspace")), undefined);
    stub.set("rigor.enable", false);
    assert.equal(resolve(entry(folderA)), undefined);
    stub.set("rigor.enable", true);
    stub.trusted = false;
    assert.equal(resolve(entry(folderA)), undefined);
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

  it("a cancelled run closes with 130 once and keeps them, even when rigor then exits 1", async () => {
    checkDoes(`${finding(A())}; exit 1`);
    await runTask(taskFor(folderA));
    checkDoes(
      `trap '${finding(A(), "lib/late.rb")}; exit 1' TERM\nsleep 5 &\nwait\n`,
    );
    const ran = await runTask(taskFor(folderA), 700);
    assert.equal(ran.code, 130);
    assert.equal(ran.closes, 1);
    await new Promise((r) => setTimeout(r, 300));
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
