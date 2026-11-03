// Managed runtime: a Rigor the extension installs for itself, for a user
// who has no `rigor` yet (ADR-27 WD9, issue #2725).
//
// The managed install is the last discovery kind: a project that pins
// `rigortype` (Gemfile.lock, mise, .tool-versions) is never served by it.
// Nothing is installed in an untrusted workspace, and nothing without a
// click. The tiers are what the machine already has:
//
// - A: a Ruby 4.0 exists. `bundle install` a one-line Gemfile into
//   `globalStorageUri/runtime/<version>/`, then run
//   `ruby <bundler> exec rigor` with that Gemfile.
// - B: no Ruby 4.0, but mise. Offer `mise install ruby@4.0`, then A.
// - C: neither. Point at the installation guide; the self-contained
//   binary that needs no Ruby is #926.
//
// The storage is per user, so every VS Code window shares it:
//
// - An install or a clear holds `runtime/.lock`: created exclusively,
//   re-read to confirm ownership, its timestamp refreshed every minute
//   while held, and removed only by its owner. A lock whose process is
//   gone, or whose heartbeat stopped LOCK_STALE_MS ago, is stale.
// - An install builds in `runtime/.tmp-*` and renames the finished
//   directory, manifest included, into place, so another window never
//   sees a half-installed version.
// - A window running a managed server leaves a marker named by its
//   extension host's pid in `<version>/.in-use/`, touched hourly and
//   removed when it stops using the version. Pruning skips a version with
//   a live marker (this window's included); a repair does not replace a
//   version another window runs. Only Clear deletes a version in use, and
//   says so.

import { ChildProcess, execFile, spawn } from "child_process";
import * as fs from "fs";
import * as https from "https";
import * as os from "os";
import * as path from "path";
import {
  CancellationToken,
  ExtensionContext,
  ExtensionMode,
  OutputChannel,
  ProgressLocation,
  Uri,
  WorkspaceFolder,
  commands,
  window,
  workspace,
} from "vscode";
import type { ResolvedServer } from "./discovery";
import { killTree } from "./kill";

export const INSTALL_GUIDE_URL =
  "https://github.com/rigortype/rigor/blob/master/docs/install.md";
const CONFIG_GUIDE_URL =
  "https://github.com/rigortype/rigor/blob/master/docs/manual/03-configuration.md";
const SINGLE_BINARY_URL = "https://github.com/rigortype/rigor/issues/926";
const LATEST_URL = "https://rubygems.org/api/v1/versions/rigortype/latest.json";
/**
 * `rigortype.gemspec`'s `required_ruby_version`, copied by hand (#2755).
 * The candidate Ruby checks `Gem.ruby_version` against it, which carries
 * a prerelease marker (`4.0.0.preview2`), so RubyGems' own rules decide.
 */
const REQUIRED_RUBY = [">= 4.0.0", "< 4.1"];
/** Installed versions kept on disk besides any a window still uses. */
const KEEP_VERSIONS = 2;
/** Inside each version directory; part of the rename, never written later. */
const MANIFEST = "rigor-runtime.json";
const LOCK = ".lock";
const IN_USE = ".in-use";
/** How often the lock holder refreshes the lock's timestamp. */
const LOCK_HEARTBEAT_MS = 60 * 1000;
/** A lock whose heartbeat stopped this long ago is stale (its pid reused). */
const LOCK_STALE_MS = 5 * 60 * 1000;
/** How often this window touches its in-use markers. */
const MARKER_TOUCH_MS = 60 * 60 * 1000;
/** A marker untouched this long belongs to a window that died uncleanly. */
const MARKER_STALE_MS = 24 * 60 * 60 * 1000;
/**
 * Development override: install `rigortype` from a local checkout
 * (`gem 'rigortype', path: ...`) instead of rubygems.org, to test the
 * install flow without a published version. Read only when the extension
 * runs in development or test mode.
 */
const DEV_GEM_PATH_ENV = "RIGOR_VSCODE_RUNTIME_GEM_PATH";
const DEV_VERSION = "dev";

interface Manifest {
  /** Directory name: the rigortype version, or `dev`. */
  version: string;
  /** What `rigor version` printed after the install. */
  rigortype: string;
  /** `RbConfig.ruby` of the Ruby the bundle was installed with. */
  ruby: string;
  /** That Ruby's `bundle` executable script. */
  bundler: string;
}

interface RubyCandidate {
  ruby: string;
  bundler: string;
  version: string;
}

let runtimeRoot: string | undefined;
let devGemPath: string | undefined;
let installing: Promise<boolean> | undefined;
/** The running `bundle install` / `mise install`, killed on deactivate. */
let activeChild: ChildProcess | undefined;
/** Folder key → the version directory its managed server runs from. */
const inUse = new Map<string, string>();
let markerTimer: NodeJS.Timeout | undefined;

