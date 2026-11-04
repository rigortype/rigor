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
  | "pinned-bundle"
  | "global"
  | "version-manager"
  | "managed";

export interface ResolvedServer {
  kind: DiscoveryKind;
  /** Executable to spawn. */
  command: string;
  /** Argument prefix that precedes the rigor subcommand. */
  prefixArgs: string[];
  /** Environment for the process, when it differs from the extension's. */
  env?: NodeJS.ProcessEnv;
  /** Spawn through a shell. Defaults to true on Windows only. */
  shell?: boolean;
  /** For the managed kind: the version directory it runs from. */
  runtimeDir?: string;
}

/** Whether to spawn the server through a shell. */
export function useShell(server: ResolvedServer): boolean {
  return server.shell ?? process.platform === "win32";
}

/** Whether the folder pins the `rigortype` gem in its lockfile. */
export function lockfileHasRigortype(folderPath: string): boolean {
  return projectLockPin(folderPath) !== undefined;
}

/**
 * The folder's own lockfile (`Gemfile.lock`, or `gems.locked` for a
 * `gems.rb`) when it pins `rigortype`, else undefined.
 */
export function projectLockPin(folderPath: string): string | undefined {
  return [
    path.join(folderPath, "Gemfile.lock"),
    path.join(folderPath, "gems.locked"),
  ].find(lockPinsRigortype);
}

/** Whether a Bundler lockfile pins the `rigortype` gem. */
export function lockPinsRigortype(lockfile: string): boolean {
  return lockedRigortype(lockfile) !== undefined;
}

/**
 * The `rigortype` version a Bundler lockfile pins, or undefined. Bundler
 * indents gem entries by four spaces under `specs:`.
 */
export function lockedRigortype(lockfile: string): string | undefined {
  try {
    const contents = fs.readFileSync(lockfile, "utf8");
    return /^\s{4}rigortype \(([^)]*)\)/m.exec(contents)?.[1];
  } catch {
    return undefined;
  }
}

/** The canonical pinned bundle (ADR-27 WD9), relative to the project root. */
export const PINNED_BUNDLE_GEMFILE = path.join(".github", "rigor", "Gemfile");

export interface PinnedBundle {
  gemfile: string;
  /** Set by `rigor.server.bundleGemfile` rather than the canonical path. */
  explicit: boolean;
  /**
   * The setting's raw value when it is absolute or leaves the project
   * root, the containment rule of `rigor.rootDir`. No pinned bundle is
   * used then.
   */
  rejected?: string;
}

/**
 * The pinned bundle's Gemfile for a project root: `rigor.server.bundleGemfile`
 * resolved against the root when set, else `.github/rigor/Gemfile`.
 */
export function pinnedBundleGemfile(
  folder: WorkspaceFolder,
  root: string,
): PinnedBundle {
  const configured = (
    workspace
      .getConfiguration("rigor", folder.uri)
      .get<string>("server.bundleGemfile") ?? ""
  ).trim();
  if (!configured) {
    return { gemfile: path.join(root, PINNED_BUNDLE_GEMFILE), explicit: false };
  }
  const gemfile = path.resolve(root, configured);
  return path.isAbsolute(configured) || !isBelow(gemfile, root)
    ? { gemfile, explicit: true, rejected: configured }
    : { gemfile, explicit: true };
}

/** Bundler's lockfile for a Gemfile: `gems.rb` locks to `gems.locked`. */
export function lockfileFor(gemfile: string): string {
  return path.basename(gemfile) === "gems.rb"
    ? path.join(path.dirname(gemfile), "gems.locked")
    : `${gemfile}.lock`;
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
  return (
    hasRigorConfig(root) ||
    lockfileHasRigortype(root) ||
    pinnedBundleLock(folder, root) !== undefined
  );
}

/** The pinned bundle's lockfile when it pins `rigortype`, else undefined. */
export function pinnedBundleLock(
  folder: WorkspaceFolder,
  root: string,
): string | undefined {
  const pinned = pinnedBundleGemfile(folder, root);
  const lock = lockfileFor(pinned.gemfile);
  return !pinned.rejected && lockPinsRigortype(lock) ? lock : undefined;
}

