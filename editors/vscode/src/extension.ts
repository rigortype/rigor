// Rigor VS Code extension — a thin LSP client over `rigor lsp`.
//
// The extension implements no language features itself: diagnostics,
// hover, completion, and the outline view all come from the language
// server via `vscode-languageclient`. The extension owns discovery,
// configuration, lifecycle commands, the status bar, and — because the
// v1 LSP is single-root — one client per Rigor-configured folder.

import { ChildProcess, execFileSync, spawn } from "child_process";
import * as fs from "fs";
import * as path from "path";
import {
  ConfigurationChangeEvent,
  ConfigurationTarget,
  Disposable,
  ExtensionContext,
  OutputChannel,
  RelativePattern,
  Uri,
  WorkspaceFolder,
  commands,
  window,
  workspace,
} from "vscode";
import {
  CloseAction,
  ErrorAction,
  ErrorHandler,
  LanguageClient,
  LanguageClientOptions,
  RevealOutputChannelOn,
  ServerOptions,
  State,
  StreamMessageReader,
  StreamMessageWriter,
} from "vscode-languageclient/node";
import {
  ResolvedServer,
  lspArgs,
  projectRoot,
  resolveServer,
  shouldManageFolder,
} from "./discovery";
import { MIN_VERSION, ProbeResult, probeServer } from "./probe";
import { FolderStatus, StatusBar, describeFolder } from "./status";

const DOCS_URL = "https://github.com/rigortype/rigor";

/** Settings that change the server invocation and require a restart. */
const SERVER_AFFECTING_SETTINGS = [
  "rigor.enable",
  "rigor.rootDir",
  "rigor.server.path",
  "rigor.server.useBundler",
  "rigor.server.configPath",
  "rigor.server.logPath",
];

/** How long `stop()` may take before the process is killed. */
const STOP_TIMEOUT_MS = 2000;
/**
 * How long to wait for the process to exit after `stop()` returned before
 * killing its process tree. The client does not kill a process it did not
 * spawn itself, and this extension spawns it (to hold the handle).
 */
const EXIT_GRACE_MS = 3000;
/**
 * How long `client.start()` (spawn + `initialize`) may take. Without a
 * limit a server that never answers would hold the lifecycle chain, and
 * every later restart, folder change and shutdown would wait behind it.
 */
const START_TIMEOUT_MS = 60000;
/** `stop()` budget per server while the window closes. */
const SHUTDOWN_STOP_MS = 1000;
/** Config files created or deleted together (a checkout) re-sync once. */
const SYNC_DEBOUNCE_MS = 500;

/** Directory names a nested Rigor config is never offered from. */
const SKIPPED_DIRS = new Set(["node_modules", "vendor", ".git"]);
const NESTED_DISMISSED_KEY = "rigor.nestedConfigDismissed";

interface ManagedClient {
  client: LanguageClient;
  disposables: Disposable[];
  /** The spawned `rigor lsp` process, once the client has started it. */
  process(): ChildProcess | undefined;
  /**
   * Mark the client as torn down by the extension: from now on a closed
   * connection is not restarted, no error is shown, and no new server is
   * spawned for it.
   */
  abandon(): void;
}

/** `client.start()` did not finish in time; the extension gave up on it. */
class StartTimeoutError extends Error {}

let outputChannel: OutputChannel;
let statusBar: StatusBar;
let extensionVersion = "unknown";
let extensionContext: ExtensionContext;
const clients = new Map<string, ManagedClient>();

/**
 * Why each unmanaged folder was last explained, so the same message is
 * not repeated on every sync but a changed setting is explained again.
 */
const explained = new Map<string, string>();
/** Folders whose probe failure was already reported since the last restart. */
const probeFailureReported = new Set<string>();

// Every start, stop, restart and sync runs through this chain, one at a
// time. Without it, a sync that is still probing `rigor version` (up to
// 20 s) and a second sync triggered meanwhile — a folder change, a trust
// grant, a restart — both see the folder as unmanaged and both start a
// server.
let lifecycle: Promise<void> = Promise.resolve();
/** Set by `deactivate`: no sync, start or spawn runs after it. */
let shuttingDown = false;
let syncTimer: NodeJS.Timeout | undefined;