/** Where managed versions live. Called once from `activate`. */
export function initRuntime(context: ExtensionContext): void {
  runtimeRoot = path.join(context.globalStorageUri.fsPath, "runtime");
  devGemPath =
    context.extensionMode === ExtensionMode.Production
      ? undefined
      : process.env[DEV_GEM_PATH_ENV] || undefined;
}

/**
 * The managed server to spawn, or undefined when nothing usable is
 * installed. `rigor.runtime.version` set to a version selects exactly
 * that one; `latest` selects the newest installed.
 */
export function managedServer(): ResolvedServer | undefined {
  const requested = requestedVersion();
  const installed = installedVersions();
  const pick =
    requested === "latest"
      ? installed[0]
      : installed.find((m) => m.version === requested);
  if (!pick || !runtimeRoot) {
    return undefined;
  }
  const dir = path.join(runtimeRoot, pick.version);
  return {
    kind: "managed",
    runtimeDir: dir,
    command: pick.ruby,
    prefixArgs: [pick.bundler, "exec", "rigor"],
    env: bundleEnv(dir, true),
    // An absolute `ruby` executable needs no shell on any platform, and a
    // shell would split a storage path that contains a space.
    shell: false,
  };
}

/** Valid installs, newest first. */
function installedVersions(): Manifest[] {
  if (!runtimeRoot || !fs.existsSync(runtimeRoot)) {
    return [];
  }
  const manifests: Manifest[] = [];
  for (const name of fs.readdirSync(runtimeRoot)) {
    if (name.startsWith(".")) {
      continue;
    }
    const manifest = readManifest(path.join(runtimeRoot, name));
    if (
      manifest &&
      manifest.version === name &&
      fs.existsSync(manifest.ruby) &&
      fs.existsSync(manifest.bundler)
    ) {
      manifests.push(manifest);
    }
  }
  return manifests.sort((a, b) => compareVersions(b.version, a.version));
}

function readManifest(dir: string): Manifest | undefined {
  try {
    return JSON.parse(
      fs.readFileSync(path.join(dir, MANIFEST), "utf8"),
    ) as Manifest;
  } catch {
    return undefined;
  }
}

/** `dev` sorts above every release: it is what a developer just built. */
function compareVersions(a: string, b: string): number {
  if (a === b) {
    return 0;
  }
  if (a === DEV_VERSION) {
    return 1;
  }
  if (b === DEV_VERSION) {
    return -1;
  }
  const pa = a.split(/[.-]/).map((n) => parseInt(n, 10) || 0);
  const pb = b.split(/[.-]/).map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const diff = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (diff !== 0) {
      return diff;
    }
  }
  return 0;
}

function requestedVersion(): string {
  if (devGemPath) {
    return DEV_VERSION;
  }
  const value = (
    workspace.getConfiguration("rigor").get<string>("runtime.version") ?? ""
  ).trim();
  return value === "" ? "latest" : value;
}

// ---------------------------------------------------------------------------
// Environment

/**
 * The extension host's environment without anything that redirects Ruby,
 * RubyGems or Bundler: every `BUNDLE_*` / `BUNDLER_*` variable except
 * `BUNDLE_MIRROR__*` (a mirror the user configured stays usable),
 * `GEM_HOME`, `GEM_PATH`, `RUBYOPT` and `RUBYLIB`. Used for every Ruby,
 * Bundler and mise process the extension starts for the managed Rigor.
 */
function cleanEnv(): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const [key, value] of Object.entries(process.env)) {
    const bundler =
      (key.startsWith("BUNDLE_") || key.startsWith("BUNDLER_")) &&
      !key.startsWith("BUNDLE_MIRROR__");
    if (bundler || ["GEM_HOME", "GEM_PATH", "RUBYOPT", "RUBYLIB"].includes(key)) {
      continue;
    }
    env[key] = value;
  }
  return env;
}

/**
 * The environment for `bundle install` / `bundle exec` in `dir`: the clean
 * environment, with Bundler's settings set explicitly and its config
 * files (the user's and the project's) ignored.
 */
function bundleEnv(dir: string, frozen: boolean): NodeJS.ProcessEnv {
  const env = cleanEnv();
  env.BUNDLE_GEMFILE = path.join(dir, "Gemfile");
  env.BUNDLE_PATH = path.join(dir, "bundle");
  env.BUNDLE_IGNORE_CONFIG = "1";
  if (frozen) {
    env.BUNDLE_FROZEN = "true";
  } else {
    // rigortype's post-install message is advice for a command-line
    // install; the extension manages this one.
    env.BUNDLE_IGNORE_MESSAGES = "true";
  }
  return env;
}

// ---------------------------------------------------------------------------
// Ruby 4.0 detection

