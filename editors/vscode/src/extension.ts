// Rigor VS Code extension — a thin LSP client over `rigor lsp`.
//
// The extension implements no language features itself: diagnostics,
// hover, completion, and the outline view all come from the language
// server via `vscode-languageclient`. The extension owns discovery,
// configuration, lifecycle commands, the status bar, and — because the
// v1 LSP is single-root — one client per Rigor-configured folder.

import { ChildProcess, spawn } from "child_process";
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
  managedReachable,
  projectRoot,
  resolveServer,
  shouldManageFolder,
  useShell,
} from "./discovery";
import { clearRuleCache, registerCommands } from "./commands";
import { killTree } from "./kill";
import { killAllCli, shellInvocation } from "./proc";
import { MIN_VERSION, ProbeResult, probeServer } from "./probe";
import {
  INSTALL_GUIDE_URL,
  initRuntime,
  installManaged,
  disposeRuntime,
  managedServer,
  offerInit,
  registerRuntimeCommands,
  setInUse,
} from "./runtime";
import { FolderStatus, StatusBar, describeFolder } from "./status";
import { registerTasks } from "./tasks";

/** Settings that change the server invocation and require a restart. */
const SERVER_AFFECTING_SETTINGS = [
  "rigor.enable",
  "rigor.rootDir",
  "rigor.server.path",
  "rigor.server.useBundler",
  "rigor.server.configPath",
  "rigor.server.logPath",
  "rigor.runtime.version",
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
  /**
   * Cut the client off from a server that is about to be killed while the
   * client is not `Running`, so the kill is not reported as a lost
   * connection (two library toasts), and release what the unfinished start
   * left registered.
   */
  cutOff(): void;
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
/** Whether the fall-through-to-managed notice was shown this session. */
let fallThroughShown = false;
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
  registerTasks(context);
  initRuntime(context);
  registerRuntimeCommands(context, outputChannel, afterManagedInstall, (task) =>
    enqueue(async () => {
      await stopAllNow();
      try {
        await task();
      } finally {
        await syncClientsNow();
      }
    }),
  );

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
  registerCommands(context, outputChannel);

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
  killAllCli();
  if (syncTimer) {
    clearTimeout(syncTimer);
  }
  await Promise.all(
    [...clients.keys()].map((key) => stopClient(key, SHUTDOWN_STOP_MS, 0)),
  );
  disposeRuntime();
}

/** Bring the running clients in line with the current workspace state. */
function syncClients(): Promise<void> {
  return enqueue(syncClientsNow);
}

function restartAll(): Promise<void> {
  return enqueue(async () => {
    probeFailureReported.clear();
    clearRuleCache();
    await stopAllNow();
    await syncClientsNow();
  });
}