function enqueue(task: () => Promise<void>): Promise<void> {
  const run = lifecycle.then(() => (shuttingDown ? undefined : task()));
  lifecycle = run.catch((err) => {
    outputChannel.appendLine(`[rigor] lifecycle error: ${String(err)}`);
  });
  return lifecycle;
}

export function activate(context: ExtensionContext): void {
  extensionContext = context;
  extensionVersion =
    (context.extension.packageJSON as { version?: string }).version ??
    "unknown";
  outputChannel = window.createOutputChannel("Rigor");
  statusBar = new StatusBar();
  context.subscriptions.push(outputChannel, statusBar);

  context.subscriptions.push(
    commands.registerCommand("rigor.restartServer", () => restartAll()),
    commands.registerCommand("rigor.showOutputChannel", () =>
      outputChannel.show(),
    ),
    commands.registerCommand("rigor.showServerLog", () => showServerLog()),
    commands.registerCommand("rigor.showServerVersion", () =>
      showServerVersion(),
    ),
  );

  // A config file created or deleted anywhere can change which folders
  // are managed (or which nested configs to offer), so re-sync.
  const configWatcher = workspace.createFileSystemWatcher(
    "**/.rigor{,.dist}.yml",
    false,
    true,
    false,
  );
  const scheduleSync = (): void => {
    if (shuttingDown) {
      return;
    }
    if (syncTimer) {
      clearTimeout(syncTimer);
    }
    syncTimer = setTimeout(() => {
      syncTimer = undefined;
      void syncClients();
    }, SYNC_DEBOUNCE_MS);
  };
  context.subscriptions.push(
    configWatcher,
    configWatcher.onDidCreate(scheduleSync),
    configWatcher.onDidDelete(scheduleSync),
    { dispose: () => syncTimer && clearTimeout(syncTimer) },
    workspace.onDidChangeWorkspaceFolders(() => void syncClients()),
    workspace.onDidChangeConfiguration((e) => onConfigChange(e)),
    workspace.onDidGrantWorkspaceTrust(() => void syncClients()),
  );

  void syncClients();
}

export async function deactivate(): Promise<void> {
  // Not queued: closing the window must not wait behind a startup probe.
  // No exit grace either: the extension host is torn down within seconds,
  // so a server still alive after `stop()` is killed at once.
  shuttingDown = true;
  if (syncTimer) {
    clearTimeout(syncTimer);
  }
  await Promise.all(
    [...clients.keys()].map((key) => stopClient(key, SHUTDOWN_STOP_MS, 0)),
  );
}

/** Bring the running clients in line with the current workspace state. */
function syncClients(): Promise<void> {
  return enqueue(syncClientsNow);
}

function restartAll(): Promise<void> {
  return enqueue(async () => {
    probeFailureReported.clear();
    await stopAllNow();
    await syncClientsNow();
  });
}

async function syncClientsNow(): Promise<void> {
  if (!workspace.isTrusted) {
    // Spawning `bundle exec rigor` is withheld in untrusted workspaces.
    await stopAllNow();
    return;
  }

  const folders = workspace.workspaceFolders ?? [];
  const wanted = new Set<string>();

  for (const folder of folders) {
    // A sync that was already running when the window closed must not
    // probe the remaining folders.
    if (shuttingDown) {
      return;
    }
    if (shouldManageFolder(folder)) {
      wanted.add(folder.uri.toString());
      await startClient(folder);
    } else {
      void explainUnmanaged(folder);
    }
  }

  for (const key of [...clients.keys()]) {
    if (!wanted.has(key)) {
      await stopClient(key);
    }
  }
  // A folder whose probe failed has a status entry but no client.
  for (const key of statusBar.keys()) {
    if (!wanted.has(key)) {
      statusBar.remove(key);
    }
  }
}