const RUBY_PROBE = [
  `req = Gem::Requirement.new(${REQUIRED_RUBY.map((r) => JSON.stringify(r)).join(", ")})`,
  'print RUBY_VERSION, "\\n", req.satisfied_by?(Gem.ruby_version), "\\n", RbConfig.ruby, "\\n", (Gem.bin_path("bundler", "bundle") rescue "")',
].join("; ");

/** The first Ruby 4.0 that also carries Bundler, or undefined. */
async function findRuby(
  output: OutputChannel,
): Promise<RubyCandidate | undefined> {
  const configured = (
    workspace.getConfiguration("rigor").get<string>("runtime.rubyPath") ?? ""
  ).trim();
  if (configured) {
    const found = await probeRuby(configured, output);
    if (found) {
      return found;
    }
    void window.showWarningMessage(
      `Rigor: "rigor.runtime.rubyPath" is "${configured}", which is not a ` +
        `Ruby satisfying ${REQUIRED_RUBY.join(", ")} with Bundler. Looking for another.`,
    );
  }
  const candidates = rubyCandidates();
  for (const candidate of candidates) {
    const found = await probeRuby(candidate, output);
    if (found) {
      return found;
    }
  }
  output.appendLine(
    `[rigor] no Ruby ${REQUIRED_RUBY.join(", ")} with Bundler among: ${candidates.join(", ")}`,
  );
  return undefined;
}

/**
 * `ruby` on PATH, then the version managers' install directories, newest
 * first. mise's own `mise where` is not run: a `mise` command can run the
 * user's configured auto-prune, which uninstalls tools, so its install
 * directory is read instead.
 */
function rubyCandidates(): string[] {
  const exe = process.platform === "win32" ? "ruby.exe" : "ruby";
  const candidates = ["ruby"];
  const home = os.homedir();
  const versionDirs: [string, string][] = [
    [path.join(miseDataDir(), "installs", "ruby"), "4."],
    [path.join(home, ".rbenv", "versions"), "4."],
    [path.join(home, ".rubies"), "ruby-4."],
    ["/opt/rubies", "ruby-4."],
    [
      path.join(process.env.ASDF_DATA_DIR ?? path.join(home, ".asdf"), "installs", "ruby"),
      "4.",
    ],
  ];
  for (const [dir, prefix] of versionDirs) {
    let names: string[] = [];
    try {
      names = fs.readdirSync(dir).filter((n) => n.startsWith(prefix));
    } catch {
      continue;
    }
    names.sort((a, b) =>
      compareVersions(b.replace(/^ruby-/, ""), a.replace(/^ruby-/, "")),
    );
    for (const name of names) {
      candidates.push(path.join(dir, name, "bin", exe));
    }
  }
  return candidates;
}

/** Ask the candidate itself: its version, its real path, its Bundler. */
async function probeRuby(
  candidate: string,
  output: OutputChannel,
): Promise<RubyCandidate | undefined> {
  // From the home directory, so a version-manager shim on PATH answers
  // with the user's default Ruby rather than the project's.
  const out = await run(candidate, ["-e", RUBY_PROBE], 15000, os.homedir());
  if (out === undefined) {
    return undefined;
  }
  const [version, satisfied, ruby, bundler] = out.split("\n");
  if (satisfied !== "true" || !ruby || !bundler) {
    output.appendLine(
      `[rigor] ${candidate}: Ruby ${version ?? "?"}${satisfied === "true" ? " without Bundler" : ""} does not qualify`,
    );
    return undefined;
  }
  return { version, ruby, bundler };
}

function miseDataDir(): string {
  if (process.env.MISE_DATA_DIR) {
    return process.env.MISE_DATA_DIR;
  }
  if (process.env.XDG_DATA_HOME) {
    return path.join(process.env.XDG_DATA_HOME, "mise");
  }
  return path.join(os.homedir(), ".local", "share", "mise");
}

/** The mise executable. On Windows only `mise.exe`, which runs without a shell. */
function findMise(): string | undefined {
  const sep = process.platform === "win32" ? ";" : ":";
  const name = process.platform === "win32" ? "mise.exe" : "mise";
  const dirs = [
    ...(process.env.PATH ?? "").split(sep),
    path.join(os.homedir(), ".local", "bin"),
    "/opt/homebrew/bin",
    "/usr/local/bin",
  ];
  for (const dir of dirs) {
    const candidate = dir && path.join(dir, name);
    if (candidate && fs.existsSync(candidate)) {
      return candidate;
    }
  }
  return undefined;
}

/** stdout of a short command, or undefined when it fails. */
function run(
  command: string,
  args: string[],
  timeout: number,
  cwd?: string,
): Promise<string | undefined> {
  return new Promise((resolve) => {
    execFile(
      command,
      args,
      { cwd, timeout, windowsHide: true, env: cleanEnv() },
      (error, stdout) => resolve(error ? undefined : stdout),
    );
  });
}

