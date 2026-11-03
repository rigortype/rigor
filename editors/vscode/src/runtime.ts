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
//   of wall-clock time while held (and at once after the machine wakes)
//   through a descriptor whose contents carry the owner's token, and
//   removed only by its owner. A lock whose process is gone, or whose
//   heartbeat stopped LOCK_STALE_MS ago, is stale.
// - An install builds in `runtime/.tmp-*` and renames the finished
//   directory, manifest included, into place, so another window never
//   sees a half-installed version.
// - A window running a managed server leaves a marker named by its
//   extension host's pid in `<version>/.in-use/`, touched hourly (and
//   after a wake) and removed when it stops using the version. Pruning
//   skips a version with a live marker (this window's included); a repair
//   does not replace a version another window, or another folder of this
//   one, runs, and checks that before it builds. Only Clear deletes a
//   version in use, and says so.

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
 * `rigortype.gemspec`'s `required_ruby_version`, copied by hand;
 * `spec/docs/vscode_required_ruby_sync_spec.rb` fails when they differ,
 * and reads this line, so keep it one array of string literals.
 * The candidate Ruby checks `Gem.ruby_version` against it, which carries
 * a prerelease marker (`4.0.0.preview2`), so RubyGems' own rules decide;
 * `findRuby` then skips a prerelease, which `< 4.1` admits.
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
 * How often the lock and marker timers wake to read the wall clock. A
 * timer runs on the monotonic clock, which on macOS stops while the
 * machine sleeps; the wall clock does not, so after a wake the lock or a
 * marker can look stale to another window until it is refreshed. Each
 * probe refreshes when the wall clock says the interval is up, or when
 * it jumped (a wake), so a refresh follows a wake within this time.
 */
const WAKE_PROBE_MS = 10 * 1000;
/** A probe this much later on the wall clock than scheduled was a sleep. */
const DRIFT_SLACK_MS = 5 * 1000;
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

/** What a candidate Ruby answered, before it is accepted. */
export interface RubyProbe extends RubyCandidate {
  /** `Gem.ruby_version.prerelease?`: a preview, rc or dev build. */
  prerelease: boolean;
}

let runtimeRoot: string | undefined;
let devGemPath: string | undefined;
let installing: Promise<boolean> | undefined;
/**
 * The running `bundle install` / `mise install`. On deactivate a
 * `bundle install` is killed; a `mise install` is left to finish.
 */
let activeChild: ChildProcess | undefined;
/** Set while `activeChild` writes to a log file and outlives the window. */
let activeChildDetaches: { commandLine: string; logFile: string } | undefined;
/** Folder key → the version directory its managed server runs from. */
const inUse = new Map<string, string>();
let stopMarkerTimer: (() => void) | undefined;
/** The output channel, once the commands are registered. */
let runtimeOutput: OutputChannel | undefined;
let updateTimer: NodeJS.Timeout | undefined;
let updateChecking = false;
/** Wall-clock time of the last background update check. */
let lastUpdateCheck = 0;
/** Versions already announced this session: each is offered once. */
const updateOffered = new Set<string>();

function log(line: string): void {
  try {
    runtimeOutput?.appendLine(line);
  } catch {
    // The channel is disposed while the window closes.
  }
}

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
  'print RUBY_VERSION, "\\n", req.satisfied_by?(Gem.ruby_version), "\\n", RbConfig.ruby, "\\n", (Gem.bin_path("bundler", "bundle") rescue ""), "\\n", Gem.ruby_version.prerelease?',
].join("; ");

/**
 * The Ruby to install with, or undefined. `rigor.runtime.rubyPath` wins
 * when it qualifies, prerelease or not: naming one is a choice.
 * Otherwise every candidate is asked and the newest release that
 * qualifies is taken. A prerelease (`4.1.0.preview1`, `4.1.0.dev`)
 * satisfies the gemspec's `< 4.1` by RubyGems' rules, so it is skipped.
 */
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
  const probes: RubyProbe[] = [];
  for (const candidate of candidates) {
    const found = await probeRuby(candidate, output);
    if (found) {
      probes.push(found);
    }
  }
  for (const skipped of probes.filter((p) => p.prerelease)) {
    output.appendLine(
      `[rigor] ${skipped.ruby}: Ruby ${skipped.version} is a prerelease; ` +
        'name it in "rigor.runtime.rubyPath" to use it',
    );
  }
  const picked = pickRuby(probes);
  if (picked) {
    return picked;
  }
  output.appendLine(
    `[rigor] no Ruby ${REQUIRED_RUBY.join(", ")} with Bundler among: ${candidates.join(", ")}`,
  );
  return undefined;
}