async function startClient(folder: WorkspaceFolder): Promise<void> {
  const key = folder.uri.toString();
  if (clients.has(key)) {
    return;
  }
  // `shouldManageFolder` only returns true for a root inside the folder.
  const root = projectRoot(folder) ?? folder.uri.fsPath;
  const label = folderLabel(folder, root);

  const server = resolveServer(folder);
  const args = lspArgs(server, folder);
  const commandLine = [server.command, ...args].join(" ");
  statusBar.update(key, { label, state: "starting", kind: server.kind });

  const probe = await probeServer(server, root);
  if (!probe.ok) {
    statusBar.update(key, {
      label,
      state: "error",
      kind: server.kind,
      version: probe.version,
    });
    logStartup(label, root, server, commandLine, probe.version, "failed");
    // A config-file watcher or folder change re-syncs often; say it once
    // until the user restarts or the probe passes.
    if (!probeFailureReported.has(key)) {
      probeFailureReported.add(key);
      reportProbeFailure(server, probe, label);
    }
    return;
  }
  probeFailureReported.delete(key);
  if (shuttingDown) {
    return;
  }

  let child: ChildProcess | undefined;
  let abandoned = false;
  // Cuts the client off from the server's streams without telling it the
  // connection closed. See the start timeout below.
  let detach = (): void => undefined;
  const serverOptions: ServerOptions = async () => {
    if (abandoned || shuttingDown) {
      throw new Error("the Rigor client was stopped");
    }
    const spawned = spawn(server.command, args, {
      cwd: root,
      shell: process.platform === "win32",
      // Its own process group on POSIX, so `killTree` reaches the forked
      // workers too.
      detached: process.platform !== "win32",
      windowsHide: true,
    });
    spawned.on("error", (err) => {
      outputChannel.appendLine(
        `[rigor] ${label}: could not spawn the server: ${String(err)}`,
      );
    });
    child = spawned;
    // Own transports instead of returning the process, so the streams can
    // be detached when the start times out.
    const reader = new StreamMessageReader(spawned.stdout!);
    const writer = new StreamMessageWriter(spawned.stdin!);
    spawned.stderr!.on("data", (data: Buffer | string) =>
      outputChannel.append(data.toString()),
    );
    detach = () => {
      reader.dispose();
      writer.dispose();
      spawned.stdout!.destroy();
    };
    return { reader, writer };
  };

  const watchers = [
    workspace.createFileSystemWatcher(new RelativePattern(root, ".rigor.yml")),
    workspace.createFileSystemWatcher(
      new RelativePattern(root, ".rigor.dist.yml"),
    ),
    workspace.createFileSystemWatcher(new RelativePattern(root, "Gemfile.lock")),
  ];

  const clientOptions: LanguageClientOptions = {
    // Scoped to the project root: without a pattern every folder's server
    // would be sent every Ruby file in the window.
    documentSelector: [
      { scheme: "file", language: "ruby", pattern: rootGlob(root) },
    ],
    workspaceFolder: folder,
    outputChannel,
    revealOutputChannelOn: RevealOutputChannelOn.Never,
    synchronize: { fileEvents: watchers },
    // The client's own handler restarts a closed connection and shows an
    // error. Once the extension has stopped or abandoned the client (a
    // start timeout, a restart, shutdown), both are wrong: the close is
    // the extension's own kill.
    errorHandler: {
      error: (error, message, count) =>
        abandoned
          ? { action: ErrorAction.Shutdown, handled: true }
          : defaultErrorHandler().error(error, message, count),
      closed: () =>
        abandoned
          ? { action: CloseAction.DoNotRestart, handled: true }
          : defaultErrorHandler().closed(),
    },
  };

  const client = new LanguageClient("rigor", "Rigor", serverOptions, clientOptions);
  let fallback: ErrorHandler | undefined;
  const defaultErrorHandler = (): ErrorHandler =>
    (fallback ??= client.createDefaultErrorHandler());
  // Which status entry the client's own transitions update. Set once the
  // first start succeeded; until then the start below reports its outcome.
  let running: FolderStatus | undefined;
  const stateListener = client.onDidChangeState((e) => {
    if (abandoned || !running) {
      return;
    }
    // A crash the client restarts goes Running -> Stopped -> Starting in
    // one tick, so only a restart that gives up (or fails) leaves it shown.
    if (e.newState === State.Stopped) {
      statusBar.update(key, { ...running, state: "error" });
      outputChannel.appendLine(
        `[rigor] ${label}: the server stopped unexpectedly`,
      );
    } else if (e.newState === State.Starting) {
      statusBar.update(key, { ...running, state: "starting" });
    } else {
      statusBar.update(key, running);
      outputChannel.appendLine(`[rigor] ${label}: the server is running again`);
    }
  });
  const disposables = [...watchers, stateListener];
  clients.set(key, {
    client,
    disposables,
    process: () => child,
    abandon: () => {
      abandoned = true;
    },
  });

  try {
    await withTimeout(
      client.start(),
      START_TIMEOUT_MS,
      `the server did not answer \`initialize\` within ${START_TIMEOUT_MS / 1000} s`,
    );
    running = {
      label,
      state: "running",
      kind: server.kind,
      version: probe.version,
      commandLine,
    };
    statusBar.update(key, running);
    logStartup(label, root, server, commandLine, probe.version, "running");
  } catch (err) {
    statusBar.update(key, {
      label,
      state: "error",
      kind: server.kind,
      version: probe.version,
      commandLine,
    });
    outputChannel.appendLine(
      `[rigor] failed to start the server for ${label}: ${String(err)}`,
    );
    clients.delete(key);
    for (const disposable of disposables) {
      disposable.dispose();
    }
    if (err instanceof StartTimeoutError) {
      // Killing the server closes the connection, which the client would
      // report as two more errors (the rejected `initialize`, then
      // "couldn't create connection"). Detached first, the pending
      // `initialize` is simply never answered and the client says nothing;
      // this is the one message.
      detach();
      void window
        .showErrorMessage(`Rigor: ${label}: ${err.message}.`, "Show Output")
        .then((choice) => choice && outputChannel.show());
    }
    // A start that failed part way (or timed out) leaves the spawned
    // process running. Kill it before disposing, so a late `initialize`
    // answer cannot register providers on an abandoned client.
    abandoned = true;
    await reap(child, 0);
    await client.dispose(STOP_TIMEOUT_MS).catch(() => undefined);
  }
}

