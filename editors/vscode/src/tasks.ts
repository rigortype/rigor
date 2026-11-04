// `rigor check` as a VS Code task. The task runs the same `rigor` that the
// language server resolves (`resolveRigor`), from the same project root, in a
// pseudoterminal that parses its text output (see `checkTask`). The problems
// it reports carry `source: "rigor check"`, apart from the server's
// `source: "rigor"`.

import {
  CustomExecution,
  Diagnostic,
  Disposable,
  EventEmitter,
  ExtensionContext,
  OutputChannel,
  Pseudoterminal,
  QuickPickItem,
  Task,
  TaskProvider,
  WorkspaceFolder,
  commands,
  tasks,
  window,
  workspace,
} from "vscode";
import { CheckFinding, LineSplitter, parseCheckLine } from "./checkOutput";
import {
  CheckResults,
  collectionSink,
  createCheckCollection,
  groupFindings,
} from "./checkResults";
import {
  configArgs,
  projectRoot,
  shouldManageFolder,
  useShell,
} from "./discovery";
import { killTree, spawnCli } from "./proc";
import { describeCandidate, peekResolution, resolveRigor } from "./resolve";

const TASK_TYPE = "rigor";
const TASK_SOURCE = "rigor";

/** Check results of every folder, in the one `rigor check` collection. */
let results: CheckResults<Diagnostic> | undefined;

function folderKey(folder: WorkspaceFolder): string {
  return folder.uri.toString();
}

/**
 * The `rigor: check` task for one managed folder, always a pseudoterminal.
 * It waits for the folder's discovery, runs the resolved `rigor check` in
 * the project root and echoes its output. It parses the output itself
 * rather than through a problem matcher, whose owner is static and would
 * make folders clear each other's problems (#2747); a folder's run replaces
 * only that folder's results. After a failed walk it prints why and exits 1,
 * so the task is never missing and never runs a Rigor discovery rejected (a
 * failed pinned bundle must not become an unpinned run). It closes with
 * `rigor check`'s exit code.
 */
function checkTask(
  folder: WorkspaceFolder,
  label: string,
  output: OutputChannel,
): Task {
  const root = projectRoot(folder) ?? folder.uri.fsPath;
  const execution = new CustomExecution(async (): Promise<Pseudoterminal> => {
    const write = new EventEmitter<string>();
    const close = new EventEmitter<number>();
    let child: ReturnType<typeof spawnCli> | undefined;
    let closed = false;
    const findings: CheckFinding[] = [];
    const splitters = [new LineSplitter(), new LineSplitter()];
    const take = (lines: string[]): void => {
      for (const line of lines) {
        const finding = parseCheckLine(line, root);
        if (finding) {
          findings.push(finding);
        }
      }
    };
    const finish = (code: number): void => {
      if (!closed) {
        closed = true;
        close.fire(code);
      }
    };
    const crlf = (text: string): string => text.replace(/\r?\n/g, "\r\n");
    return {
      onDidWrite: write.event,
      onDidClose: close.event,
      open: () => {
        // A new run replaces this folder's earlier results, even when it
        // never gets as far as running rigor.
        results?.clear(folderKey(folder));
        void resolveRigor(folder, output).then((res) => {
          if (closed) {
            return;
          }
          if (!res.probe.ok && !res.probe.tooOld) {
            const lines = [
              `Rigor: could not run Rigor in ${folder.name}.`,
              ...(res.hint ? [res.hint] : []),
              ...res.rejected.map((r) => `  rejected ${describeCandidate(r.server)}: ${r.reason}`),
              'Fix the setup, then run "Rigor: Restart Server".',
            ];
            write.fire(crlf(`${lines.join("\n")}\n`));
            finish(1);
            return;
          }
          const server = res.server;
          const args = [...server.prefixArgs, "check", ...configArgs(folder)];
          child = spawnCli(server.command, args, root, {
            shell: useShell(server),
            env: server.env,
          });
          const pipe = (stream: NodeJS.ReadableStream | null, splitter: LineSplitter): void => {
            stream?.on("data", (d: Buffer) => {
              const text = d.toString();
              write.fire(crlf(text));
              take(splitter.push(text));
            });
          };
          pipe(child.stdout, splitters[0]);
          pipe(child.stderr, splitters[1]);
          child.on("error", (err) => {
            write.fire(crlf(`${String(err)}\n`));
            finish(1);
          });
          child.on("close", (code) => {
            if (!closed) {
              splitters.forEach((s) => take(s.flush()));
              results?.replace(folderKey(folder), groupFindings(findings));
            }
            finish(code ?? 1);
          });
        });
      },
      close: () => {
        if (child) {
          killTree(child);
        }
        finish(130);
      },
    };
  });
  return new Task(
    { type: TASK_TYPE, command: "check" },
    folder,
    label,
    TASK_SOURCE,
    execution,
  );
}

/**
 * One `rigor: check` task per folder the extension manages. Untrusted
 * workspaces get none: the task spawns `bundle exec rigor` from the
 * workspace, as the language server does.
 */