// ---------------------------------------------------------------------------
// The shared storage: lock, in-use markers, pruning

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === "EPERM";
  }
}

/**
 * Run `task` holding `runtime/.lock`. Resolves undefined, after telling
 * the user, when another window holds it.
 */
async function withLock<T>(task: () => Promise<T>): Promise<T | undefined> {
  const root = runtimeRoot;
  if (!root) {
    return undefined;
  }
  fs.mkdirSync(root, { recursive: true });
  const lock = path.join(root, LOCK);
  const token = `${process.pid}-${Math.random().toString(36).slice(2)}`;
  const write = (flag: string): void =>
    fs.writeFileSync(
      lock,
      JSON.stringify({ pid: process.pid, token, at: Date.now() }),
      { flag },
    );
  let held = false;
  for (let attempt = 0; attempt < 2 && !held; attempt++) {
    try {
      write("wx");
      // Two windows that both judged the old lock stale may both have
      // removed it; only the one whose token is in the file owns it.
      held = readLock(lock)?.token === token;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "EEXIST") {
        throw err;
      }
      if (attempt === 0 && lockIsStale(lock)) {
        fs.rmSync(lock, { force: true });
      }
    }
  }
  if (!held) {
    void window.showWarningMessage(
      "Rigor: another VS Code window is installing or clearing the managed " +
        "Rigor. Try again when it has finished.",
    );
    return undefined;
  }
  const heartbeat = setInterval(() => {
    if (readLock(lock)?.token === token) {
      write("w");
    }
  }, LOCK_HEARTBEAT_MS);
  try {
    return await task();
  } finally {
    clearInterval(heartbeat);
    if (readLock(lock)?.token === token) {
      fs.rmSync(lock, { force: true });
    }
  }
}

interface LockContents {
  pid?: number;
  token?: string;
  at?: number;
}

function readLock(lock: string): LockContents | undefined {
  try {
    return JSON.parse(fs.readFileSync(lock, "utf8")) as LockContents;
  } catch {
    return undefined;
  }
}

/** Stale: its process is gone, or its heartbeat stopped. */
function lockIsStale(lock: string): boolean {
  const contents = readLock(lock);
  if (contents && typeof contents.pid === "number" && typeof contents.at === "number") {
    return !pidAlive(contents.pid) || Date.now() - contents.at > LOCK_STALE_MS;
  }
  // Unreadable or half-written: judge by the file's age alone.
  try {
    return Date.now() - fs.statSync(lock).mtimeMs > LOCK_STALE_MS;
  } catch {
    return true;
  }
}

/**
 * Record which version `key`'s managed server runs from (`undefined` when
 * it stops or runs something else), and bring this window's markers in
 * line: a marker per version in use, none for a version no longer used.
 */
export function setInUse(key: string, server: ResolvedServer | undefined): void {
  const before = new Set(inUse.values());
  if (server?.kind === "managed" && server.runtimeDir) {
    inUse.set(key, server.runtimeDir);
  } else {
    inUse.delete(key);
  }
  const after = new Set(inUse.values());
  for (const dir of before) {
    if (!after.has(dir)) {
      fs.rmSync(markerPath(dir), { force: true });
    }
  }
  touchMarkers();
  if (after.size > 0 && !markerTimer) {
    markerTimer = setInterval(touchMarkers, MARKER_TOUCH_MS);
    markerTimer.unref?.();
  } else if (after.size === 0 && markerTimer) {
    clearInterval(markerTimer);
    markerTimer = undefined;
  }
}

/** On deactivate: drop this window's markers and kill a running install. */
export function disposeRuntime(): void {
  for (const key of [...inUse.keys()]) {
    setInUse(key, undefined);
  }
  if (activeChild && activeChild.exitCode === null) {
    killTree(activeChild);
  }
}

function markerPath(dir: string, pid = process.pid): string {
  return path.join(dir, IN_USE, String(pid));
}

function touchMarkers(): void {
  for (const dir of new Set(inUse.values())) {
    try {
      fs.mkdirSync(path.join(dir, IN_USE), { recursive: true });
      fs.writeFileSync(markerPath(dir), "");
    } catch {
      // A marker that cannot be written only makes pruning less careful.
    }
  }
}

/**
 * Pids of the live windows, other than this one unless `includeSelf`,
 * that mark `dir` in use. A marker untouched for MARKER_STALE_MS is a
 * window that died without removing it, whatever its pid now names.
 */