async function stopClient(
  key: string,
  stopTimeoutMs = STOP_TIMEOUT_MS,
  exitGraceMs = EXIT_GRACE_MS,
): Promise<void> {
  statusBar.remove(key);
  const managed = clients.get(key);
  if (!managed) {
    return;
  }
  clients.delete(key);
  managed.abandon();
  for (const disposable of managed.disposables) {
    disposable.dispose();
  }
  try {
    await managed.client.stop(stopTimeoutMs);
  } catch {
    // The server may already be gone, or ignored `shutdown`; reaped below.
  }
  await reap(managed.process(), exitGraceMs);
}

async function stopAllNow(): Promise<void> {
  for (const key of [...clients.keys()]) {
    await stopClient(key);
  }
  statusBar.clear();
}

/** Wait for the process to exit, and kill its process tree if it does not. */
async function reap(
  child: ChildProcess | undefined,
  graceMs = EXIT_GRACE_MS,
): Promise<void> {
  if (
    !child ||
    child.pid === undefined ||
    child.exitCode !== null ||
    child.signalCode !== null
  ) {
    return;
  }
  const exited = await new Promise<boolean>((resolve) => {
    const timer = setTimeout(() => resolve(false), graceMs);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve(true);
    });
  });
  if (!exited) {
    outputChannel.appendLine(
      `[rigor] server process ${child.pid ?? "?"} did not exit; killing it`,
    );
    killTree(child);
  }
}

/**
 * Kill the server and everything it started: the fork-based worker pool
 * on POSIX (one process group, see the `detached` spawn), and on Windows
 * the `ruby.exe` behind the `cmd.exe` that `shell: true` interposes.
 */
function killTree(child: ChildProcess): void {
  const pid = child.pid;
  if (pid === undefined) {
    return;
  }
  try {
    if (process.platform === "win32") {
      execFileSync("taskkill", ["/T", "/F", "/PID", String(pid)], {
        stdio: "ignore",
        windowsHide: true,
      });
    } else {
      process.kill(-pid, "SIGKILL");
    }
  } catch {
    child.kill("SIGKILL");
  }
}

