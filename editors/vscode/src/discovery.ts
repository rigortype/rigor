// Server discovery — locate the `rigor` executable for a workspace
// folder and build the argument vectors for `rigor lsp` / `rigor version`.

import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { WorkspaceFolder, workspace } from "vscode";

export type BundlerMode = "auto" | "always" | "never";

export type DiscoveryKind =
  | "explicit"
  | "bundler"
  | "global"
  | "version-manager";

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
 * The directory that holds the folder's Rigor project: the folder itself,
 * or `rigor.rootDir` resolved against it. Returns undefined when the
 * setting is absolute or points outside the folder, so a typo cannot root
 * a server in an unrelated directory. The problem matcher's file base
 * (`${config:rigor.rootDir}`) assumes the relative form.
 */
export function projectRoot(folder: WorkspaceFolder): string | undefined {
  const cfg = workspace.getConfiguration("rigor", folder.uri);
  const rootDir = (cfg.get<string>("rootDir") ?? "").trim();
  const folderPath = folder.uri.fsPath;
  if (!rootDir) {
    return folderPath;
  }
  if (path.isAbsolute(rootDir)) {
    return undefined;
  }
  const resolved = path.resolve(folderPath, rootDir);
  const relative = path.relative(folderPath, resolved);
  if (
    relative === ".." ||
    relative.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relative)
  ) {
    return undefined;
  }
  return resolved;
}

/**
 * Decide whether the extension should manage a language client for this
 * workspace folder. We only start a server where there is positive
 * evidence the project uses Rigor — a config file, the gem in the
 * lockfile, or an explicit server path — so non-Rigor folders in a
 * multi-root workspace stay silent. The evidence is looked for in the
 * project root (`rigor.rootDir`), not necessarily the folder root.
 */
export function shouldManageFolder(folder: WorkspaceFolder): boolean {
  const cfg = workspace.getConfiguration("rigor", folder.uri);
  if (!cfg.get<boolean>("enable", true)) {
    return false;
  }
  const root = projectRoot(folder);
  if (!root || !fs.existsSync(root)) {
    return false;
  }
  if ((cfg.get<string>("server.path") ?? "").trim()) {
    return true;
  }
  return hasRigorConfig(root) || lockfileHasRigortype(root);
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
    (mode === "auto" &&
      lockfileHasRigortype(projectRoot(folder) ?? folder.uri.fsPath));

  if (useBundler) {
    return { kind: "bundler", command: "bundle", prefixArgs: ["exec", "rigor"] };
  }

  // Neither explicit nor Bundler. Prefer `rigor` from PATH; when PATH
  // does not carry it — common when a GUI-launched editor never ran
  // the shell's `mise activate` hook — fall back to a mise / asdf
  // shim, the recommended install path (ADR-27).
  if (isOnPath("rigor")) {
    return { kind: "global", command: "rigor", prefixArgs: [] };
  }
  const shim = versionManagerShim();
  if (shim) {
    return { kind: "version-manager", command: shim, prefixArgs: [] };
  }
  return { kind: "global", command: "rigor", prefixArgs: [] };
}

/** Whether `name` resolves to an executable on the current `PATH`. */
function isOnPath(name: string): boolean {
  const sep = process.platform === "win32" ? ";" : ":";
  const candidates =
    process.platform === "win32"
      ? [name, `${name}.exe`, `${name}.cmd`, `${name}.bat`]
      : [name];
  for (const dir of (process.env.PATH ?? "").split(sep)) {
    if (!dir) {
      continue;
    }
    for (const candidate of candidates) {
      try {
        if (fs.existsSync(path.join(dir, candidate))) {
          return true;
        }
      } catch {
        // Unreadable PATH entry — skip it.
      }
    }
  }
  return false;
}

/**
 * Locate a `rigor` shim installed by a runtime version manager.
 *
 * `mise` (the recommended install path) and `asdf` both expose an
 * installed gem's executables as fixed "shim" files at a stable
 * location. Unlike a PATH entry, a shim is found even when a
 * GUI-launched editor never ran the shell's `mise activate` hook.
 * Returns the first shim that exists, or undefined.
 */
function versionManagerShim(): string | undefined {
  const home = os.homedir();
  const dirs: string[] = [];

  // mise — honour MISE_DATA_DIR / XDG_DATA_HOME, then the default.
  if (process.env.MISE_DATA_DIR) {
    dirs.push(path.join(process.env.MISE_DATA_DIR, "shims"));
  }
  if (process.env.XDG_DATA_HOME) {
    dirs.push(path.join(process.env.XDG_DATA_HOME, "mise", "shims"));
  }
  dirs.push(path.join(home, ".local", "share", "mise", "shims"));

  // asdf — honour ASDF_DATA_DIR, then the default.
  if (process.env.ASDF_DATA_DIR) {
    dirs.push(path.join(process.env.ASDF_DATA_DIR, "shims"));
  }
  dirs.push(path.join(home, ".asdf", "shims"));

  for (const dir of dirs) {
    const shim = path.join(dir, "rigor");
    try {
      if (fs.existsSync(shim)) {
        return shim;
      }
    } catch {
      // Unreadable candidate — skip it.
    }
  }
  return undefined;
}

/** The `--config=` flag, shared by `rigor lsp` and `rigor check`. */
export function configArgs(folder: WorkspaceFolder): string[] {
  const cfg = workspace.getConfiguration("rigor", folder.uri);
  const configPath = (cfg.get<string>("server.configPath") ?? "").trim();
  return configPath ? [`--config=${configPath}`] : [];
}

/** Extra `rigor lsp` flags derived from settings. */
export function serverOptionArgs(folder: WorkspaceFolder): string[] {
  const cfg = workspace.getConfiguration("rigor", folder.uri);
  const logPath = (cfg.get<string>("server.logPath") ?? "").trim();
  return [...configArgs(folder), ...(logPath ? [`--log=${logPath}`] : [])];
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
