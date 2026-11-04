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

export interface RubyCandidate {
  ruby: string;
  bundler: string;
  version: string;
  /** Named by `rigor.runtime.rubyPath`: never swapped for another. */
  explicit?: boolean;
}

/** What a candidate Ruby answered, before it is accepted. */
export interface RubyProbe extends RubyCandidate {
  /** `Gem.ruby_version.prerelease?`: a preview, rc or dev build. */
  prerelease: boolean;
  /** Whether `require "openssl"` worked. */
  openssl: boolean;
}

let runtimeRoot: string | undefined;
let devGemPath: string | undefined;
/**
 * The install in progress, keyed by what it was asked for: a second
 * request for the same thing shares it, one for something else waits for
 * it and then runs its own.
 */
let installing: { key: string; promise: Promise<InstallResult> } | undefined;
let installQueue: Promise<unknown> = Promise.resolve();
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
/**
 * Versions the user already answered this session ("Install update" or
 * a restart prompt): each is offered once. A "Later" is also persisted
 * in `globalState` (DECLINED_KEY), so no window asks again.
 */
const updateOffered = new Set<string>();
/** Versions whose restart offer the user answered this session. */
const restartOffered = new Set<string>();
/** The user's global extension state, shared by every window. */
let globalState: ExtensionContext["globalState"] | undefined;
/** Wall-clock time of the last background check by any window. */
const LAST_CHECK_KEY = "rigor.runtime.lastUpdateCheck";
/** Versions the user answered "Later" to. */
const DECLINED_KEY = "rigor.runtime.declinedUpdates";

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
  globalState = context.globalState;
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

/**
 * Valid installs, newest first. A `dev` install is left out unless the
 * development override is active (or `all`), so a production window
 * never selects what a development host left behind.
 */
function installedVersions(all = false): Manifest[] {
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
  return manifests
    .filter((m) => all || devGemPath !== undefined || m.version !== DEV_VERSION)
    .sort((a, b) => compareVersions(b.version, a.version));
}

/** Whether `version` is installed: its directory, with a valid manifest. */
function isInstalled(version: string): boolean {
  return installedVersions(true).some((m) => m.version === version);
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
  // `bundle install` fetches over HTTPS: a Ruby whose OpenSSL does not
  // load cannot install anything.
  'ssl = begin; require "openssl"; true; rescue LoadError, StandardError; false; end',
  'print RUBY_VERSION, "\\n", req.satisfied_by?(Gem.ruby_version), "\\n", RbConfig.ruby, "\\n", (Gem.bin_path("bundler", "bundle") rescue ""), "\\n", Gem.ruby_version.prerelease?, "\\n", ssl',
].join("; ");

/**
 * The first Ruby that qualifies, in order: `rigor.runtime.rubyPath`,
 * then `ruby` on PATH, then the version managers' install directories.
 * A prerelease (`4.1.0.preview1`, `4.1.0.dev`) satisfies the gemspec's
 * `< 4.1` by RubyGems' rules, so it qualifies only as the named
 * `rubyPath`. `skip` holds the real paths of Rubies already tried. The
 * pinned bundle uses `findRubyMatching` instead.
 */
export async function findRuby(
  output: OutputChannel,
  skip: ReadonlySet<string> = new Set(),
): Promise<RubyCandidate | undefined> {
  const configured = (
    workspace.getConfiguration("rigor").get<string>("runtime.rubyPath") ?? ""
  ).trim();
  if (configured && !skip.has(realPath(resolveExecutable(configured)))) {
    const found = await probeRuby(configured, output);
    if (found && rubyQualifies(found, true)) {
      return { ...found, explicit: true };
    }
    if (skip.size === 0) {
      void window.showWarningMessage(
        `Rigor: "rigor.runtime.rubyPath" is "${configured}", which is not a ` +
          `Ruby satisfying ${REQUIRED_RUBY.join(", ")} with Bundler and OpenSSL. Looking for another.`,
      );
    }
  }
  const candidates = dedupeCandidates(rubyCandidates(), (c) =>
    realPath(resolveExecutable(c)),
  );
  for (const candidate of candidates) {
    if (skip.has(realPath(resolveExecutable(candidate)))) {
      continue;
    }
    const found = await probeRuby(candidate, output);
    if (!found || skip.has(realPath(found.ruby))) {
      continue;
    }
    if (rubyQualifies(found, false)) {
      return found;
    }
    if (found.prerelease) {
      output.appendLine(
        `[rigor] ${candidate}: Ruby ${found.version} is a prerelease; ` +
          'name it in "rigor.runtime.rubyPath" to use it',
      );
    }
  }
  output.appendLine(
    `[rigor] no Ruby ${REQUIRED_RUBY.join(", ")} with Bundler and OpenSSL among: ${candidates.join(", ")}`,
  );
  return undefined;
}

