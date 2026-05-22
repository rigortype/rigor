// Server discovery — locate the `rigor` executable for a workspace
// folder and build the argument vectors for `rigor lsp` / `rigor version`.

import * as fs from "fs";
import * as path from "path";
import { WorkspaceFolder, workspace } from "vscode";

export type BundlerMode = "auto" | "always" | "never";

export type DiscoveryKind = "explicit" | "bundler" | "global";

export interface ResolvedServer {
  kind: DiscoveryKind;
  /** Executable to spawn. */
  command: string;
  /** Argument prefix that precedes the rigor subcommand. */
  prefixArgs: string[];
}

/** Whether the folder pins the `rigortype` gem in its lockfile. */
export function lockfileHasRigortype(folderPath: string): boolean {
  try {
    const contents = fs.readFileSync(
      path.join(folderPath, "Gemfile.lock"),
      "utf8",
    );
    // Bundler indents gem entries by four spaces under `specs:`.
    return /^\s{4}rigortype\s/m.test(contents);
  } catch {
    return false;
  }
}

/** Whether the folder carries a Rigor config file at its root. */
export function hasRigorConfig(folderPath: string): boolean {
  return (
    fs.existsSync(path.join(folderPath, ".rigor.yml")) ||
    fs.existsSync(path.join(folderPath, ".rigor.dist.yml"))
  );
}

/**
 * Decide whether the extension should manage a language client for this
 * workspace folder. We only start a server where there is positive
 * evidence the project uses Rigor — a config file, the gem in the
 * lockfile, or an explicit server path — so non-Rigor folders in a
 * multi-root workspace stay silent.
 */
export function shouldManageFolder(folder: WorkspaceFolder): boolean {
  const cfg = workspace.getConfiguration("rigor", folder.uri);
  if (!cfg.get<boolean>("enable", true)) {
    return false;
  }
  if ((cfg.get<string>("server.path") ?? "").trim()) {
    return true;
  }
  const folderPath = folder.uri.fsPath;
  return hasRigorConfig(folderPath) || lockfileHasRigortype(folderPath);
}

/** Resolve which executable to spawn for a folder. */
export function resolveServer(folder: WorkspaceFolder): ResolvedServer {
  const cfg = workspace.getConfiguration("rigor", folder.uri);
  const explicitPath = (cfg.get<string>("server.path") ?? "").trim();
  if (explicitPath) {
    return { kind: "explicit", command: explicitPath, prefixArgs: [] };
  }

  const mode = cfg.get<BundlerMode>("server.useBundler", "auto");
  const useBundler =
    mode === "always" ||
    (mode === "auto" && lockfileHasRigortype(folder.uri.fsPath));

  if (useBundler) {
    return { kind: "bundler", command: "bundle", prefixArgs: ["exec", "rigor"] };
  }
  return { kind: "global", command: "rigor", prefixArgs: [] };
}

/** Extra `rigor lsp` flags derived from settings. */
export function serverOptionArgs(folder: WorkspaceFolder): string[] {
  const cfg = workspace.getConfiguration("rigor", folder.uri);
  const args: string[] = [];
  const configPath = (cfg.get<string>("server.configPath") ?? "").trim();
  const logPath = (cfg.get<string>("server.logPath") ?? "").trim();
  if (configPath) {
    args.push(`--config=${configPath}`);
  }
  if (logPath) {
    args.push(`--log=${logPath}`);
  }
  return args;
}

/** Full argument vector for `rigor lsp`. */
export function lspArgs(
  server: ResolvedServer,
  folder: WorkspaceFolder,
): string[] {
  return [...server.prefixArgs, "lsp", ...serverOptionArgs(folder)];
}

/** Full argument vector for `rigor version`. */
export function versionArgs(server: ResolvedServer): string[] {
  return [...server.prefixArgs, "version"];
}