/**
 * The file through which the project pins `rigortype`, or undefined. Such
 * a project is served by its own pin or not at all, never by the managed
 * install. Read from the files rather than by running `mise`: a `mise`
 * command can run the user's configured auto-prune, which uninstalls
 * tools.
 *
 * - `Gemfile.lock` at the project root, or the CI-only
 *   `.github/rigor/Gemfile.lock` (manual chapter 11).
 * - A mise or asdf file in the project root or a directory above it,
 *   other than the home directory and its ancestors: the `[tools]` table
 *   must name `rigortype` or `gem:rigortype`.
 * - The user's global mise or asdf config (the home directory, its
 *   ancestors, and mise's global config files) only while a rigortype is
 *   installed through mise or asdf. A global pin that was
 *   never installed would otherwise block the managed Rigor everywhere.
 */
export function rigortypePin(root: string): string | undefined {
  return findPin(root)?.file;
}

/**
 * Like `rigortypePin`, and which kind of file pins: a Bundler lockfile, a
 * mise or asdf file of the project (the root or above it, below the home
 * directory), or the user's global one.
 */
export function findPin(
  root: string,
  options: { skipLocks?: boolean } = {},
): { file: string; scope: "lock" | "project" | "global" } | undefined {
  // `skipLocks`: `useBundler: never` opts out of a lockfile pin, so a
  // mise or asdf pin behind it still decides.
  const lock = options.skipLocks
    ? undefined
    : (projectLockPin(root) ??
      [lockfileFor(path.join(root, PINNED_BUNDLE_GEMFILE))].find(lockPinsRigortype));
  if (lock) {
    return { file: lock, scope: "lock" };
  }
  const home = path.resolve(os.homedir());
  const globalFiles = globalPinFiles(home);
  let dir = path.resolve(root);
  for (;;) {
    // The home directory and the directories above it hold the user's
    // own configuration, not the project's.
    const projectLevel = dir !== home && !isBelow(home, dir);
    for (const file of pinFilesIn(dir)) {
      if (!projectLevel) {
        globalFiles.push(file);
      } else if (fileNamesRigortype(file)) {
        return { file, scope: "project" };
      }
    }
    const parent = path.dirname(dir);
    if (parent === dir) {
      break;
    }
    dir = parent;
  }
  if (globalPinInstalled()) {
    const file = globalFiles.find(fileNamesRigortype);
    return file ? { file, scope: "global" } : undefined;
  }
  return undefined;
}

/** Whether `dir` is strictly inside `base`. */
function isBelow(dir: string, base: string): boolean {
  const relative = path.relative(base, dir);
  return (
    relative !== "" &&
    relative !== ".." &&
    !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative)
  );
}

/** The mise and asdf config files a directory can hold. */
export function pinFilesIn(dir: string): string[] {
  const envs = (process.env.MISE_ENV ?? "")
    .split(",")
    .map((e) => e.trim())
    .filter((e) => e !== "");
  const names = [
    "mise.toml",
    ".mise.toml",
    "mise.local.toml",
    ".mise.local.toml",
    ...envs.flatMap((e) => [`mise.${e}.toml`, `.mise.${e}.toml`]),
    path.join(".mise", "config.toml"),
    path.join("mise", "config.toml"),
    path.join(".config", "mise.toml"),
    path.join(".config", "mise", "config.toml"),
    ".tool-versions",
  ];
  return [
    ...names.map((name) => path.join(dir, name)),
    ...confD(path.join(dir, ".config", "mise", "conf.d")),
  ];
}

/** mise's global config, wherever the environment relocates it. */
function globalPinFiles(home: string): string[] {
  const configDir =
    process.env.MISE_CONFIG_DIR ??
    path.join(process.env.XDG_CONFIG_HOME ?? path.join(home, ".config"), "mise");
  return [
    ...(process.env.MISE_GLOBAL_CONFIG_FILE
      ? [process.env.MISE_GLOBAL_CONFIG_FILE]
      : []),
    path.join(configDir, "config.toml"),
    ...confD(path.join(configDir, "conf.d")),
  ];
}

function confD(dir: string): string[] {
  try {
    return fs
      .readdirSync(dir)
      .filter((name) => name.endsWith(".toml"))
      .map((name) => path.join(dir, name));
  } catch {
    return [];
  }
}