/**
 * Whether a probed Ruby is one to install with: it carries Bundler and
 * OpenSSL (`probeRuby` checked the version range), and it is a release
 * unless the user named it (`explicit`).
 */
export function rubyQualifies(probe: RubyProbe, explicit: boolean): boolean {
  return probe.openssl && (explicit || !probe.prerelease);
}

/**
 * `candidates` without the ones that resolve to an executable already
 * listed (`ruby` on PATH is often a manager's install), first one kept.
 */
export function dedupeCandidates(
  candidates: readonly string[],
  resolve: (candidate: string) => string,
): string[] {
  const seen = new Set<string>();
  const kept: string[] = [];
  for (const candidate of candidates) {
    const key = resolve(candidate);
    if (!seen.has(key)) {
      seen.add(key);
      kept.push(candidate);
    }
  }
  return kept;
}

/** A bare command name looked up on PATH; a path as given. */
function resolveExecutable(command: string): string {
  if (command.includes("/") || command.includes("\\")) {
    return command;
  }
  const sep = process.platform === "win32" ? ";" : ":";
  const names =
    process.platform === "win32" ? [`${command}.exe`, command] : [command];
  for (const dir of (process.env.PATH ?? "").split(sep)) {
    for (const name of names) {
      const candidate = dir && path.join(dir, name);
      if (candidate && fs.existsSync(candidate)) {
        return candidate;
      }
    }
  }
  return command;
}

