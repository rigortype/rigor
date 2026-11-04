// `rigor check` as a VS Code task. The task runs the same `rigor` that the
// language server resolves (`resolveRigor`), from the same project root,
// and its text output is matched by the `$rigor` problem matcher that
// package.json contributes. The problems it reports carry `source: "rigor"`,
// the same source as the server's diagnostics.

import {
  Disposable,
  ExtensionContext,
  OutputChannel,
  ProcessExecution,
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
import { peekResolution, resolveRigor } from "./resolve";

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
 * One `rigor: check` task per folder the extension manages. Untrusted
 * workspaces get none: the task spawns `bundle exec rigor` from the
 * workspace, as the language server does.
 */
class RigorCheckTaskProvider implements TaskProvider {
  constructor(private readonly output: OutputChannel) {}

  /**
   * Never waits for a discovery walk, which can take seconds per
   * candidate: a folder whose resolution is not finished gets no task yet
   * (its walk is started), and VS Code asks again. A folder where no
   * `rigor` passed the probe gets none either: running the failed candidate
   * anyway could run an unpinned Rigor (`bundle exec rigor` falls back to
   * PATH), and **Rigor: Check Workspace** reports the failure instead.
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
      const resolution = peekResolution(folder, this.output);
      if (resolution && (resolution.probe.ok || resolution.probe.tooOld)) {
        out.push(
          checkTask(
            folder,
            folders.length > 1 ? `check (${folder.name})` : "check",
            resolution.server,
          ),
        );
      }
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
    if (failedNames.length > 0 && failedNames.length === managed.length) {
      void window.showErrorMessage(
        `Rigor: could not run Rigor in ${failedNames.join(", ")}, so rigor check does not run. ` +
          'The Rigor output lists what was tried; fix the setup, then run "Rigor: Restart Server".',
      );
      return;
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