function liveMarkers(dir: string, includeSelf: boolean): number[] {
  let names: string[];
  try {
    names = fs.readdirSync(path.join(dir, IN_USE));
  } catch {
    return [];
  }
  return names
    .map((name) => parseInt(name, 10))
    .filter((pid) => {
      if (!(pid > 0) || (pid === process.pid && !includeSelf)) {
        return false;
      }
      try {
        const age = Date.now() - fs.statSync(markerPath(dir, pid)).mtimeMs;
        return age < MARKER_STALE_MS && pidAlive(pid);
      } catch {
        return false;
      }
    });
}

/**
 * Under the lock: remove leftovers of installs that died (only the lock
 * holder creates them), and the versions beyond the newest KEEP_VERSIONS
 * that no live window (this one included) uses. A directory without a manifest that is not a
 * leftover is not ours to judge and stays.
 */
function prune(keep: string): void {
  const root = runtimeRoot;
  if (!root) {
    return;
  }
  for (const name of fs.readdirSync(root)) {
    if (name.startsWith(".tmp-") || name.startsWith(".old-")) {
      fs.rmSync(path.join(root, name), { recursive: true, force: true });
    }
  }
  const others = installedVersions()
    .map((m) => m.version)
    .filter((v) => v !== keep);
  for (const version of others.slice(KEEP_VERSIONS - 1)) {
    const dir = path.join(root, version);
    if (liveMarkers(dir, true).length === 0) {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }
}

// ---------------------------------------------------------------------------
// Installing

export interface InstallOptions {
  /** Reinstall the version even when it is installed: its probe failed. */
  repair?: boolean;
}

/**
 * Install the managed Rigor (tiers A–C). Resolves true when a usable
 * version is installed afterwards. Concurrent calls share one install.
 */
export function installManaged(
  output: OutputChannel,
  options: InstallOptions = {},
): Promise<boolean> {
  if (!workspace.isTrusted) {
    void window.showWarningMessage(
      "Rigor: the managed Rigor is not installed in an untrusted workspace. " +
        "Trust the workspace first.",
    );
    return Promise.resolve(false);
  }
  installing ??= installNow(output, options)
    .catch((err) => {
      output.appendLine(`[rigor] the managed install failed: ${String(err)}`);
      void window.showErrorMessage(
        `Rigor: installing the managed Rigor failed: ${String(err)}`,
      );
      return false;
    })
    .finally(() => {
      installing = undefined;
    });
  return installing;
}

async function installNow(
  output: OutputChannel,
  options: InstallOptions,
): Promise<boolean> {
  if (!runtimeRoot) {
    return false;
  }
  let ruby = await findRuby(output);
  if (!ruby) {
    ruby = await offerMiseRuby(output);
    if (!ruby) {
      return false;
    }
  }

  let version: string;
  try {
    version = await targetVersion();
  } catch (err) {
    void window.showErrorMessage(
      `Rigor: could not find the rigortype version to install: ${String(err)}`,
    );
    return false;
  }
  const present = installedVersions().some((m) => m.version === version);
  if (present && !options.repair && version !== DEV_VERSION) {
    void window.showInformationMessage(
      `Rigor: rigortype ${version} is already installed for this editor.`,
    );
    return true;
  }
  const found = ruby;
  const result = await withLock(() => installVersion(output, found, version));
  return result === true;
}

async function installVersion(
  output: OutputChannel,
  ruby: RubyCandidate,
  version: string,
): Promise<boolean> {
  const root = runtimeRoot;
  if (!root) {
    return false;
  }
  const dir = path.join(root, version);
  const staging = path.join(
    root,
    `.tmp-${version}-${process.pid}-${Date.now().toString(36)}`,
  );
  output.appendLine(
    `[rigor] installing rigortype ${version} with Ruby ${ruby.version} (${ruby.ruby}) into ${dir}`,
  );
  let ok = false;
  let busy = false;
  try {
    ok = await window.withProgress(
      {
        location: ProgressLocation.Notification,
        title: `Rigor: installing rigortype ${version}`,
        cancellable: true,
      },
      (progress, token) =>
        buildInto(staging, output, ruby, version, progress, token),
    );
    if (ok && liveMarkers(dir, false).length > 0) {
      ok = false;
      busy = true;
    } else if (ok) {
      replaceDir(staging, dir);
    }
  } catch (err) {
    ok = false;
    output.appendLine(`[rigor] the install failed: ${String(err)}`);
  } finally {
    fs.rmSync(staging, { recursive: true, force: true });
  }
  if (busy) {
    void window.showWarningMessage(
      `Rigor: another VS Code window is running rigortype ${version} from ` +
        "the managed install, so it was not replaced. Close or reload that " +
        "window, then try again.",
    );
    return false;
  }
  if (!ok) {
    const show = "Show Output";
    const guide = "Installation guide";
    void window
      .showErrorMessage(
        `Rigor: installing rigortype ${version} failed. The Bundler output is in the Rigor output channel.`,
        show,
        guide,
      )
      .then((choice) => {
        if (choice === show) {
          output.show();
        } else if (choice === guide) {
          void commands.executeCommand("vscode.open", Uri.parse(INSTALL_GUIDE_URL));
        }
      });
    return false;
  }
  output.appendLine(`[rigor] installed rigortype ${version} into ${dir}`);
  prune(version);
  return true;
}

/** `bundle install`, checked with `rigor version`, manifest written last. */
async function buildInto(
  staging: string,
  output: OutputChannel,
  ruby: RubyCandidate,
  version: string,
  progress: { report(value: { message?: string }): void },
  token: CancellationToken,
): Promise<boolean> {
  fs.mkdirSync(staging, { recursive: true });
  const gem = devGemPath
    ? `gem 'rigortype', path: ${rubyString(devGemPath)}`
    : `gem 'rigortype', ${rubyString(`= ${version}`)}`;
  fs.writeFileSync(
    path.join(staging, "Gemfile"),
    `source 'https://rubygems.org'\n${gem}\n`,
  );
  progress.report({ message: "bundle install" });
  const installed = await stream(
    output,
    ruby.ruby,
    [ruby.bundler, "install"],
    staging,
    bundleEnv(staging, false),
    token,
  );
  if (!installed) {
    return false;
  }
  progress.report({ message: "checking `rigor version`" });
  const printed = await new Promise<string | undefined>((resolve) => {
    execFile(
      ruby.ruby,
      [ruby.bundler, "exec", "rigor", "version"],
      { cwd: staging, env: bundleEnv(staging, true), timeout: 60000, windowsHide: true },
      (error, stdout) => resolve(error ? undefined : stdout),
    );
  });
  const rigortype = printed && /\b(\d+\.\d+\.\d+)\b/.exec(printed)?.[1];
  if (!rigortype) {
    output.appendLine("[rigor] the installed `rigor version` did not run");
    return false;
  }
  const manifest: Manifest = {
    version,
    rigortype,
    ruby: ruby.ruby,
    bundler: ruby.bundler,
  };
  fs.writeFileSync(
    path.join(staging, MANIFEST),
    `${JSON.stringify(manifest, null, 2)}\n`,
  );
  return true;
}

/**
 * Rename `staging` to `dir`. An existing `dir` (a repair or a `dev`
 * reinstall, which the caller checked no other live window runs) is
 * renamed aside first and then deleted, so the swap is two renames.
 */
function replaceDir(staging: string, dir: string): void {
  if (fs.existsSync(dir)) {
    const aside = path.join(
      path.dirname(dir),
      `.old-${path.basename(dir)}-${process.pid}-${Date.now().toString(36)}`,
    );
    fs.renameSync(dir, aside);
    fs.renameSync(staging, dir);
    fs.rmSync(aside, { recursive: true, force: true });
    return;
  }
  fs.renameSync(staging, dir);
}

/** A single-quoted Ruby string literal: no `#{}` interpolation. */
function rubyString(value: string): string {
  return `'${value.replace(/\\/g, "\\\\").replace(/'/g, "\\'")}'`;
}

/** `rigor.runtime.version`, with `latest` resolved from rubygems.org. */
async function targetVersion(): Promise<string> {
  const requested = requestedVersion();
  if (requested !== "latest") {
    if (
      requested !== DEV_VERSION &&
      !/^\d+\.\d+\.\d+([.-][0-9A-Za-z.]+)?$/.test(requested)
    ) {
      throw new Error(`"rigor.runtime.version" is "${requested}", which is not a version`);
    }
    return requested;
  }
  return latestVersion();
}

function latestVersion(): Promise<string> {
  return new Promise((resolve, reject) => {
    const request = https.get(LATEST_URL, { timeout: 15000 }, (response) => {
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error(`${LATEST_URL} answered ${response.statusCode}`));
        return;
      }
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk: string) => (body += chunk));
      response.on("end", () => {
        try {
          const version = (JSON.parse(body) as { version?: unknown }).version;
          if (typeof version === "string" && /^\d+\.\d+\.\d+$/.test(version)) {
            resolve(version);
          } else {
            reject(new Error(`${LATEST_URL} named no release version`));
          }
        } catch (err) {
          reject(err as Error);
        }
      });
    });
    request.on("timeout", () => request.destroy(new Error("timed out")));
    request.on("error", reject);
  });
}