function withTimeout<T>(promise: Promise<T>, ms: number, message: string): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new StartTimeoutError(message)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function onConfigChange(e: ConfigurationChangeEvent): void {
  if (
    e.affectsConfiguration("rigor.rootDir") ||
    e.affectsConfiguration("rigor.enable")
  ) {
    // Explain a folder again after its setting changed, even back to a
    // value that was explained before. Only that folder: another folder's
    // dismissed offer stays dismissed.
    for (const folder of workspace.workspaceFolders ?? []) {
      if (
        e.affectsConfiguration("rigor.rootDir", folder.uri) ||
        e.affectsConfiguration("rigor.enable", folder.uri)
      ) {
        explained.delete(folder.uri.toString());
      }
    }
  }
  if (SERVER_AFFECTING_SETTINGS.some((s) => e.affectsConfiguration(s))) {
    void restartAll();
  }
}

/**
 * Say why an enabled folder got no server when the reason is a setting
 * or a config in the wrong place, rather than the folder not using Rigor.
 *
 * A folder with no Rigor config at its root may hold one deeper down (a
 * monorepo's `api/.rigor.yml`). The activation event fires for it, so
 * offer to set `rigor.rootDir`. Never pick a directory automatically: the
 * server is single-root and there may be two.
 */
async function explainUnmanaged(folder: WorkspaceFolder): Promise<void> {
  const key = folder.uri.toString();
  const cfg = workspace.getConfiguration("rigor", folder.uri);
  if (!cfg.get<boolean>("enable", true)) {
    return;
  }

  const rootDir = (cfg.get<string>("rootDir") ?? "").trim();
  if (rootDir) {
    const root = projectRoot(folder);
    let problem: string | undefined;
    if (!root) {
      problem = "is outside the workspace folder. It must be a subdirectory.";
    } else if (!fs.existsSync(root)) {
      problem = "does not exist.";
    } else {
      problem = "has no .rigor.yml or .rigor.dist.yml (and Gemfile.lock does not pin rigortype).";
    }
    if (explained.get(key) !== `rootDir:${rootDir}`) {
      explained.set(key, `rootDir:${rootDir}`);
      void window.showWarningMessage(
        `Rigor: "rigor.rootDir" for ${folder.name} is "${rootDir}", which ${problem}`,
      );
    }
    return;
  }

  const dismissed =
    extensionContext.workspaceState.get<string[]>(NESTED_DISMISSED_KEY) ?? [];
  if (explained.get(key) === "nested" || dismissed.includes(key)) {
    return;
  }
  // `undefined` keeps the user's `files.exclude` (and search excludes).
  const found = await workspace.findFiles(
    new RelativePattern(folder, "**/.rigor{,.dist}.yml"),
    undefined,
    50,
  );
  const dirs = [
    ...new Set(
      found
        .map((uri) => path.relative(folder.uri.fsPath, path.dirname(uri.fsPath)))
        .filter((dir) => dir !== "")
        .map((dir) => dir.split(path.sep))
        .filter((parts) => !parts.some((part) => SKIPPED_DIRS.has(part)))
        .map((parts) => parts.join("/")),
    ),
  ].sort(
    (a, b) => a.split("/").length - b.split("/").length || a.localeCompare(b),
  );
  if (dirs.length === 0 || explained.get(key) === "nested") {
    return;
  }
  explained.set(key, "nested");

  const choices = dirs.slice(0, 3).map((dir) => `Use ${dir}`);
  const openSettings = "Open Settings";
  const dontAsk = "Don't Ask Again";
  const choice = await window.showInformationMessage(
    `Rigor: ${folder.name} has no Rigor config at its root, so no server ` +
      `started. Found one in ${dirs.join(", ")}. Set "rigor.rootDir" to ` +
      "start the server there.",
    ...choices,
    openSettings,
    dontAsk,
  );
  try {
    if (choice === openSettings) {
      await commands.executeCommand(
        "workbench.action.openSettings",
        "rigor.rootDir",
      );
    } else if (choice === dontAsk) {
      await extensionContext.workspaceState.update(NESTED_DISMISSED_KEY, [
        ...dismissed,
        key,
      ]);
    } else if (choice) {
      const dir = dirs[choices.indexOf(choice)];
      await cfg.update("rootDir", dir, ConfigurationTarget.WorkspaceFolder);
    }
  } catch (err) {
    void window.showErrorMessage(
      `Rigor: could not set "rigor.rootDir": ${String(err)}`,
    );
  }
}