class RigorCheckTaskProvider implements TaskProvider {
  constructor(private readonly output: OutputChannel) {}

  /**
   * Never waits for a discovery walk, which can take seconds per
   * candidate: the task waits for it when it runs.
   */
  provideTasks(): Task[] {
    if (!workspace.isTrusted) {
      return [];
    }
    const folders = (workspace.workspaceFolders ?? []).filter((folder) =>
      shouldManageFolder(folder),
    );
    const out: Task[] = [];
    for (const folder of folders) {
      const label = folders.length > 1 ? `check (${folder.name})` : "check";
      // Starts the folder's walk; the task itself waits for it.
      peekResolution(folder, this.output);
      out.push(checkTask(folder, label, this.output));
    }
    return out;
  }

  resolveTask(): undefined {
    // Only the tasks provided above run; a tasks.json entry is not resolved.
    return undefined;
  }
}

/** The folder a provided task is scoped to; `TaskScope` numbers are not one. */
function taskFolder(task: Task): WorkspaceFolder | undefined {
  const scope = task.scope;
  return typeof scope === "object" ? scope : undefined;
}

/**
 * Run the check for the folder of the active editor, or ask which folder
 * when the active file is in none of them.
 */
async function checkWorkspace(): Promise<void> {
  if (!workspace.isTrusted) {
    void window.showWarningMessage(
      "Rigor: this workspace is not trusted, so rigor check does not run here. Trust the workspace to check it.",
    );
    return;
  }
  // A command may wait: finish each managed folder's discovery first, so
  // the provider below has every folder's task.
  if (output) {
    const managed = (workspace.workspaceFolders ?? []).filter((folder) =>
      shouldManageFolder(folder),
    );
    const resolutions = await Promise.all(
      managed.map((folder) => resolveRigor(folder, output!)),
    );
    const failedNames = managed
      .filter((_, i) => !resolutions[i].probe.ok && !resolutions[i].probe.tooOld)
      .map((folder) => folder.name);
    if (failedNames.length > 0) {
      void window
        .showErrorMessage(
          `Rigor: could not run Rigor in ${failedNames.join(", ")}, so rigor check cannot check ` +
            `${failedNames.length === 1 ? "it" : "them"}. The Rigor output lists what was tried; ` +
            'fix the setup, then run "Rigor: Restart Server".',
          "Show Output",
        )
        .then((choice) => choice && output?.show());
      if (failedNames.length === managed.length) {
        return;
      }
    }
  }
  const all = (await tasks.fetchTasks({ type: TASK_TYPE })).filter(
    (task) => taskFolder(task) !== undefined,
  );
  if (all.length === 0) {
    void window.showInformationMessage(
      "Rigor: no folder in this workspace uses Rigor, so there is nothing to check.",
    );
    return;
  }

  const active = window.activeTextEditor?.document.uri;
  const activeFolder = active ? workspace.getWorkspaceFolder(active) : undefined;
  let chosen: Task | undefined;
  if (all.length === 1) {
    chosen = all[0];
  } else {
    const match = all.find(
      (task) =>
        activeFolder !== undefined &&
        taskFolder(task)?.uri.toString() === activeFolder.uri.toString(),
    );
    if (match) {
      chosen = match;
    } else {
      const items: (QuickPickItem & { task: Task })[] = all.map((task) => ({
        label: task.name,
        description: taskFolder(task)?.name,
        task,
      }));
      const picked = await window.showQuickPick(items, {
        placeHolder: "Run rigor check for which folder?",
      });
      chosen = picked?.task;
    }
  }
  if (chosen) {
    await tasks.executeTask(chosen);
  }
}

/**
 * Register the `rigor` task provider and the `Rigor: Check Workspace`
 * command. Called once from `activate`.
 */
let output: OutputChannel | undefined;

export function registerTasks(
  context: ExtensionContext,
  channel: OutputChannel,
): void {
  output = channel;
  const collection = createCheckCollection();
  results = new CheckResults(collectionSink(collection));
  const provider: Disposable = tasks.registerTaskProvider(
    TASK_TYPE,
    new RigorCheckTaskProvider(channel),
  );
  context.subscriptions.push(
    provider,
    collection,
    { dispose: () => (results = undefined) },
    commands.registerCommand("rigor.checkWorkspace", () => checkWorkspace()),
    commands.registerCommand("rigor.clearCheckResults", () => results?.clearAll()),
    workspace.onDidChangeWorkspaceFolders(() => pruneCheckResults()),
  );
}

/**
 * Drop the results of folders that left the workspace or are no longer
 * managed. Called when the workspace folders change and after each sync.
 */
export function pruneCheckResults(): void {
  if (!results) {
    return;
  }
  const managed = new Set(
    (workspace.workspaceFolders ?? [])
      .filter((folder) => shouldManageFolder(folder))
      .map(folderKey),
  );
  for (const key of results.folders()) {
    if (!managed.has(key)) {
      results.clear(key);
    }
  }
}