/**
 * Run a command, streaming its output to the channel. True on exit 0.
 * Cancelling kills the whole tree (`bundle install` runs compilers).
 */
function stream(
  output: OutputChannel,
  command: string,
  args: string[],
  cwd: string,
  env: NodeJS.ProcessEnv,
  token: CancellationToken,
): Promise<boolean> {
  output.appendLine(`[rigor] $ ${[command, ...args].join(" ")}`);
  return new Promise((resolve) => {
    let child: ChildProcess;
    try {
      child = spawn(command, args, {
        cwd,
        env,
        windowsHide: true,
        detached: process.platform !== "win32",
      });
    } catch (err) {
      output.appendLine(`[rigor] could not run ${command}: ${String(err)}`);
      resolve(false);
      return;
    }
    activeChild = child;
    const cancel = token.onCancellationRequested(() => {
      output.appendLine("[rigor] cancelled");
      killTree(child);
    });
    child.stdout?.on("data", (data: Buffer) => output.append(data.toString()));
    child.stderr?.on("data", (data: Buffer) => output.append(data.toString()));
    child.on("error", (err) => {
      output.appendLine(`[rigor] could not run ${command}: ${String(err)}`);
    });
    child.on("close", (code) => {
      cancel.dispose();
      if (activeChild === child) {
        activeChild = undefined;
      }
      resolve(code === 0 && !token.isCancellationRequested);
    });
  });
}