function reportProbeFailure(
  server: ResolvedServer,
  probe: ProbeResult,
  label: string,
): void {
  if (probe.tooOld) {
    void window.showWarningMessage(
      `Rigor: ${label} has rigortype ${probe.version}, but the extension ` +
        `needs >= ${MIN_VERSION} (the version that ships \`rigor lsp\`). ` +
        `Update the gem, then run "Rigor: Restart Server".`,
    );
    return;
  }

  const install = "Installation help";
  void window
    .showErrorMessage(
      `Rigor: could not run \`${server.command}\` in ${label}. ` +
        "Install Rigor so `rigor` is on `PATH` (`mise use gem:rigortype` " +
        "is the recommended setup), or set `rigor.server.path` to the " +
        'executable, then run "Rigor: Restart Server".',
      install,
    )
    .then((choice) => {
      if (choice === install) {
        void commands.executeCommand("vscode.open", Uri.parse(DOCS_URL));
      }
    });
}

function logStartup(
  label: string,
  root: string,
  server: ResolvedServer,
  commandLine: string,
  version: string | undefined,
  outcome: string,
): void {
  outputChannel.appendLine(
    [
      `[rigor] ${label}: ${outcome}`,
      `  extension ${extensionVersion} · rigortype ${version ?? "unknown"} · ${server.kind}`,
      `  root: ${root}`,
      `  command: ${commandLine}`,
    ].join("\n"),
  );
}

function showServerVersion(): void {
  const folders = statusBar.entries();
  if (folders.length === 0) {
    void window.showInformationMessage(
      `Rigor: no language server is running (extension ${extensionVersion}).`,
    );
    return;
  }
  void window.showInformationMessage(
    `Rigor (extension ${extensionVersion}) — ` +
      folders.map(describeFolder).join("; "),
  );
}

async function showServerLog(): Promise<void> {
  const withLog = (workspace.workspaceFolders ?? []).filter(
    (folder) => logPathFor(folder) !== "",
  );
  if (withLog.length === 0) {
    void window.showInformationMessage(
      'Rigor: no log file configured. Set "rigor.server.logPath" to capture ' +
        "the server log to a file.",
    );
    return;
  }

  let folder: WorkspaceFolder | undefined;
  const active = window.activeTextEditor?.document.uri;
  const activeFolder = active ? workspace.getWorkspaceFolder(active) : undefined;
  if (withLog.length === 1) {
    folder = withLog[0];
  } else if (activeFolder && withLog.includes(activeFolder)) {
    folder = activeFolder;
  } else {
    folder = await window.showWorkspaceFolderPick({
      placeHolder: "Show the Rigor server log of which folder?",
    });
    if (folder && !withLog.includes(folder)) {
      void window.showInformationMessage(
        `Rigor: ${folder.name} has no "rigor.server.logPath" configured.`,
      );
      return;
    }
  }
  if (!folder) {
    return;
  }

  // The server runs in the project root, so a relative path resolves there.
  const logPath = logPathFor(folder);
  const root = projectRoot(folder) ?? folder.uri.fsPath;
  const uri = path.isAbsolute(logPath)
    ? Uri.file(logPath)
    : Uri.file(path.join(root, logPath));
  void window.showTextDocument(uri);
}

function logPathFor(folder: WorkspaceFolder): string {
  return (
    workspace
      .getConfiguration("rigor", folder.uri)
      .get<string>("server.logPath") ?? ""
  ).trim();
}

/** `api (api/)` when the project root is a subdirectory, else `api`. */
function folderLabel(folder: WorkspaceFolder, root: string): string {
  const relative = path.relative(folder.uri.fsPath, root);
  if (relative === "") {
    return folder.name;
  }
  return `${folder.name} (${relative.split(path.sep).join("/")}/)`;
}

/**
 * A glob matching every file under `root`. Forward slashes so it matches
 * on Windows too. `*`, `?`, `[` and `]` are wrapped in a character class
 * (`[[]`, `[]]`, ...) so `a[1]` matches literally. A brace cannot be: VS
 * Code splits glob segments on `{`/`}` before it reads brackets, so `[{]`
 * opens a group that never closes. A brace becomes `?` instead, which also
 * matches a sibling directory differing in just that character.
 */
function rootGlob(root: string): string {
  const base = root
    .replace(/\\/g, "/")
    .replace(/[*?[\]]/g, "[$&]")
    .replace(/[{}]/g, "?");
  return `${base}/**/*`;
}