function realPath(file: string): string {
  try {
    return fs.realpathSync(file);
  } catch {
    return file;
  }
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
  const [version, satisfied, ruby, bundler, prerelease, openssl] = out.split("\n");
  if (satisfied !== "true" || !ruby || !bundler) {
    output.appendLine(
      `[rigor] ${candidate}: Ruby ${version ?? "?"}${satisfied === "true" ? " without Bundler" : ""} does not qualify`,
    );
    return undefined;
  }
  if (openssl !== "true") {
    output.appendLine(
      `[rigor] ${candidate}: Ruby ${version} cannot load OpenSSL, which \`bundle install\` needs`,
    );
  }
  return {
    version,
    ruby,
    bundler,
    prerelease: prerelease === "true",
    openssl: openssl === "true",
  };
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

/**
 * The Ruby for the pinned bundle (`resolve.ts`): the first candidate, in
 * `findRuby`'s order, that satisfies the first of `requirements` any
 * candidate satisfies (the bundle's lockfile `RUBY VERSION`, then its
 * Gemfile's `ruby` line), else rigortype's own range. Each candidate is
 * probed once, for every requirement at a time. Unlike the managed
 * install, a named `rubyPath` that misses a requirement is not warned
 * about: the next requirement may take it.
 */
export async function findRubyMatching(
  output: OutputChannel,
  requirements: readonly (readonly string[])[],
): Promise<RubyCandidate | undefined> {
  const all = [...requirements, REQUIRED_RUBY];
  const script = [
    `reqs = [${all.map((r) => `Gem::Requirement.new(${r.map((x) => JSON.stringify(x)).join(", ")})`).join(", ")}]`,
    'ssl = begin; require "openssl"; true; rescue LoadError, StandardError; false; end',
    'print RUBY_VERSION, "\n", RbConfig.ruby, "\n", (Gem.bin_path("bundler", "bundle") rescue ""), "\n", Gem.ruby_version.prerelease?, "\n", ssl, "\n", reqs.map { |r| r.satisfied_by?(Gem.ruby_version) }.join(",")',
  ].join("; ");
  const configured = (
    workspace.getConfiguration("rigor").get<string>("runtime.rubyPath") ?? ""
  ).trim();
  const candidates = dedupeCandidates(
    [...(configured ? [configured] : []), ...rubyCandidates()],
    (c) => realPath(resolveExecutable(c)),
  );
  const probed = new Map<string, (RubyProbe & { satisfies: boolean[] }) | null>();
  const probe = async (candidate: string) => {
    if (!probed.has(candidate)) {
      const out = await run(candidate, ["-e", script], 15000, os.homedir());
      const [version, ruby, bundler, prerelease, openssl, sat] = (out ?? "").split("\n");
      probed.set(
        candidate,
        out === undefined || !ruby || !bundler
          ? null
          : {
              version,
              ruby,
              bundler,
              prerelease: prerelease === "true",
              openssl: openssl === "true",
              satisfies: (sat ?? "").split(",").map((v) => v === "true"),
            },
      );
    }
    return probed.get(candidate);
  };
  for (let i = 0; i < all.length; i++) {
    for (const candidate of candidates) {
      const found = await probe(candidate);
      const explicit = configured !== "" && candidate === configured;
      if (found && found.satisfies[i] && rubyQualifies(found, explicit)) {
        if (i > 0) {
          output.appendLine(
            `[rigor] info: no Ruby matches ${all.slice(0, i).map((r) => r.join(", ")).join(" or ")}; using ${found.ruby} (Ruby ${found.version})`,
          );
        }
        return { version: found.version, ruby: found.ruby, bundler: found.bundler, explicit };
      }
    }
  }
  output.appendLine(
    `[rigor] no Ruby ${REQUIRED_RUBY.join(", ")} with Bundler and OpenSSL among: ${candidates.join(", ")}`,
  );
  return undefined;
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
export function prune(keep: string): void {
  const root = runtimeRoot;
  if (!root) {
    return;
  }
  for (const name of fs.readdirSync(root)) {
    if (name.startsWith(".tmp-") || name.startsWith(".old-")) {
      fs.rmSync(path.join(root, name), { recursive: true, force: true });
    }
    // The log of a `mise install` a closed window left running, once that
    // has been quiet for MISE_LOG_RECENT_MS (one being written stays).
    if (MISE_LOG.test(name) && !miseLogRecent(path.join(root, name))) {
      fs.rmSync(path.join(root, name), { force: true });
    }
  }
  // A `dev` install is not counted in a production window (and not
  // removed there either): the two kept are the newest releases.
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
 * How an install ended: `installed` (the version is there, with its
 * manifest), `busy` (another window holds the lock or runs the version,
 * so nothing was tried), or `failed`.
 */
export type InstallResult = "installed" | "busy" | "failed";

/**
 * Install the managed Rigor (tiers A–C). Resolves true when a usable
 * version is installed afterwards.
 */
export async function installManaged(
  output: OutputChannel,
  options: InstallOptions = {},
): Promise<boolean> {
  return (await installManagedResult(output, options)) === "installed";
}

/**
 * `installManaged`, with the reason it did not install. A second call
 * while one runs shares it when it asks for the same thing, and
 * otherwise waits for it and then runs its own.
 */
export function installManagedResult(
  output: OutputChannel,
  options: InstallOptions = {},
): Promise<InstallResult> {
  if (!workspace.isTrusted) {
    void window.showWarningMessage(
      "Rigor: the managed Rigor is not installed in an untrusted workspace. " +
        "Trust the workspace first.",
    );
    return Promise.resolve("failed");
  }
  const key = `${options.version ?? ""}|${options.repair === true}`;
  if (installing?.key === key) {
    return installing.promise;
  }
  const promise: Promise<InstallResult> = installQueue
    .then(() => installNow(output, options))
    .catch((err): InstallResult => {
      output.appendLine(`[rigor] the managed install failed: ${String(err)}`);
      void window.showErrorMessage(
        `Rigor: installing the managed Rigor failed: ${String(err)}`,
      );
      return "failed";
    })
    .finally(() => {
      if (installing?.promise === promise) {
        installing = undefined;
      }
    });
  installing = { key, promise };
  installQueue = promise;
  return promise;
}

async function installNow(
  output: OutputChannel,
  options: InstallOptions,
): Promise<InstallResult> {
  if (!runtimeRoot) {
    return "failed";
  }
  // The version first: no Ruby search, and no mise offer, for a version
  // that is already there.
  let version: string;
  try {
    version = options.version ?? (await targetVersion());
  } catch (err) {
    void window.showErrorMessage(
      `Rigor: could not find the rigortype version to install: ${String(err)}`,
    );
    return "failed";
  }
  if (isInstalled(version) && !options.repair && version !== DEV_VERSION) {
    void window.showInformationMessage(
      `Rigor: rigortype ${version} is already installed for this editor.`,
    );
    return "installed";
  }
  let ruby = await findRuby(output);
  if (!ruby) {
    ruby = await offerMiseRuby(output);
    if (!ruby) {
      return "failed";
    }
  }
  const repair = options.repair === true;
  const tried = new Set<string>();
  // A build that fails the way a broken Ruby does (OpenSSL or another
  // stdlib extension that does not load) is tried once more with the next
  // Ruby that qualifies, unless the user named this one.
  for (let attempt = 0; attempt < 2; attempt++) {
    const found: RubyCandidate = ruby;
    tried.add(realPath(found.ruby));
    const result = await withLock(() =>
      installVersion(output, found, version, repair),
    );
    if (result === undefined) {
      return "busy";
    }
    if (result === "installed" || result === "busy") {
      return result;
    }
    if (result === "failed") {
      break;
    }
    const next =
      attempt === 0 && !found.explicit ? await findRuby(output, tried) : undefined;
    if (!next) {
      break;
    }
    output.appendLine(
      `[rigor] the build failed the way a broken Ruby does; trying Ruby ${next.version} (${next.ruby})`,
    );
    ruby = next;
  }
  showInstallFailed(output, version, failureHint(lastBuildFailure));
  return "failed";
}

function showInstallFailed(
  output: OutputChannel,
  version: string,
  hint: string,
): void {
  const show = "Show Output";
  const guide = "Installation guide";
  void window
    .showErrorMessage(
      `Rigor: installing rigortype ${version} failed.${hint} The Bundler output is in the Rigor output channel.`,
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

/** `ruby-failed`: failed the way a broken Ruby does, so another may work. */
type BuildResult = "installed" | "busy" | "failed" | "ruby-failed";

async function installVersion(
  output: OutputChannel,
  ruby: RubyCandidate,
  version: string,
  repair: boolean,
): Promise<BuildResult> {
  const root = runtimeRoot;
  if (!root) {
    return "failed";
  }
  const dir = path.join(root, version);
  if (replaceBlocked(dir, repair)) {
    showReplaceBlocked(version);
    return "busy";
  }
  const staging = path.join(
    root,
    `.tmp-${version}-${process.pid}-${Date.now().toString(36)}`,
  );
  output.appendLine(
    `[rigor] installing rigortype ${version} with Ruby ${ruby.version} (${ruby.ruby}) into ${dir}`,
  );
  let result: BuildResult = "failed";
  try {
    result = await window.withProgress(
      {
        location: ProgressLocation.Notification,
        title: `Rigor: installing rigortype ${version}`,
        cancellable: true,
      },
      (progress, token) =>
        buildInto(staging, output, ruby, version, progress, token),
    );
    // Again: a window may have started on the version during the build.
    if (result === "installed" && replaceBlocked(dir, repair)) {
      result = "busy";
    } else if (result === "installed") {
      replaceDir(staging, dir);
    }
  } catch (err) {
    result = "failed";
    output.appendLine(`[rigor] the install failed: ${String(err)}`);
  } finally {
    fs.rmSync(staging, { recursive: true, force: true });
  }
  if (result === "busy") {
    showReplaceBlocked(version);
    return result;
  }
  if (result !== "installed") {
    return result;
  }
  output.appendLine(`[rigor] installed rigortype ${version} into ${dir}`);
  prune(version);
  return "installed";
}

/**
 * What a failed `bundle install` says about its cause:
 * - `ruby`: the Ruby itself is broken: OpenSSL or another stdlib
 *   extension does not load, or was built against another library
 *   version. Another Ruby may work.
 * - `tls`: the HTTPS connection was refused (a certificate that does not
 *   verify, usually a proxy or a missing CA bundle). Another Ruby would
 *   fail the same way.
 * - `compiler`: a native extension did not build (no compiler, no
 *   headers). Likewise.
 * Anything else (the network, the gem) is undefined.
 */
export type BuildFailure = "ruby" | "tls" | "compiler";

export function classifyBuildFailure(text: string): BuildFailure | undefined {
  if (
    /cannot load such file -- (openssl|zlib|psych|digest|etc|fiddle|io\/console)\b|incompatible library version|LoadError[^\n]*\b(openssl|zlib|psych|libssl|libcrypto|libyaml)\b/i.test(
      text,
    )
  ) {
    return "ruby";
  }
  if (/certificate verify failed|SSL_connect returned|OpenSSL::SSL::SSLError|unable to get local issuer certificate/i.test(text)) {
    return "tls";
  }
  if (/Gem::Ext::BuildError|Failed to build gem native extension/i.test(text)) {
    return "compiler";
  }
  return undefined;
}

/** What `classifyBuildFailure` found in the last build, for the message. */
let lastBuildFailure: BuildFailure | undefined;

function failureHint(failure: BuildFailure | undefined): string {
  switch (failure) {
    case "tls":
      return " The HTTPS connection to rubygems.org failed certificate verification: check your proxy and CA certificate settings (for example SSL_CERT_FILE).";
    case "compiler":
      return " A native extension did not build: install a C compiler and build tools (on macOS, `xcode-select --install`).";
    case "ruby":
      return " The Ruby it used cannot load a standard library it needs (such as OpenSSL); set \"rigor.runtime.rubyPath\" to a working Ruby 4.0.";
    default:
      return "";
  }
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
): Promise<BuildResult> {
  lastBuildFailure = undefined;
  fs.mkdirSync(staging, { recursive: true });
  const gem = devGemPath
    ? `gem 'rigortype', path: ${rubyString(devGemPath)}`
    : `gem 'rigortype', ${rubyString(`= ${version}`)}`;
  fs.writeFileSync(
    path.join(staging, "Gemfile"),
    `source 'https://rubygems.org'\n${gem}\n`,
  );
  progress.report({ message: "bundle install" });
  let captured = "";
  const installed = await stream(
    output,
    ruby.ruby,
    [ruby.bundler, "install"],
    staging,
    bundleEnv(staging, false),
    token,
    undefined,
    (text) => {
      captured += text;
    },
  );
  if (!installed) {
    if (token.isCancellationRequested) {
      return "failed";
    }
    lastBuildFailure = classifyBuildFailure(captured);
    return lastBuildFailure === "ruby" ? "ruby-failed" : "failed";
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
    return "failed";
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
  return "installed";
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
  if (requested === DEV_VERSION && !devGemPath) {
    throw new Error(
      `"rigor.runtime.version" is "${DEV_VERSION}", which only a development host with ${DEV_GEM_PATH_ENV} set installs; use latest or a release version`,
    );
  }
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
  onOutput?: (text: string) => void,
): Promise<boolean> {
  const commandLine = [command, ...args].join(" ");
  output.appendLine(`[rigor] $ ${commandLine}`);
  const emit = (text: string): void => {
    output.append(text);
    onOutput?.(text);
  };
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
        follow = followFile(logFile, emit);
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
    child.stdout?.on("data", (data: Buffer) => emit(data.toString()));
    child.stderr?.on("data", (data: Buffer) => emit(data.toString()));
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
  const running = runningMiseLog();
  if (running) {
    void window.showWarningMessage(
      "Rigor: a `mise install ruby@4.0` that a VS Code window started may " +
        `still be running, or may have finished: check its log, ${running}. ` +
        "When it has finished, try again.",
    );
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

const MISE_LOG = /^\.mise-install-\d+\.log$/;
/**
 * A mise log written to this recently may belong to an install still
 * running: one a closed window left behind, or one in another window.
 * mise keeps writing while it builds, so the age is of the last write.
 */
const MISE_LOG_RECENT_MS = 2 * 60 * 60 * 1000;

/**
 * Whether `file` is a mise log written within MISE_LOG_RECENT_MS. The
 * window's pid in the name is not consulted: the install outlives it,
 * and a reused pid would keep a finished log alive.
 */
function miseLogRecent(file: string): boolean {
  if (!MISE_LOG.test(path.basename(file))) {
    return false;
  }
  try {
    return Date.now() - fs.statSync(file).mtimeMs < MISE_LOG_RECENT_MS;
  } catch {
    return false;
  }
}

/**
 * A log that has not grown for this long belongs to an install that
 * ended (or was killed) without saying so. ruby-build compiles quietly
 * for minutes at a time, so it is longer than one compile step.
 */
const MISE_LOG_QUIET_MS = 15 * 60 * 1000;

/**
 * Whether a mise log (its last few KiB, and how long since it last grew)
 * reads as an install still running: it grew lately, and its tail does
 * not show mise or ruby-build finishing, with success or an error.
 */
export function miseLogActive(tail: string, quietMs: number): boolean {
  if (quietMs >= MISE_LOG_QUIET_MS) {
    return false;
  }
  // Only the final non-empty line counts: a tick printed by an earlier
  // step, or a compiler line that starts with `Error:` and is followed by
  // more output, is not the end of the install.
  const last =
    tail
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line !== "")
      .pop() ?? "";
  return !MISE_LOG_FINISHED.test(last);
}

const MISE_LOG_FINISHED =
  /^(?:.*\bInstalled ruby-\S+ to|.*\bBUILD FAILED|mise\b.*\b(?:ERROR|error)\b|(?:ERROR|Error)\b.*|.*✓.*\binstalled\b.*|.*\binstalled\b.*ruby@.*)/;

function miseLogTail(file: string): string {
  let fd: number | undefined;
  try {
    fd = fs.openSync(file, "r");
    const size = fs.fstatSync(fd).size;
    const length = Math.min(size, 4096);
    const buffer = Buffer.alloc(length);
    fs.readSync(fd, buffer, 0, length, size - length);
    return buffer.toString("utf8");
  } catch {
    return "";
  } finally {
    if (fd !== undefined) {
      fs.closeSync(fd);
    }
  }
}

/** A mise log another install may still be writing, if any. */
function runningMiseLog(): string | undefined {
  const root = runtimeRoot;
  if (!root) {
    return undefined;
  }
  let names: string[];
  try {
    names = fs.readdirSync(root);
  } catch {
    return undefined;
  }
  return names
    .filter((name) => MISE_LOG.test(name))
    .map((name) => path.join(root, name))
    .find((file) => {
      try {
        const quiet = Date.now() - fs.statSync(file).mtimeMs;
        return miseLogActive(miseLogTail(file), quiet);
      } catch {
        return false;
      }
    });
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

export async function checkForUpdate(output: OutputChannel): Promise<void> {
  const installed = installedVersions();
  const requested = requestedVersion();
  if (requested === DEV_VERSION && !devGemPath) {
    void window.showInformationMessage(
      `Rigor: "rigor.runtime.version" is "${DEV_VERSION}", which is only ` +
        `valid in an extension development host with ${DEV_GEM_PATH_ENV} set; ` +
        "use latest or a release version.",
    );
    return;
  }
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
  if (choice !== install) {
    return;
  }
  const target = await freshLatest(output, latest);
  if (target && (await installManaged(output, { version: target }))) {
    await offerRestart();
  }
}

/**
 * The latest release again, for a prompt the user may have left open
 * for a while; the earlier answer when rubygems.org is unreachable now.
 */
async function freshLatest(
  output: OutputChannel,
  earlier: string,
): Promise<string | undefined> {
  try {
    const now = await latestVersion();
    return compareVersions(now, earlier) >= 0 ? now : earlier;
  } catch (err) {
    output.appendLine(`[rigor] could not re-check rubygems.org: ${String(err)}`);
    return earlier;
  }
}

/**
 * Offer a restart onto the version `latest` now selects (the newest
 * installed). Resolves whether the user answered.
 */
async function offerRestart(): Promise<boolean> {
  const next = installedVersions()[0]?.version;
  if (!next) {
    return false;
  }
  const restartNow = "Restart Server";
  const after = await window.showInformationMessage(
    `Rigor: rigortype ${next} is installed and takes effect when the server restarts.`,
    restartNow,
  );
  if (after === restartNow) {
    await commands.executeCommand("rigor.restartServer");
  }
  return after !== undefined;
}

// ---------------------------------------------------------------------------
// Background update checks (#2746)

/** The first check after a managed server starts. */
const UPDATE_FIRST_CHECK_MS = 30 * 1000;
const HOUR_MS = 60 * 60 * 1000;
/** How many declined versions `globalState` remembers. */
const DECLINED_KEEP = 20;

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
 * When any window last checked, from `globalState`: the interval is a
 * rate for the machine, not per window. A time in the future (a clock
 * set back) counts as never.
 */
function lastUpdateCheck(): number {
  const at = globalState?.get<number>(LAST_CHECK_KEY);
  return typeof at === "number" && at <= Date.now() ? at : 0;
}

function declinedUpdates(): string[] {
  const list = globalState?.get<unknown>(DECLINED_KEY);
  return Array.isArray(list) ? list.filter((v): v is string => typeof v === "string") : [];
}

/**
 * Arm the next check: `delayMs` from now, but never sooner than the
 * interval after the last check by any window. A no-op while one is
 * armed or running. Called whenever a folder starts on the managed Rigor.
 */
function scheduleUpdateCheck(delayMs: number): void {
  if (updateTimer || updateChecking || !runtimeOutput) {
    return;
  }
  const last = lastUpdateCheck();
  const notBefore = last === 0 ? 0 : last + updateIntervalMs();
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
  if (Date.now() - lastUpdateCheck() < updateIntervalMs()) {
    // Another window checked meanwhile.
    scheduleUpdateCheck(UPDATE_FIRST_CHECK_MS);
    return;
  }
  updateChecking = true;
  try {
    await globalState?.update(LAST_CHECK_KEY, Date.now());
    await checkInBackground(output);
  } finally {
    updateChecking = false;
    if (inUse.size > 0) {
      scheduleUpdateCheck(UPDATE_FIRST_CHECK_MS);
    }
  }
}

/**
 * One background check. A newer release is announced until the user
 * answers: "Install update" installs it beside the current version (used
 * from the next restart), "Later" is remembered for every window. A
 * newer version another window already installed is offered as a
 * restart. An install refused because another window holds the lock is
 * not an answer, so the next check offers the restart instead. A network
 * failure logs one line and changes nothing.
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
    new Set([...updateOffered, ...declinedUpdates()]),
    restartOffered,
  );
  if (decision.kind === "none") {
    return;
  }
  if (decision.kind === "restart") {
    if (await offerRestart()) {
      restartOffered.add(decision.version);
    }
    return;
  }
  const install = "Install update";
  const later = "Later";
  const choice = await window.showInformationMessage(
    `Rigor: rigortype ${decision.version} is available (the managed Rigor ` +
      `runs ${decision.current}). It installs beside the current version and ` +
      "is used from the next server restart.",
    install,
    later,
  );
  if (choice === later) {
    updateOffered.add(decision.version);
    await globalState?.update(
      DECLINED_KEY,
      [...declinedUpdates().filter((v) => v !== decision.version), decision.version].slice(
        -DECLINED_KEEP,
      ),
    );
    return;
  }
  if (choice !== install || !autoUpdateApplies()) {
    return;
  }
  const target = await freshLatest(output, decision.version);
  if (!target) {
    return;
  }
  const result = await installManagedResult(output, { version: target });
  if (result === "busy") {
    return;
  }
  updateOffered.add(decision.version);
  updateOffered.add(target);
  if (result === "installed" && (await offerRestart())) {
    const next = installedVersions()[0]?.version;
    if (next) {
      restartOffered.add(next);
    }
  }
}

export type UpdateDecision =
  | { kind: "none" }
  | { kind: "install"; version: string; current: string }
  | { kind: "restart"; version: string };

/**
 * What a background check does with the `latest` release, given the
 * installed versions and those this window's servers run (both version
 * directory names): install it when nothing installed is that new;
 * offer a restart onto the newest installed version when that is at
 * least `latest` (another window updated) but not running. `declined`
 * (answered install offers, "Later" in any window included) suppresses
 * only the install offer; once a version is installed its restart is
 * offered until answered in this window (`restartAnswered`).
 */
export function updateDecision(
  latest: string,
  installed: readonly string[],
  running: readonly string[],
  declined: ReadonlySet<string>,
  restartAnswered: ReadonlySet<string>,
): UpdateDecision {
  if (running.length === 0) {
    return { kind: "none" };
  }
  const newest = (list: readonly string[]): string | undefined =>
    [...list].sort((a, b) => compareVersions(b, a))[0];
  const newestRunning = newest(running) as string;
  if (compareVersions(newestRunning, latest) >= 0) {
    return { kind: "none" };
  }
  const newestInstalled = newest(installed);
  if (newestInstalled && compareVersions(newestInstalled, latest) >= 0) {
    if (
      compareVersions(newestInstalled, newestRunning) <= 0 ||
      restartAnswered.has(newestInstalled)
    ) {
      return { kind: "none" };
    }
    return { kind: "restart", version: newestInstalled };
  }
  if (declined.has(latest)) {
    return { kind: "none" };
  }
  return { kind: "install", version: latest, current: newestRunning };
}

async function clearManaged(
  output: OutputChannel,
  whileStopped: (task: () => Promise<void>) => Promise<void>,
): Promise<void> {
  const root = runtimeRoot;
  const versions = installedVersions(true).map((m) => m.version);
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
