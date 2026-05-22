// Rigor VSCode extension — a thin LSP client over `rigor lsp`.
//
// The extension implements no language features itself: diagnostics,
// hover, completion, and the outline view all come from the language
// server via `vscode-languageclient`. The extension owns discovery,
// configuration, lifecycle commands, the status bar, and — because the
// v1 LSP is single-root — one client per Rigor-configured folder.

import * as path from "path";
import {
  ConfigurationChangeEvent,
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
import { ResolvedServer, lspArgs, resolveServer, shouldManageFolder } from "./discovery";
import { MIN_VERSION, ProbeResult, probeServer } from "./probe";
import { StatusBar } from "./status";

const DOCS_URL = "https://github.com/rigortype/rigor";

/** Settings that change the server invocation and require a restart. */
const SERVER_AFFECTING_SETTINGS = [
  "rigor.enable",
  "rigor.server.path",
  "rigor.server.useBundler",
  "rigor.server.configPath",
  "rigor.server.logPath",
];

interface ManagedClient {
  client: LanguageClient;
  disposables: Disposable[];
}

let outputChannel: OutputChannel;
let statusBar: StatusBar;
const clients = new Map<string, ManagedClient>();

export function activate(context: ExtensionContext): void {
  outputChannel = window.createOutputChannel("Rigor");
  statusBar = new StatusBar();
  context.subscriptions.push(outputChannel, statusBar);

  context.subscriptions.push(
    commands.registerCommand("rigor.restartServer", () => restartAll()),
    commands.registerCommand("rigor.showOutputChannel", () =>
      outputChannel.show(),
    ),
    commands.registerCommand("rigor.showServerLog", () => showServerLog()),
  );

  context.subscriptions.push(
    workspace.onDidChangeWorkspaceFolders(() => syncClients()),
    workspace.onDidChangeConfiguration((e) => onConfigChange(e)),
    workspace.onDidGrantWorkspaceTrust(() => syncClients()),
  );

  void syncClients();
}

export async function deactivate(): Promise<void> {
  await stopAll();
}

/** Bring the running clients in line with the current workspace state. */
async function syncClients(): Promise<void> {
  if (!workspace.isTrusted) {
    // Spawning `bundle exec rigor` is withheld in untrusted workspaces.
    await stopAll();
    statusBar.set("stopped");
    return;
  }

  const folders = workspace.workspaceFolders ?? [];
  const wanted = new Set<string>();

  for (const folder of folders) {
    if (shouldManageFolder(folder)) {
      wanted.add(folder.uri.toString());
      await startClient(folder);
    }
  }

  for (const key of [...clients.keys()]) {
    if (!wanted.has(key)) {
      await stopClient(key);
    }
  }

  if (clients.size === 0) {
    statusBar.set("stopped");
  }
}

async function startClient(folder: WorkspaceFolder): Promise<void> {
  const key = folder.uri.toString();
  if (clients.has(key)) {
    return;
  }

  const server = resolveServer(folder);
  statusBar.set("starting");

  const probe = await probeServer(server, folder.uri.fsPath);
  if (!probe.ok) {
    statusBar.set("error");
    reportProbeFailure(server, probe, folder);
    return;
  }

  const serverOptions: ServerOptions = {
    command: server.command,
    args: lspArgs(server, folder),
    options: {
      cwd: folder.uri.fsPath,
      shell: process.platform === "win32",
    },
  };

  const watchers = [
    workspace.createFileSystemWatcher(new RelativePattern(folder, ".rigor.yml")),
    workspace.createFileSystemWatcher(
      new RelativePattern(folder, ".rigor.dist.yml"),
    ),
    workspace.createFileSystemWatcher(
      new RelativePattern(folder, "Gemfile.lock"),
    ),
  ];

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "ruby" }],
    workspaceFolder: folder,
    outputChannel,
    revealOutputChannelOn: RevealOutputChannelOn.Never,
    synchronize: { fileEvents: watchers },
  };

  const client = new LanguageClient("rigor", "Rigor", serverOptions, clientOptions);
  clients.set(key, { client, disposables: watchers });

  try {
    await client.start();
    statusBar.set("running");
  } catch (err) {
    statusBar.set("error");
    outputChannel.appendLine(
      `[rigor] failed to start the server for ${folder.name}: ${String(err)}`,
    );
    await stopClient(key);
  }
}

async function stopClient(key: string): Promise<void> {
  const managed = clients.get(key);
  if (!managed) {
    return;
  }
  clients.delete(key);
  for (const disposable of managed.disposables) {
    disposable.dispose();
  }
  try {
    await managed.client.stop();
  } catch {
    // The server may already be gone; nothing actionable here.
  }
}

async function stopAll(): Promise<void> {
  for (const key of [...clients.keys()]) {
    await stopClient(key);
  }
}

async function restartAll(): Promise<void> {
  await stopAll();
  await syncClients();
}

function onConfigChange(e: ConfigurationChangeEvent): void {
  if (SERVER_AFFECTING_SETTINGS.some((s) => e.affectsConfiguration(s))) {
    void restartAll();
  }
}

function reportProbeFailure(
  server: ResolvedServer,
  probe: ProbeResult,
  folder: WorkspaceFolder,
): void {
  if (probe.tooOld) {
    void window.showWarningMessage(
      `Rigor: ${folder.name} has rigortype ${probe.version}, but the extension ` +
        `needs >= ${MIN_VERSION} (the version that ships \`rigor lsp\`). ` +
        `Update the gem, then run "Rigor: Restart Server".`,
    );
    return;
  }

  const install = "Installation help";
  void window
    .showErrorMessage(
      `Rigor: could not run \`${server.command}\` in ${folder.name}. ` +
        "Add `rigortype` to the project's Gemfile (or install the gem " +
        'globally), then run "Rigor: Restart Server".',
      install,
    )
    .then((choice) => {
      if (choice === install) {
        void commands.executeCommand("vscode.open", Uri.parse(DOCS_URL));
      }
    });
}

function showServerLog(): void {
  const folder = workspace.workspaceFolders?.[0];
  const logPath = folder
    ? (
        workspace
          .getConfiguration("rigor", folder.uri)
          .get<string>("server.logPath") ?? ""
      ).trim()
    : "";

  if (!folder || !logPath) {
    void window.showInformationMessage(
      'Rigor: no log file configured. Set "rigor.server.logPath" to capture ' +
        "the server log to a file.",
    );
    return;
  }

  const uri = path.isAbsolute(logPath)
    ? Uri.file(logPath)
    : Uri.file(path.join(folder.uri.fsPath, logPath));
  void window.showTextDocument(uri);
}
