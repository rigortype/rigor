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
  return lockPinsRigortype(path.join(folderPath, "Gemfile.lock"));
}

/** Whether a Bundler lockfile pins the `rigortype` gem. */
export function lockPinsRigortype(lockfile: string): boolean {
  try {
    const contents = fs.readFileSync(lockfile, "utf8");
    // Bundler indents gem entries by four spaces under `specs:`.
    return /^\s{4}rigortype\s/m.test(contents);
  } catch {
    return false;
  }
}

/** The canonical pinned bundle (ADR-27 WD9), relative to the project root. */
export const PINNED_BUNDLE_GEMFILE = path.join(".github", "rigor", "Gemfile");

/**
 * The pinned bundle's Gemfile for a project root: `rigor.server.bundleGemfile`
 * resolved against the root when set, else `.github/rigor/Gemfile`.
 * `explicit` says which.
 */
export function pinnedBundleGemfile(
  folder: WorkspaceFolder,
  root: string,
): { gemfile: string; explicit: boolean } {
  const configured = (
    workspace
      .getConfiguration("rigor", folder.uri)
      .get<string>("server.bundleGemfile") ?? ""
  ).trim();
  return configured
    ? { gemfile: path.resolve(root, configured), explicit: true }
    : { gemfile: path.join(root, PINNED_BUNDLE_GEMFILE), explicit: false };
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
    lockPinsRigortype(lockfileFor(pinnedBundleGemfile(folder, root).gemfile))
  );
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
  for (const lock of [
    path.join(root, "Gemfile.lock"),
    path.join(root, ".github", "rigor", "Gemfile.lock"),
  ]) {
    if (lockfileHasRigortype(path.dirname(lock))) {
      return lock;
    }
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
        return file;
      }
    }
    const parent = path.dirname(dir);
    if (parent === dir) {
      break;
    }
    dir = parent;
  }
  if (globalPinInstalled()) {
    return globalFiles.find(fileNamesRigortype);
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
function pinFilesIn(dir: string): string[] {
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
export function pathExecutables(name: string): string[] {
  const sep = process.platform === "win32" ? ";" : ":";
  const candidates =
    process.platform === "win32"
      ? [name, `${name}.exe`, `${name}.cmd`, `${name}.bat`]
      : [name];
  const found: string[] = [];
  for (const dir of (process.env.PATH ?? "").split(sep)) {
    if (!dir) {
      continue;
    }
    for (const candidate of candidates) {
      const file = path.resolve(dir, candidate);
      try {
        if (
          !found.includes(file) &&
          fs.existsSync(file) &&
          fs.statSync(file).isFile()
        ) {
          found.push(file);
        }
      } catch {
        // Unreadable PATH entry — skip it.
      }
    }
  }
  return found;
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

  const shims: string[] = [];
  for (const dir of dirs) {
    const shim = path.join(dir, "rigor");
    try {
      if (!shims.includes(shim) && fs.existsSync(shim)) {
        shims.push(shim);
      }
    } catch {
      // Unreadable candidate — skip it.
    }
  }
  return shims;
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
