// `rigor check` as a VS Code task. The task runs the same `rigor` that the
// language server resolves (`resolveRigor`), from the same project root,
// and its text output is matched by the `$rigor` problem matcher that
// package.json contributes. The problems it reports carry `source: "rigor"`,
// the same source as the server's diagnostics.

import {
  CustomExecution,
  Disposable,
  EventEmitter,
  ExtensionContext,
  OutputChannel,
  ProcessExecution,
  Pseudoterminal,
  QuickPickItem,
  ShellExecution,
  Task,
  TaskDefinition,
  TaskProvider,
  WorkspaceFolder,
  commands,
  tasks,
  window,
  workspace,
} from "vscode";
import {
  ResolvedServer,
  configArgs,
  projectRoot,
  shouldManageFolder,
  useShell,
} from "./discovery";
import { killTree, spawnCli } from "./proc";
import { describeCandidate, peekResolution, resolveRigor } from "./resolve";

const TASK_TYPE = "rigor";
const TASK_SOURCE = "rigor";
const PROBLEM_MATCHER = "$rigor";

function definedEnv(env: NodeJS.ProcessEnv): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(env)) {
    if (value !== undefined) {
      out[key] = value;
    }
  }
  return out;
}

/** The `rigor check` task for one managed folder. */
function checkTask(
  folder: WorkspaceFolder,
  label: string,
  server: ResolvedServer,
): Task {
  const root = projectRoot(folder) ?? folder.uri.fsPath;
  const args = [...server.prefixArgs, "check", ...configArgs(folder)];
  const definition: TaskDefinition = { type: TASK_TYPE, command: "check" };
  // On Windows `bundle` and the version-manager shim are .cmd or .bat files,
  // which only a shell can start. ShellExecution takes the command and its
  // arguments separately, so VS Code quotes them for the user's shell.
  // The managed kind (ADR-27 WD10) runs under its own Bundler environment.
  // VS Code adds a task's `env` to the window's environment rather than
  // replacing it, so variables the managed spawn strips can still reach it.
  const env = server.env ? definedEnv(server.env) : undefined;
  const execution = useShell(server)
    ? new ShellExecution(server.command, args, { cwd: root, env })
    : new ProcessExecution(server.command, args, { cwd: root, env });
  const task = new Task(
    definition,
    folder,
    label,
    TASK_SOURCE,
    execution,
    PROBLEM_MATCHER,
  );
  return task;
}

/**
 * The `rigor check` task for a folder whose discovery has not finished, or
 * found no `rigor` that runs. It waits for the walk, then runs the resolved
 * `rigor check` in a pseudoterminal; after a failed walk it prints why and
 * exits 1, so the task is never missing and never runs a Rigor discovery
 * rejected (a failed pinned bundle must not become an unpinned run).
 */
function pendingCheckTask(
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
          child.stdout?.on("data", (d: Buffer) => write.fire(crlf(d.toString())));
          child.stderr?.on("data", (d: Buffer) => write.fire(crlf(d.toString())));
          child.on("error", (err) => {
            write.fire(crlf(`${String(err)}\n`));
            finish(1);
          });
          child.on("close", (code) => finish(code ?? 1));
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
    PROBLEM_MATCHER,
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
   * candidate: a folder whose resolution has not finished, or failed, gets
   * a `pendingCheckTask` instead (its walk is started).
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
      const resolution = peekResolution(folder, this.output);
      out.push(
        resolution && (resolution.probe.ok || resolution.probe.tooOld)
          ? checkTask(folder, label, resolution.server)
          : pendingCheckTask(folder, label, this.output),
      );
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
  const provider: Disposable = tasks.registerTaskProvider(
    TASK_TYPE,
    new RigorCheckTaskProvider(channel),
  );
  context.subscriptions.push(
    provider,
    commands.registerCommand("rigor.checkWorkspace", () => checkWorkspace()),
  );
}