// ---------------------------------------------------------------------------
// Tiers B and C

/** Tier B when mise exists; otherwise tier C. Returns the new Ruby, if any. */
async function offerMiseRuby(
  output: OutputChannel,
): Promise<RubyCandidate | undefined> {
  const mise = findMise();
  if (!mise) {
    showNoRuby();
    return undefined;
  }
  const install = "Install Ruby 4.0 with mise";
  const guide = "Installation guide";
  const choice = await window.showInformationMessage(
    "Rigor needs Ruby 4.0, and none was found. Run `mise install ruby@4.0`? " +
      "mise installs Ruby into its own store, and no file in this project " +
      "changes, but mise applies your own mise settings while it runs (an " +
      "auto-prune, for example, may uninstall tool versions it considers unused).",
    install,
    guide,
  );
  if (choice === guide) {
    void commands.executeCommand("vscode.open", Uri.parse(INSTALL_GUIDE_URL));
    return undefined;
  }
  if (choice !== install) {
    return undefined;
  }
  const ok = await window.withProgress(
    {
      location: ProgressLocation.Notification,
      title: "Rigor: mise install ruby@4.0",
      cancellable: true,
    },
    (_progress, token) =>
      stream(output, mise, ["install", "ruby@4.0"], os.homedir(), cleanEnv(), token),
  );
  const ruby = ok ? await findRuby(output) : undefined;
  if (!ruby) {
    void window.showErrorMessage(
      "Rigor: `mise install ruby@4.0` did not leave a usable Ruby 4.0. " +
        "The output is in the Rigor output channel.",
    );
  }
  return ruby;
}

/** Tier C: no Ruby 4.0 and no mise to provide one. */
function showNoRuby(): void {
  const guide = "Installation guide";
  const binary = "Single-binary issue (#926)";
  void window
    .showErrorMessage(
      "Rigor needs Ruby 4.0, and neither a Ruby 4.0 nor mise was found to " +
        "install it with. The installation guide covers the ways to get one; " +
        "a self-contained Rigor that needs no Ruby is tracked in #926.",
      guide,
      binary,
    )
    .then((choice) => {
      if (choice === guide) {
        void commands.executeCommand("vscode.open", Uri.parse(INSTALL_GUIDE_URL));
      } else if (choice === binary) {
        void commands.executeCommand("vscode.open", Uri.parse(SINGLE_BINARY_URL));
      }
    });
}

// ---------------------------------------------------------------------------
// A project with no Rigor config

/**
 * After an install that started no server because no folder has a Rigor
 * config: say so, and offer `rigor init` (run with the managed Rigor) in
 * one of `folders`.
 */
export async function offerInit(
  folders: readonly WorkspaceFolder[],
  output: OutputChannel,
  restart: () => Promise<void>,
): Promise<void> {
  const server = managedServer();
  const enabled = folders.filter((folder) =>
    workspace.getConfiguration("rigor", folder.uri).get<boolean>("enable", true),
  );
  if (enabled.length === 0) {
    return;
  }
  const create = "Create .rigor.yml";
  const guide = "Configuration guide";
  const choice = await window.showInformationMessage(
    "Rigor is installed, but no workspace folder has a .rigor.yml, so no " +
      "server started. Create one with `rigor init`?",
    ...(server ? [create] : []),
    guide,
  );
  if (choice === guide) {
    void commands.executeCommand("vscode.open", Uri.parse(CONFIG_GUIDE_URL));
    return;
  }
  if (choice !== create || !server) {
    return;
  }
  const folder =
    enabled.length === 1
      ? enabled[0]
      : await window.showWorkspaceFolderPick({
          placeHolder: "Create .rigor.yml in which folder?",
        });
  if (!folder) {
    return;
  }
  const ok = await new Promise<boolean>((resolve) => {
    execFile(
      server.command,
      [...server.prefixArgs, "init"],
      { cwd: folder.uri.fsPath, env: server.env, timeout: 60000, windowsHide: true },
      (error, stdout, stderr) => {
        output.append(stdout);
        output.append(stderr);
        resolve(!error);
      },
    );
  });
  if (!ok) {
    void window.showErrorMessage(
      "Rigor: `rigor init` failed. The output is in the Rigor output channel.",
    );
    return;
  }
  await restart();
}