/**
 * The newest release among the qualifying probes; on a tie the one asked
 * first (`ruby` on PATH comes first). A prerelease never qualifies here.
 */
export function pickRuby(probes: readonly RubyProbe[]): RubyProbe | undefined {
  let best: RubyProbe | undefined;
  for (const probe of probes) {
    if (probe.prerelease) {
      continue;
    }
    if (!best || compareVersions(probe.version, best.version) > 0) {
      best = probe;
    }
  }
  return best;
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
): Promise<RubyProbe | undefined> {
  // From the home directory, so a version-manager shim on PATH answers
  // with the user's default Ruby rather than the project's.
  const out = await run(candidate, ["-e", RUBY_PROBE], 15000, os.homedir());
  if (out === undefined) {
    return undefined;
  }
  const [version, satisfied, ruby, bundler, prerelease] = out.split("\n");
  if (satisfied !== "true" || !ruby || !bundler) {
    output.appendLine(
      `[rigor] ${candidate}: Ruby ${version ?? "?"}${satisfied === "true" ? " without Bundler" : ""} does not qualify`,
    );
    return undefined;
  }
  return { version, ruby, bundler, prerelease: prerelease === "true" };
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
  let held = false;
  for (let attempt = 0; attempt < 2 && !held; attempt++) {
    try {
      fs.writeFileSync(lock, lockBody(token), { flag: "wx" });
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
  const stopHeartbeat = wallClockTimer(LOCK_HEARTBEAT_MS, () =>
    withOwnedLock(lock, token, (fd) => {
      const body = Buffer.from(lockBody(token));
      fs.writeSync(fd, body, 0, body.length, 0);
      fs.ftruncateSync(fd, body.length);
    }),
  );
  try {
    return await task();
  } finally {
    stopHeartbeat();
    withOwnedLock(lock, token, (fd) => {
      // Unlink only the file the token was read from: a lock another
      // window created after judging this one stale stays.
      if (fs.statSync(lock).ino === fs.fstatSync(fd).ino) {
        fs.rmSync(lock, { force: true });
      }
    });
  }
}

function lockBody(token: string): string {
  return JSON.stringify({ pid: process.pid, token, at: Date.now() });
}

/**
 * Run `action` on an open descriptor of the lock file when the contents
 * read through it carry `token`. Reading and writing the same descriptor
 * means a window that judged the lock stale, removed it and created its
 * own (a new file) is never overwritten: a write after that lands in the
 * unlinked file. The residue is the steal itself, which can happen only
 * when the heartbeat is older than LOCK_STALE_MS (see `wallClockTimer`).
 */
function withOwnedLock(
  lock: string,
  token: string,
  action: (fd: number) => void,
): void {
  let fd: number;
  try {
    fd = fs.openSync(lock, "r+");
  } catch {
    return;
  }
  try {
    const contents = JSON.parse(fs.readFileSync(fd, "utf8")) as LockContents;
    if (contents.token === token) {
      action(fd);
    }
  } catch {
    // Unreadable, or gone meanwhile: not ours to touch.
  } finally {
    fs.closeSync(fd);
  }
}

/**
 * Whether a wall-clock timer probing at `now` should refresh: the
 * interval is up by the wall clock since `lastRefresh`, or the probe
 * came late (`lastTick` more than WAKE_PROBE_MS + DRIFT_SLACK_MS ago) or
 * before the previous one, so the machine slept or the clock was set.
 */
export function refreshDue(
  now: number,
  lastTick: number,
  lastRefresh: number,
  intervalMs: number,
): boolean {
  const sinceTick = now - lastTick;
  return (
    now - lastRefresh >= intervalMs ||
    sinceTick > WAKE_PROBE_MS + DRIFT_SLACK_MS ||
    sinceTick < 0
  );
}

/**
 * Call `refresh` every `intervalMs` of wall-clock time, and at once after
 * a wake. Returns the function that stops it. Unreferenced: it never
 * keeps the extension host alive.
 */
function wallClockTimer(intervalMs: number, refresh: () => void): () => void {
  let lastTick = Date.now();
  let lastRefresh = lastTick;
  const timer = setInterval(() => {
    const now = Date.now();
    if (refreshDue(now, lastTick, lastRefresh, intervalMs)) {
      lastRefresh = now;
      try {
        refresh();
      } catch {
        // A refresh that fails is retried on the next interval.
      }
    }
    lastTick = now;
  }, WAKE_PROBE_MS);
  timer.unref?.();
  return () => clearInterval(timer);
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
  if (after.size > 0 && !stopMarkerTimer) {
    stopMarkerTimer = wallClockTimer(MARKER_TOUCH_MS, touchMarkers);
  } else if (after.size === 0 && stopMarkerTimer) {
    stopMarkerTimer();
    stopMarkerTimer = undefined;
  }
  if (after.size > 0) {
    scheduleUpdateCheck(UPDATE_FIRST_CHECK_MS);
  }
}

/**
 * On deactivate: drop this window's markers and stop the update checks.
 * A running `bundle install` is killed (its staging directory is a
 * leftover the next install prunes). A running `mise install ruby@4.0`
 * is left to finish, detached, writing to its log file: killing it
 * mid-build leaves mise's own partial install for the user to clean up.
 */
export function disposeRuntime(): void {
  for (const key of [...inUse.keys()]) {
    setInUse(key, undefined);
  }
  if (updateTimer) {
    clearTimeout(updateTimer);
    updateTimer = undefined;
  }
  if (!activeChild || activeChild.exitCode !== null) {
    return;
  }
  if (activeChildDetaches) {
    log(
      `[rigor] left \`${activeChildDetaches.commandLine}\` running (pid ` +
        `${activeChild.pid ?? "?"}) as the window closed; its output goes to ` +
        activeChildDetaches.logFile,
    );
    activeChild.unref();
    return;
  }
  killTree(activeChild);
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
    // The log of a `mise install` a closed window left running, once that
    // window is gone (the install may outlive it; unlinking is harmless).
    const miseLog = /^\.mise-install-(\d+)\.log$/.exec(name);
    if (miseLog && !pidAlive(parseInt(miseLog[1], 10))) {
      fs.rmSync(path.join(root, name), { force: true });
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
  /** The version to install, already resolved (an update check). */
  version?: string;
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
    version = options.version ?? (await targetVersion());
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
  const repair = options.repair === true;
  const result = await withLock(() =>
    installVersion(output, found, version, repair),
  );
  return result === true;
}

/**
 * Who runs the version directory `dir`, so replacing it would pull the
 * files from under a live server: other windows' live markers, and for a
 * repair this window's other folders too (a dev reinstall in a window
 * that runs it is the developer's own call, and restarts after).
 */
function replaceBlocked(dir: string, repair: boolean): boolean {
  if (!fs.existsSync(dir)) {
    return false;
  }
  if (liveMarkers(dir, false).length > 0) {
    return true;
  }
  return repair && [...inUse.values()].includes(dir);
}

async function installVersion(
  output: OutputChannel,
  ruby: RubyCandidate,
  version: string,
  repair: boolean,
): Promise<boolean> {
  const root = runtimeRoot;
  if (!root) {
    return false;
  }
  const dir = path.join(root, version);
  if (replaceBlocked(dir, repair)) {
    showReplaceBlocked(version);
    return false;
  }
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
    // Again: a window may have started on the version during the build.
    if (ok && replaceBlocked(dir, repair)) {
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
    showReplaceBlocked(version);
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

function showReplaceBlocked(version: string): void {
  void window.showWarningMessage(
    `Rigor: rigortype ${version} from the managed install is running in ` +
      "another VS Code window or another folder of this one, so it was not " +
      "replaced. Close or reload that window (or stop that folder's " +
      "server), then try again.",
  );
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
 *
 * With `logFile`, the command's output goes to that file, which is
 * followed into the channel, instead of to a pipe: a pipe closes with
 * the extension host, and the next write would fail the command. Such a
 * command is not killed when the window closes (`disposeRuntime`).
 */
function stream(
  output: OutputChannel,
  command: string,
  args: string[],
  cwd: string,
  env: NodeJS.ProcessEnv,
  token: CancellationToken,
  logFile?: string,
): Promise<boolean> {
  const commandLine = [command, ...args].join(" ");
  output.appendLine(`[rigor] $ ${commandLine}`);
  return new Promise((resolve) => {
    let child: ChildProcess;
    let follow: { stop(): void } | undefined;
    try {
      if (logFile) {
        const fd = fs.openSync(logFile, "w");
        try {
          child = spawn(command, args, {
            cwd,
            env,
            windowsHide: true,
            detached: true,
            stdio: ["ignore", fd, fd],
          });
        } finally {
          fs.closeSync(fd);
        }
        follow = followFile(logFile, (text) => output.append(text));
      } else {
        child = spawn(command, args, {
          cwd,
          env,
          windowsHide: true,
          detached: process.platform !== "win32",
        });
      }
    } catch (err) {
      output.appendLine(`[rigor] could not run ${command}: ${String(err)}`);
      resolve(false);
      return;
    }
    activeChild = child;
    activeChildDetaches = logFile ? { commandLine, logFile } : undefined;
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
      follow?.stop();
      if (logFile) {
        fs.rmSync(logFile, { force: true });
      }
      if (activeChild === child) {
        activeChild = undefined;
        activeChildDetaches = undefined;
      }
      resolve(code === 0 && !token.isCancellationRequested);
    });
  });
}

/** Append what is written to `file` to `sink` until stopped, then drain. */
function followFile(file: string, sink: (text: string) => void): { stop(): void } {
  let position = 0;
  const drain = (): void => {
    let fd: number | undefined;
    try {
      fd = fs.openSync(file, "r");
      const buffer = Buffer.alloc(64 * 1024);
      let read: number;
      while ((read = fs.readSync(fd, buffer, 0, buffer.length, position)) > 0) {
        position += read;
        sink(buffer.toString("utf8", 0, read));
      }
    } catch {
      // The file went away (Clear Managed Rigor): nothing more to show.
    } finally {
      if (fd !== undefined) {
        fs.closeSync(fd);
      }
    }
  };
  const timer = setInterval(drain, 500);
  timer.unref?.();
  return {
    stop: () => {
      clearInterval(timer);
      drain();
    },
  };
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
      stream(
        output,
        mise,
        ["install", "ruby@4.0"],
        os.homedir(),
        cleanEnv(),
        token,
        miseLogFile(),
      ),
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

/**
 * Where `mise install ruby@4.0` writes its output: beside the versions,
 * but not a version directory (a dot name), and not a leftover prune
 * removes; Clear deletes it.
 */
function miseLogFile(): string {
  const dir = runtimeRoot ?? os.tmpdir();
  fs.mkdirSync(dir, { recursive: true });
  return path.join(dir, `.mise-install-${process.pid}.log`);
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
  runtimeOutput = output;
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
  if (choice !== install || !(await installManaged(output, { version: latest }))) {
    return;
  }
  await offerRestart(latest);
}

async function offerRestart(version: string): Promise<void> {
  const restartNow = "Restart Server";
  const after = await window.showInformationMessage(
    `Rigor: rigortype ${version} is installed and takes effect when the server restarts.`,
    restartNow,
  );
  if (after === restartNow) {
    await commands.executeCommand("rigor.restartServer");
  }
}

// ---------------------------------------------------------------------------
// Background update checks (#2746)

/** The first check after a managed server starts. */
const UPDATE_FIRST_CHECK_MS = 30 * 1000;
const HOUR_MS = 60 * 60 * 1000;

/**
 * `rigor.runtime.updateCheckIntervalHours`, clamped to 1–168: VS Code
 * enforces the schema's bounds only in the Settings UI.
 */
function updateIntervalMs(): number {
  const hours = workspace
    .getConfiguration("rigor")
    .get<number>("runtime.updateCheckIntervalHours", 24);
  const valid = typeof hours === "number" && Number.isFinite(hours) ? hours : 24;
  return Math.min(168, Math.max(1, valid)) * HOUR_MS;
}

/**
 * Whether a background check may run now: the workspace is trusted,
 * `rigor.runtime.autoUpdate` is on, `rigor.runtime.version` is `latest`
 * (not a pin, not a development install), and a folder of this window
 * runs the managed Rigor.
 */
function autoUpdateApplies(): boolean {
  return (
    workspace.isTrusted &&
    workspace.getConfiguration("rigor").get<boolean>("runtime.autoUpdate", true) &&
    requestedVersion() === "latest" &&
    inUse.size > 0
  );
}

/**
 * Arm the next check: `delayMs` from now, but never sooner than the
 * interval after the last check. A no-op while one is armed or running.
 * Called whenever a folder starts on the managed Rigor.
 */
function scheduleUpdateCheck(delayMs: number): void {
  if (updateTimer || updateChecking || !runtimeOutput) {
    return;
  }
  const notBefore = lastUpdateCheck === 0 ? 0 : lastUpdateCheck + updateIntervalMs();
  const delay = Math.max(delayMs, notBefore - Date.now());
  updateTimer = setTimeout(() => {
    updateTimer = undefined;
    void backgroundUpdateCheck();
  }, delay);
  updateTimer.unref?.();
}

async function backgroundUpdateCheck(): Promise<void> {
  const output = runtimeOutput;
  if (!output || !autoUpdateApplies()) {
    // Re-armed by the next managed start (setInUse).
    return;
  }
  updateChecking = true;
  lastUpdateCheck = Date.now();
  try {
    await checkInBackground(output);
  } finally {
    updateChecking = false;
    if (inUse.size > 0) {
      scheduleUpdateCheck(updateIntervalMs());
    }
  }
}

/**
 * One background check. A newer release is announced once per session
 * and installed only on "Install update"; it is used from the next
 * restart. A newer version another window already installed is offered
 * as a restart. A network failure logs one line and changes nothing.
 */
async function checkInBackground(output: OutputChannel): Promise<void> {
  let latest: string;
  try {
    latest = await latestVersion();
  } catch (err) {
    output.appendLine(`[rigor] the update check could not reach rubygems.org: ${String(err)}`);
    return;
  }
  const decision = updateDecision(
    latest,
    installedVersions().map((m) => m.version),
    [...new Set(inUse.values())].map((dir) => path.basename(dir)),
    updateOffered,
  );
  if (decision.kind === "none") {
    return;
  }
  updateOffered.add(decision.version);
  if (decision.kind === "restart") {
    await offerRestart(decision.version);
    return;
  }
  const install = "Install update";
  const choice = await window.showInformationMessage(
    `Rigor: rigortype ${decision.version} is available (the managed Rigor ` +
      `runs ${decision.current}). It installs beside the current version and ` +
      "is used from the next server restart.",
    install,
    "Later",
  );
  if (choice !== install || !autoUpdateApplies()) {
    return;
  }
  if (await installManaged(output, { version: decision.version })) {
    await offerRestart(decision.version);
  }
}

export type UpdateDecision =
  | { kind: "none" }
  | { kind: "install"; version: string; current: string }
  | { kind: "restart"; version: string };

/**
 * What a background check does with the `latest` release, given the
 * installed versions and those this window's servers run (both version
 * directory names): install it when nothing installed is that new,
 * offer a restart when it is installed (another window updated) but not
 * running, and nothing for a version already offered this session.
 */
export function updateDecision(
  latest: string,
  installed: readonly string[],
  running: readonly string[],
  offered: ReadonlySet<string>,
): UpdateDecision {
  if (offered.has(latest) || running.length === 0) {
    return { kind: "none" };
  }
  const newestRunning = [...running].sort((a, b) => compareVersions(b, a))[0];
  if (compareVersions(newestRunning, latest) >= 0) {
    return { kind: "none" };
  }
  if (installed.some((v) => compareVersions(v, latest) >= 0)) {
    return { kind: "restart", version: latest };
  }
  return { kind: "install", version: latest, current: newestRunning };
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
