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
  LanguageClient,
  LanguageClientOptions,
  RevealOutputChannelOn,
  ServerOptions,
} from "vscode-languageclient/node";
import {
  ResolvedServer,
  lspArgs,
  projectRoot,
  resolveServer,
  shouldManageFolder,
} from "./discovery";
import { MIN_VERSION, ProbeResult, probeServer } from "./probe";
import { StatusBar, describeFolder } from "./status";

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
 * How long to wait for the process to exit after `stop()` returned. The
 * client itself sends a terminate 2 s after stopping, so wait past that
 * before killing.
 */
const EXIT_GRACE_MS = 3000;

/** Directories never searched for a nested Rigor config. */
const NESTED_CONFIG_EXCLUDE = "**/{node_modules,vendor,.git}/**";

interface ManagedClient {
  client: LanguageClient;
  disposables: Disposable[];
  /** The spawned `rigor lsp` process, once the client has started it. */
  process(): ChildProcess | undefined;
}

let outputChannel: OutputChannel;
let statusBar: StatusBar;
let extensionVersion = "unknown";
const clients = new Map<string, ManagedClient>();

/** Folders already told about a nested config this session. */
const nestedConfigOffered = new Set<string>();

// Every start, stop, restart and sync runs through this chain, one at a
// time. Without it, a sync that is still probing `rigor version` (up to
// 20 s) and a second sync triggered meanwhile — a folder change, a trust
// grant, a restart — both see the folder as unmanaged and both start a
// server.
let lifecycle: Promise<void> = Promise.resolve();

function enqueue(task: () => Promise<void>): Promise<void> {
  const run = lifecycle.then(task);
  lifecycle = run.catch((err) => {
    outputChannel.appendLine(`[rigor] lifecycle error: ${String(err)}`);
  });
  return lifecycle;
}

export function activate(context: ExtensionContext): void {
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
  context.subscriptions.push(
    configWatcher,
    configWatcher.onDidCreate(() => void syncClients()),
    configWatcher.onDidDelete(() => void syncClients()),
    workspace.onDidChangeWorkspaceFolders(() => void syncClients()),
    workspace.onDidChangeConfiguration((e) => onConfigChange(e)),
    workspace.onDidGrantWorkspaceTrust(() => void syncClients()),
  );

  void syncClients();
}

export async function deactivate(): Promise<void> {
  await enqueue(stopAllNow);
}

/** Bring the running clients in line with the current workspace state. */
function syncClients(): Promise<void> {
  return enqueue(syncClientsNow);
}

function restartAll(): Promise<void> {
  return enqueue(async () => {
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
    reportProbeFailure(server, probe, label);
    return;
  }

  let child: ChildProcess | undefined;
  const serverOptions: ServerOptions = async () => {
    child = spawn(server.command, args, {
      cwd: root,
      shell: process.platform === "win32",
      windowsHide: true,
    });
    return child;
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
  };

  const client = new LanguageClient("rigor", "Rigor", serverOptions, clientOptions);
  clients.set(key, { client, disposables: watchers, process: () => child });

  try {
    await client.start();
    statusBar.update(key, {
      label,
      state: "running",
      kind: server.kind,
      version: probe.version,
      commandLine,
    });
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
    for (const disposable of watchers) {
      disposable.dispose();
    }
    // A start that failed part way leaves the spawned process running.
    await client.dispose(STOP_TIMEOUT_MS).catch(() => undefined);
    await reap(child);
  }
}

async function stopClient(key: string): Promise<void> {
  statusBar.remove(key);
  const managed = clients.get(key);
  if (!managed) {
    return;
  }
  clients.delete(key);
  for (const disposable of managed.disposables) {
    disposable.dispose();
  }
  try {
    await managed.client.stop(STOP_TIMEOUT_MS);
  } catch {
    // The server may already be gone, or ignored `shutdown`; reaped below.
  }
  await reap(managed.process());
}

async function stopAllNow(): Promise<void> {
  for (const key of [...clients.keys()]) {
    await stopClient(key);
  }
  statusBar.clear();
}

/** Wait for the process to exit, and kill it if it does not. */
async function reap(child: ChildProcess | undefined): Promise<void> {
  if (!child || child.exitCode !== null || child.signalCode !== null) {
    return;
  }
  const exited = await new Promise<boolean>((resolve) => {
    const timer = setTimeout(() => resolve(false), EXIT_GRACE_MS);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve(true);
    });
  });
  if (!exited) {
    outputChannel.appendLine(
      `[rigor] server process ${child.pid ?? "?"} did not exit; killing it`,
    );
    child.kill("SIGKILL");
  }
}

function onConfigChange(e: ConfigurationChangeEvent): void {
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
  if (nestedConfigOffered.has(key) || !cfg.get<boolean>("enable", true)) {
    return;
  }

  const rootDir = (cfg.get<string>("rootDir") ?? "").trim();
  if (rootDir) {
    const root = projectRoot(folder);
    if (!root || !fs.existsSync(root)) {
      nestedConfigOffered.add(key);
      void window.showWarningMessage(
        `Rigor: "rigor.rootDir" for ${folder.name} is "${rootDir}", which ` +
          (root
            ? "does not exist."
            : "is outside the workspace folder. It must be a subdirectory."),
      );
    }
    return;
  }

  const found = await workspace.findFiles(
    new RelativePattern(folder, "**/.rigor{,.dist}.yml"),
    NESTED_CONFIG_EXCLUDE,
    20,
  );
  const dirs = [
    ...new Set(
      found
        .map((uri) => path.relative(folder.uri.fsPath, path.dirname(uri.fsPath)))
        .filter((dir) => dir !== "")
        .map((dir) => dir.split(path.sep).join("/")),
    ),
  ].sort();
  if (dirs.length === 0 || nestedConfigOffered.has(key)) {
    return;
  }
  nestedConfigOffered.add(key);

  const choices = dirs.slice(0, 3).map((dir) => `Use ${dir}`);
  const openSettings = "Open Settings";
  const choice = await window.showInformationMessage(
    `Rigor: ${folder.name} has no Rigor config at its root, so no server ` +
      `started. Found one in ${dirs.join(", ")}. Set "rigor.rootDir" to ` +
      "start the server there.",
    ...choices,
    openSettings,
  );
  if (choice === openSettings) {
    void commands.executeCommand("workbench.action.openSettings", "rigor.rootDir");
  } else if (choice) {
    const dir = dirs[choices.indexOf(choice)];
    await cfg.update("rootDir", dir, ConfigurationTarget.WorkspaceFolder);
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
 * on Windows too; glob metacharacters in the path are wrapped in a
 * character class so a directory named `app{1}` matches literally.
 */
function rootGlob(root: string): string {
  const base = root.replace(/\\/g, "/").replace(/[*?{}]/g, "[$&]");
  return `${base}/**/*`;
}
