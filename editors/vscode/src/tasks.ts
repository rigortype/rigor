// `rigor check` as a VS Code task. The task runs the same `rigor` that the
// language server resolves (`resolveServer`), from the same project root,
// and its text output is matched by the `$rigor` problem matcher that
// package.json contributes. The problems it reports carry `source: "rigor"`,
// the same source as the server's diagnostics.

import {
  Disposable,
  ExtensionContext,
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
  configArgs,
  projectRoot,
  resolveServer,
  shouldManageFolder,
} from "./discovery";

const TASK_TYPE = "rigor";
const TASK_SOURCE = "rigor";
const PROBLEM_MATCHER = "$rigor";

/** Quote one argument for a Windows command line run through `cmd`. */
function quoteWin(arg: string): string {
  return /[\s"]/.test(arg) ? `"${arg.replace(/"/g, '\\"')}"` : arg;
}

/** The `rigor check` task for one managed folder. */
function checkTask(folder: WorkspaceFolder, label: string): Task {
  const server = resolveServer(folder);
  const root = projectRoot(folder) ?? folder.uri.fsPath;
  const args = [...server.prefixArgs, "check", ...configArgs(folder)];
  const definition: TaskDefinition = { type: TASK_TYPE, command: "check" };
  // `bundle` and the mise shim are not plain executables on Windows, so the
  // task runs through the shell there, as the language server does.
  const execution =
    process.platform === "win32"
      ? new ShellExecution([server.command, ...args].map(quoteWin).join(" "), {
          cwd: root,
        })
      : new ProcessExecution(server.command, args, { cwd: root });
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
  provideTasks(): Task[] {
    if (!workspace.isTrusted) {
      return [];
    }
    const folders = (workspace.workspaceFolders ?? []).filter((folder) =>
      shouldManageFolder(folder),
    );
    return folders.map((folder) =>
      checkTask(
        folder,
        folders.length > 1 ? `check (${folder.name})` : "check",
      ),
    );
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
export function registerTasks(context: ExtensionContext): void {
  const provider: Disposable = tasks.registerTaskProvider(
    TASK_TYPE,
    new RigorCheckTaskProvider(),
  );
  context.subscriptions.push(
    provider,
    commands.registerCommand("rigor.checkWorkspace", () => checkWorkspace()),
  );
}