// ---------------------------------------------------------------------------
// Commands

export function registerRuntimeCommands(
  context: ExtensionContext,
  output: OutputChannel,
  afterInstall: () => Promise<void>,
  whileStopped: (task: () => Promise<void>) => Promise<void>,
): void {
  context.subscriptions.push(
    commands.registerCommand("rigor.installManagedRuntime", async () => {
      if (await installManaged(output)) {
        await afterInstall();
      }
    }),
    commands.registerCommand("rigor.checkForUpdate", () =>
      checkForUpdate(output),
    ),
    commands.registerCommand("rigor.clearManagedRuntime", () =>
      clearManaged(output, whileStopped),
    ),
  );
}

async function checkForUpdate(output: OutputChannel): Promise<void> {
  const installed = installedVersions();
  const requested = requestedVersion();
  if (requested === DEV_VERSION) {
    void window.showInformationMessage(
      "Rigor: the managed Rigor is a development install from a local " +
        `checkout (${DEV_GEM_PATH_ENV}); it is not updated from rubygems.org.`,
    );
    return;
  }
  if (requested !== "latest") {
    void window.showInformationMessage(
      `Rigor: "rigor.runtime.version" pins the managed Rigor to ${requested}; ` +
        "set it to latest to follow new releases.",
    );
    return;
  }
  let latest: string;
  try {
    latest = await latestVersion();
  } catch (err) {
    void window.showErrorMessage(
      `Rigor: could not check rubygems.org for an update: ${String(err)}`,
    );
    return;
  }
  const current = installed[0]?.version;
  // Only the managed Rigor is updated here; a `rigor` found earlier in
  // discovery (PATH, a shim, Bundler) is the user's and is never touched.
  const scope =
    "The managed Rigor is used only for a project with no other rigor.";
  if (current && compareVersions(current, latest) >= 0) {
    void window.showInformationMessage(
      `Rigor: the managed rigortype ${current} is the latest release. ${scope}`,
    );
    return;
  }
  const install = `Install ${latest}`;
  const choice = await window.showInformationMessage(
    (current
      ? `Rigor: rigortype ${latest} is available (the managed install is ${current}).`
      : `Rigor: no managed Rigor is installed; the latest release is ${latest}.`) +
      ` ${scope}`,
    install,
  );
  if (choice !== install || !(await installManaged(output))) {
    return;
  }
  const restartNow = "Restart Server";
  const after = await window.showInformationMessage(
    `Rigor: rigortype ${latest} is installed and takes effect when the server restarts.`,
    restartNow,
  );
  if (after === restartNow) {
    await commands.executeCommand("rigor.restartServer");
  }
}

async function clearManaged(
  output: OutputChannel,
  whileStopped: (task: () => Promise<void>) => Promise<void>,
): Promise<void> {
  const root = runtimeRoot;
  const versions = installedVersions().map((m) => m.version);
  if (!root || !fs.existsSync(root)) {
    void window.showInformationMessage("Rigor: no managed Rigor is installed.");
    return;
  }
  const clear = "Delete";
  const choice = await window.showWarningMessage(
    `Rigor: delete the managed Rigor (${versions.join(", ") || "no complete version"}) ` +
      "from the editor's storage? This window's servers using it stop. Servers " +
      "in other VS Code windows keep running from the deleted files and fail " +
      "until those windows restart them.",
    { modal: true },
    clear,
  );
  if (choice !== clear) {
    return;
  }
  const failed: string[] = [];
  await whileStopped(async () => {
    await withLock(async () => {
      for (const name of fs.readdirSync(root)) {
        if (name === LOCK) {
          continue;
        }
        try {
          fs.rmSync(path.join(root, name), { recursive: true, force: true });
        } catch (err) {
          failed.push(name);
          output.appendLine(`[rigor] could not delete ${name}: ${String(err)}`);
        }
      }
      output.appendLine(`[rigor] cleared the managed Rigor in ${root}`);
    });
  });
  if (failed.length > 0) {
    void window.showErrorMessage(
      `Rigor: could not delete ${failed.join(", ")} from ${root}. ` +
        "The Rigor output channel has the errors.",
    );
  }
}