async function syncClientsNow(): Promise<void> {
  if (!workspace.isTrusted) {
    // Spawning `bundle exec rigor` is withheld in untrusted workspaces.
    await stopAllNow();
    void setManagedContext(false);
    return;
  }

  const folders = workspace.workspaceFolders ?? [];
  const wanted = new Set<string>();
  // Before any client start (each may probe for seconds), so the palette
  // entries do not lag the folder state.
  void setManagedContext(folders.some((f) => shouldManageFolder(f)));

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

/** Drives the `when` clause of the CLI-backed commands. */
async function setManagedContext(value: boolean): Promise<void> {
  await commands.executeCommand("setContext", "rigor.managedFolder", value);
}

async function startClient(folder: WorkspaceFolder): Promise<void> {
  const key = folder.uri.toString();
  if (clients.has(key)) {
    return;
  }
  // `shouldManageFolder` only returns true for a root inside the folder.
  const root = projectRoot(folder) ?? folder.uri.fsPath;
  const label = folderLabel(folder, root);

  let server = resolveServer(folder);
  statusBar.update(key, { label, state: "starting", kind: server.kind });

  let probe = await probeServer(server, root);
  // A `rigor` on PATH or a shim that exists but does not run would hide
  // an installed managed Rigor behind it for good: fall through to it.
  // Not for a `rigor` that runs but is too old: that one gets the
  // upgrade warning, since it is the user's own install.
  if (
    !probe.ok &&
    !probe.tooOld &&
    server.kind !== "managed" &&
    managedReachable(server.kind, root)
  ) {
    const fallback = managedServer();
    if (fallback && !shuttingDown) {
      const fallbackProbe = await probeServer(fallback, root);
      if (fallbackProbe.ok) {
        const note = `\`${server.command}\` (${server.kind}) did not run in ${label}, so the managed Rigor serves it.`;
        outputChannel.appendLine(`[rigor] ${note}`);
        if (!fallThroughShown) {
          fallThroughShown = true;
          void window.showInformationMessage(`Rigor: ${note}`);
        }
        server = fallback;
        probe = fallbackProbe;
      }
    }
  }
  const args = lspArgs(server, folder);
  const commandLine = [server.command, ...args].join(" ");
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
      reportProbeFailure(server, probe, label, root);
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
    const shell = useShell(server);
    const invocation = shellInvocation(server.command, args, shell);
    const spawned = spawn(invocation.command, invocation.args, {
      cwd: root,
      env: server.env,
      shell,
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
      // `dispose` leaves a pending partial-message timer armed, which
      // re-arms itself every period; a zero timeout ends that chain.
      reader.partialMessageTimeout = 0;
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
  // A restart the client starts itself after a crash is not on the
  // extension's start timeout, so it gets its own.
  let restartTimer: NodeJS.Timeout | undefined;
  const clearRestartTimer = (): void => {
    if (restartTimer) {
      clearTimeout(restartTimer);
      restartTimer = undefined;
    }
  };
  const cutOff = (): void => {
    detach();
    client.diagnostics?.dispose();
  };
  const stateListener = client.onDidChangeState((e) => {
    if (abandoned || !running) {
      return;
    }
    clearRestartTimer();
    if (e.newState === State.Starting) {
      restartTimer = setTimeout(() => {
        restartTimer = undefined;
        if (abandoned) {
          return;
        }
        const message = `the restarted server did not answer \`initialize\` within ${START_TIMEOUT_MS / 1000} s`;
        statusBar.update(key, { ...running!, state: "error" });
        outputChannel.appendLine(`[rigor] ${label}: ${message}`);
        void discardClient(message);
      }, START_TIMEOUT_MS);
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
  const disposables = [
    ...watchers,
    stateListener,
    { dispose: clearRestartTimer },
  ];
  // Gives up on a client the extension still holds: out of `clients`,
  // transports detached (see `cutOff`), server killed, client disposed.
  const discardClient = async (toastMessage?: string): Promise<void> => {
    clients.delete(key);
    setInUse(key, undefined);
    for (const disposable of disposables) {
      disposable.dispose();
    }
    abandoned = true;
    if (toastMessage !== undefined) {
      // Killing the server closes the connection, which the client would
      // report as two more errors (the rejected `initialize`, then
      // "couldn't create connection"). Detached first, the pending
      // `initialize` is simply never answered and the client says nothing;
      // this is the one message.
      cutOff();
      void window
        .showErrorMessage(`Rigor: ${label}: ${toastMessage}.`, "Show Output")
        .then((choice) => choice && outputChannel.show());
    }
    // Kill before disposing, so a late `initialize` answer cannot register
    // providers on an abandoned client.
    await reap(child, 0);
    await client.dispose(STOP_TIMEOUT_MS).catch(() => undefined);
  };
  // Before the spawn, so a prune in another window keeps this version.
  setInUse(key, server);
  clients.set(key, {
    client,
    disposables,
    process: () => child,
    abandon: () => {
      abandoned = true;
    },
    cutOff,
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
    await discardClient(
      err instanceof StartTimeoutError ? err.message : undefined,
    );
  }
}

async function stopClient(
  key: string,
  stopTimeoutMs = STOP_TIMEOUT_MS,
  exitGraceMs = EXIT_GRACE_MS,
): Promise<void> {
  statusBar.remove(key);
  setInUse(key, undefined);
  const managed = clients.get(key);
  if (!managed) {
    return;
  }
  clients.delete(key);
  managed.abandon();
  for (const disposable of managed.disposables) {
    disposable.dispose();
  }
  // `stop()` cannot shut down a client that is still starting (the
  // library's own restart after a crash, or the first start at deactivate),
  // so the server is killed below; cut the client off first, or the closed
  // connection shows the library's two error toasts.
  const unfinished = managed.client.state !== State.Running;
  if (unfinished) {
    managed.cutOff();
  }
  try {
    await managed.client.stop(stopTimeoutMs);
  } catch {
    // The server may already be gone, or ignored `shutdown`; reaped below.
  }
  await reap(managed.process(), exitGraceMs);
  if (unfinished) {
    await managed.client.dispose(stopTimeoutMs).catch(() => undefined);
  }
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
      problem = path.isAbsolute(rootDir)
        ? 'is an absolute path. Use a path relative to the folder, such as "sub".'
        : "is outside the workspace folder. It must be a subdirectory.";
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
  root: string,
): void {
  if (probe.tooOld) {
    void window.showWarningMessage(
      `Rigor: ${label} has rigortype ${probe.version}, but the extension ` +
        `needs >= ${MIN_VERSION} (the version that ships \`rigor lsp\`). ` +
        `Update the gem, then run "Rigor: Restart Server".`,
    );
    return;
  }

  const guide = "Installation guide";
  // The managed install is offered only where discovery would fall
  // through to it: no explicit path, no Bundler, no project pin (ADR-27
  // WD9). When one is installed and still failed, offer to repair it.
  const offerManaged = managedReachable(server.kind, root);
  const repair = offerManaged && managedServer() !== undefined;
  const managed = repair ? "Repair Managed Rigor" : "Install Rigor for this editor";
  const choices = offerManaged ? [managed, guide] : [guide];
  void window
    .showErrorMessage(
      `Rigor: could not run \`${server.command}\` in ${label}. ` +
        "Install Rigor so `rigor` is on `PATH` (`mise use gem:rigortype` " +
        "is the recommended setup), or set `rigor.server.path` to the " +
        'executable, then run "Rigor: Restart Server".' +
        (repair
          ? " The managed Rigor did not run either; repairing reinstalls it."
          : offerManaged
            ? " Or let the extension install a Rigor of its own (needs Ruby 4.0)."
            : ""),
      ...choices,
    )
    .then(async (choice) => {
      if (choice === guide) {
        void commands.executeCommand("vscode.open", Uri.parse(INSTALL_GUIDE_URL));
      } else if (
        choice === managed &&
        (await installManaged(outputChannel, { repair }))
      ) {
        await afterManagedInstall();
      }
    });
}

/**
 * Restart after a managed install; when no folder has a Rigor config, so
 * nothing started, say so and offer `rigor init`.
 */
async function afterManagedInstall(): Promise<void> {
  await restartAll();
  const folders = workspace.workspaceFolders ?? [];
  if (!folders.some((folder) => shouldManageFolder(folder))) {
    await offerInit(folders, outputChannel, restartAll);
  }
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