/** Whether a mise TOML file or an asdf `.tool-versions` names rigortype. */
function fileNamesRigortype(file: string): boolean {
  let text: string;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    return false;
  }
  if (path.basename(file) === ".tool-versions") {
    return /^\s*(gem:)?rigortype\s+\S/m.test(text);
  }
  return tomlToolsNameRigortype(text);
}

/**
 * Whether a mise TOML file pins rigortype: a `rigortype` / `gem:rigortype`
 * key in the `[tools]` table, a `[tools."gem:rigortype"]` table, a root
 * dotted key (`tools."gem:rigortype" = ...`), or a root inline table
 * (`tools = { "gem:rigortype" = ... }`, on one line). A line-level
 * reading: enough for the forms mise documents. Lines inside a multi-line
 * string are skipped, and a comment or another table that merely
 * mentions rigortype is no pin.
 */
export function tomlToolsNameRigortype(text: string): boolean {
  const key = `(["']?)(gem:)?rigortype\\1`;
  const header = /^\s*\[\s*([^\]]*?)\s*\]\s*(#.*)?$/;
  const toolKey = new RegExp(`^\\s*${key}\\s*=`);
  const toolTable = new RegExp(`^tools\\s*\\.\\s*${key}$`);
  const dottedKey = new RegExp(`^\\s*tools\\s*\\.\\s*${key}\\s*=`);
  const inlineTable = new RegExp(`^\\s*tools\\s*=\\s*\\{(?:.*?,)?\\s*${key}\\s*=`);
  let section = "";
  /** The delimiter of the multi-line string the line starts in, if any. */
  let inString: string | undefined;
  for (const line of text.split(/\r?\n/)) {
    const before = inString;
    inString = multilineStringAfter(line, inString);
    if (before) {
      continue;
    }
    const match = header.exec(line);
    if (match) {
      section = match[1];
      if (toolTable.test(section)) {
        return true;
      }
      continue;
    }
    if (section === "tools" && toolKey.test(line)) {
      return true;
    }
    if (section === "" && (dottedKey.test(line) || inlineTable.test(line))) {
      return true;
    }
  }
  return false;
}

/**
 * The multi-line string delimiter (`"""` or `'''`) still open at the end
 * of `line`, given the one open at its start. The two are tracked apart:
 * a `"""` inside a `'''` string, or the other way round, is text, and so
 * is either inside a single-line string (`x = '"""'`) or after a `#`
 * comment. A backslash escapes in `"..."` and `"""..."""`, as in TOML.
 */
export function multilineStringAfter(
  line: string,
  open: string | undefined,
): string | undefined {
  let current = open;
  let i = 0;
  while (i < line.length) {
    if (current === '"""') {
      if (line[i] === "\\") {
        i += 2;
      } else if (line.startsWith('"""', i)) {
        current = undefined;
        i += 3;
      } else {
        i++;
      }
      continue;
    }
    if (current === "'''") {
      if (line.startsWith("'''", i)) {
        current = undefined;
        i += 3;
      } else {
        i++;
      }
      continue;
    }
    const c = line[i];
    if (c === "#") {
      break;
    }
    if (line.startsWith('"""', i) || line.startsWith("'''", i)) {
      current = line.slice(i, i + 3);
      i += 3;
    } else if (c === '"') {
      i++;
      while (i < line.length && line[i] !== '"') {
        i += line[i] === "\\" ? 2 : 1;
      }
      i++;
    } else if (c === "'") {
      i++;
      while (i < line.length && line[i] !== "'") {
        i++;
      }
      i++;
    } else {
      i++;
    }
  }
  return current;
}

/** Whether mise or asdf has a rigortype installed at all. */
function globalPinInstalled(): boolean {
  const home = os.homedir();
  const miseData =
    process.env.MISE_DATA_DIR ??
    path.join(process.env.XDG_DATA_HOME ?? path.join(home, ".local", "share"), "mise");
  const asdfData = process.env.ASDF_DATA_DIR ?? path.join(home, ".asdf");
  return [
    path.join(miseData, "installs", "gem-rigortype"),
    path.join(miseData, "installs", "rigortype"),
    path.join(asdfData, "installs", "rigortype"),
  ].some((dir) => {
    try {
      return fs.readdirSync(dir).length > 0;
    } catch {
      return false;
    }
  });
}

/**
 * Every file named `name` on the current `PATH`, in `PATH` order, as an
 * absolute path. Each is a separate discovery candidate: the first may
 * exist and not run (an rbenv shim for a Ruby without the gem).
 */
export function pathExecutables(name: string): {
  found: string[];
  /** Relative `PATH` entries (`.` among them), which are never searched. */
  skipped: string[];
} {
  const win = process.platform === "win32";
  const sep = win ? ";" : ":";
  // On Windows an extensionless `rigor` is the POSIX script RubyGems also
  // writes, which only a POSIX shell runs.
  const candidates = win
    ? [`${name}.bat`, `${name}.cmd`, `${name}.exe`]
    : [name];
  const found: string[] = [];
  const real = new Set<string>();
  const skipped: string[] = [];
  for (const dir of (process.env.PATH ?? "").split(sep)) {
    if (!dir) {
      continue;
    }
    // A relative entry resolves against the extension host's working
    // directory, which is no directory the user chose.
    if (!path.isAbsolute(dir)) {
      if (!skipped.includes(dir)) {
        skipped.push(dir);
      }
      continue;
    }
    for (const candidate of candidates) {
      const file = path.join(dir, candidate);
      try {
        if (!fs.existsSync(file) || !fs.statSync(file).isFile()) {
          continue;
        }
        // The same file reached through two PATH entries (a symlinked
        // directory) is one candidate.
        const target = fs.realpathSync(file);
        if (!real.has(target)) {
          real.add(target);
          found.push(file);
        }
      } catch {
        // Unreadable PATH entry — skip it.
      }
    }
  }
  return { found, skipped };
}

/**
 * Locate a `rigor` shim installed by a runtime version manager.
 *
 * `mise` (the recommended install path) and `asdf` both expose an
 * installed gem's executables as fixed "shim" files at a stable
 * location. Unlike a PATH entry, a shim is found even when a
 * GUI-launched editor never ran the shell's `mise activate` hook.
 * Returns every shim that exists, mise's first.
 */
export function versionManagerShims(): string[] {
  const names =
    process.platform === "win32"
      ? ["rigor.bat", "rigor.cmd", "rigor.exe"]
      : ["rigor"];
  const shims: string[] = [];
  for (const root of versionManagerRoots()) {
    for (const name of names) {
      const shim = path.join(root, "shims", name);
      try {
        if (!shims.includes(shim) && fs.existsSync(shim)) {
          shims.push(shim);
        }
      } catch {
        // Unreadable candidate — skip it.
      }
    }
  }
  return shims;
}

/**
 * mise's and asdf's data directories, mise's first: `MISE_DATA_DIR`,
 * `XDG_DATA_HOME/mise`, then `%LOCALAPPDATA%\mise` on Windows or
 * `~/.local/share/mise` elsewhere; `ASDF_DATA_DIR`, then `~/.asdf`. Each
 * holds `shims/` and `installs/`. Read from the environment, never by
 * running `mise`.
 */
export function versionManagerRoots(): string[] {
  const home = os.homedir();
  const roots: string[] = [];
  if (process.env.MISE_DATA_DIR) {
    roots.push(process.env.MISE_DATA_DIR);
  }
  if (process.env.XDG_DATA_HOME) {
    roots.push(path.join(process.env.XDG_DATA_HOME, "mise"));
  }
  roots.push(
    process.platform === "win32"
      ? path.join(process.env.LOCALAPPDATA ?? path.join(home, "AppData", "Local"), "mise")
      : path.join(home, ".local", "share", "mise"),
  );
  if (process.env.ASDF_DATA_DIR) {
    roots.push(process.env.ASDF_DATA_DIR);
  }
  roots.push(path.join(home, ".asdf"));
  return [...new Set(roots)];
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

/**
 * The command line as the log and the status tooltip show it. The pinned
 * bundle's `BUNDLE_GEMFILE` is part of what runs, so it is shown first.
 */
export function displayCommand(server: ResolvedServer, args: string[]): string {
  const gemfile =
    server.kind === "pinned-bundle" ? server.env?.BUNDLE_GEMFILE : undefined;
  return [
    ...(gemfile ? [`BUNDLE_GEMFILE=${gemfile}`] : []),
    server.command,
    ...args,
  ].join(" ");
}

/** Full argument vector for `rigor version`. */
export function versionArgs(server: ResolvedServer): string[] {
  return [...server.prefixArgs, "version"];
}
