// The one resolution path (#2748): which `rigor` serves a folder. The
// language server, the `rigor: check` task and every CLI-backed command
// ask `resolveRigor`, so all three run the same executable.
//
// Candidates, in order (README "Server discovery"):
//
// 1. `rigor.server.path` — the user's choice: reported when it fails, never
//    replaced.
// 2. `bundle exec rigor` for a project `Gemfile.lock` / `gems.locked`
//    pinning rigortype.
// 3. The pinned bundle (ADR-27 WD9, #2750): `.github/rigor/Gemfile.lock`
//    pinning rigortype, or `rigor.server.bundleGemfile`.
// 4. Every `rigor` on `PATH`, in `PATH` order.
// 5. Every mise / asdf shim.
// 6. The managed Rigor, for a project with no pin.
//
// A pin is final: a project whose lockfile pins rigortype runs 2 or 3 and
// nothing else, and one whose mise or asdf config pins it runs the shims
// and nothing else, because a different Rigor would report diagnostics
// that differ from CI's. `rigor.server.useBundler: always` makes 2 or 3
// the only candidate (3 when `rigor.server.bundleGemfile` is set); `never`
// skips both. The first candidate whose `rigor version` probe passes wins.
// One that runs but is too old stops the walk: it is the user's own
// install, and gets the upgrade warning instead of being hidden behind a
// later one.

import * as fs from "fs";
import * as path from "path";
import { OutputChannel, WorkspaceFolder, window, workspace } from "vscode";
import {
  BundlerMode,
  ResolvedServer,
  displayCommand,
  lockedRigortype,
  lockfileFor,
  pathExecutables,
  pinnedBundleGemfile,
  pinnedBundleLock,
  projectLockPin,
  findPin,
  projectRoot,
  versionManagerShims,
} from "./discovery";
import { ProbeResult, probeServer } from "./probe";
import { findRubyMatching, managedServer } from "./runtime";

/** After this long, the walk skips the candidates no pin requires. */
const WALK_BUDGET_MS = 45000;

export interface Rejected {
  server: ResolvedServer;
  reason: string;
}

/** What pins rigortype for the folder, for the not-found message. */
export type Pin =
  | { kind: "lock"; file: string }
  | { kind: "pinned-bundle"; file: string; gemfile: string }
  | { kind: "tool"; file: string };

export interface Resolution {
  /** The server that passed its probe, or the one to report. */
  server: ResolvedServer;
  probe: ProbeResult;
  /** Candidates tried before `server` and rejected, in order. */
  rejected: Rejected[];
  /**
   * Whether the managed Rigor may serve this folder: no explicit path, no
   * `useBundler: always`, and no project pin (ADR-27 WD9).
   */
  managedReachable: boolean;
  /** The pin that ended the walk, when one did. */
  pin?: Pin;
  /** A sentence for the not-found message, when the settings explain it. */
  hint?: string;
}

/** A group of candidates; `final` ends the walk after it. */
interface Step {
  candidates: () => Promise<ResolvedServer[]>;
  final?: boolean;
}

const cache = new Map<string, Promise<Resolution>>();
const settled = new Map<string, Resolution>();
/** Each folder's pin signature when its resolution was made. */
const signatures = new Map<string, string>();
let stopping = false;
/** Folders already warned that `useBundler: never` ignores their lockfile pin. */
const neverWarned = new Set<string>();

/**
 * Resolve the `rigor` for a folder. The result, passing or failing, is
 * cached until `forgetResolutions` (a restart, a settings change, a pin
 * change): VS Code asks the task provider often, and a failing walk can
 * probe every candidate. The not-found message says to restart.
 */
export function resolveRigor(
  folder: WorkspaceFolder,
  output: OutputChannel,
): Promise<Resolution> {
  const key = folder.uri.toString();
  const cached = cache.get(key);
  if (cached) {
    return cached;
  }
  signatures.set(key, pinSignature(folder));
  const pending = walk(folder, output);
  cache.set(key, pending);
  pending.then(
    (res) => {
      if (cache.get(key) === pending) {
        settled.set(key, res);
      }
    },
    () => {
      if (cache.get(key) === pending) {
        cache.delete(key);
      }
    },
  );
  return pending;
}

/**
 * The folder's finished resolution, or undefined while none is: then one
 * is started, so a caller that must not wait (the task provider) can ask
 * again later.
 */
export function peekResolution(
  folder: WorkspaceFolder,
  output: OutputChannel,
): Resolution | undefined {
  const done = settled.get(folder.uri.toString());
  if (!done) {
    void resolveRigor(folder, output);
  }
  return done;
}

/** Drop the cached resolution of one folder, or of every folder. */
export function forgetResolutions(folder?: WorkspaceFolder): void {
  if (folder) {
    const key = folder.uri.toString();
    cache.delete(key);
    settled.delete(key);
    signatures.delete(key);
  } else {
    cache.clear();
    settled.clear();
    signatures.clear();
  }
}

/** The window is closing: a walk in progress probes nothing more. */
export function stopResolving(): void {
  stopping = true;
}

/**
 * Whether what pins rigortype for the folder changed since its resolution
 * was made: a lockfile or mise / asdf file appearing, disappearing, or
 * pinning another version. Any other write to those files is no change.
 */
export function pinChanged(folder: WorkspaceFolder): boolean {
  const recorded = signatures.get(folder.uri.toString());
  return recorded === undefined || recorded !== pinSignature(folder);
}

function pinSignature(folder: WorkspaceFolder): string {
  const root = projectRoot(folder);
  if (!root) {
    return "";
  }
  const pinned = pinnedBundleGemfile(folder, root);
  const found = findPin(root);
  const tool = found?.file;
  let toolLines = "";
  if (tool && found.scope !== "lock") {
    try {
      toolLines = fs
        .readFileSync(tool, "utf8")
        .split(/\r?\n/)
        .filter((line) => line.includes("rigortype"))
        .join("\n");
    } catch {
      // Gone since; the path still differs from a later signature.
    }
  }
  return JSON.stringify([
    lockedRigortype(path.join(root, "Gemfile.lock")),
    lockedRigortype(path.join(root, "gems.locked")),
    pinned.rejected ? undefined : lockedRigortype(lockfileFor(pinned.gemfile)),
    // The pinned bundle's Ruby is chosen by these.
    pinned.rejected ? undefined : bundleRubyRequirements(pinned.gemfile),
    tool,
    toolLines,
  ]);
}

/**
 * Whether the version `rigor version` printed is the one a lockfile pins:
 * equal, or the lockfile's with a platform suffix (`0.4.7-x86_64-linux`).
 * `0.4.1` is not `0.4.10`, `0.5.0` not `0.5.0.pre1`, and no version is no
 * match.
 */
export function lockMatches(locked: string, printed: string | undefined): boolean {
  return printed !== undefined && (locked === printed || locked.startsWith(`${printed}-`));
}

/** `/path/to/rigor` (global) — one candidate as the log names it. */
export function describeCandidate(server: ResolvedServer): string {
  return `\`${displayCommand(server, server.prefixArgs)}\` (${server.kind})`;
}

async function walk(
  folder: WorkspaceFolder,
  output: OutputChannel,
): Promise<Resolution> {
  const cfg = workspace.getConfiguration("rigor", folder.uri);
  const root = projectRoot(folder) ?? folder.uri.fsPath;
  const explicitPath = (cfg.get<string>("server.path") ?? "").trim();
  const mode = cfg.get<BundlerMode>("server.useBundler", "auto");
  const pinned = pinnedBundleGemfile(folder, root);
  if (pinned.rejected) {
    const note = `"rigor.server.bundleGemfile" for ${folder.name} is "${pinned.rejected}", which is not a path inside the project root. No pinned bundle is used.`;
    output.appendLine(`[rigor] ${note}`);
    void window.showWarningMessage(`Rigor: ${note}`);
  }
  const projectLock = projectLockPin(root);
  const pinnedLock = pinnedBundleLock(folder, root);
  const anyPin = findPin(root)?.file ?? pinnedLock;
  // `never` opts out of a lockfile pin; a mise or asdf pin behind it
  // still decides.
  const found = findPin(root, { skipLocks: mode === "never" });
  const optedOut = mode === "never" && !explicitPath ? (projectLock ?? pinnedLock) : undefined;
  if (optedOut) {
    const note = `"rigor.server.useBundler" is "never" in ${folder.name}, so the rigortype that ${path.basename(optedOut)} pins is not used; a Rigor from PATH or a shim may report differently from CI.`;
    output.appendLine(`[rigor] ${note}`);
    const key = folder.uri.toString();
    if (!neverWarned.has(key)) {
      neverWarned.add(key);
      void window.showWarningMessage(`Rigor: ${note}`);
    }
  }
  const managedReachable =
    !explicitPath && mode !== "always" && anyPin === undefined;

  const bundler: ResolvedServer = {
    kind: "bundler",
    command: "bundle",
    prefixArgs: ["exec", "rigor"],
  };
  const shims = async (): Promise<ResolvedServer[]> =>
    versionManagerShims().map((command) => ({
      kind: "version-manager" as const,
      command,
      prefixArgs: [],
    }));
  const steps: Step[] = [];
  let pin: Pin | undefined;
  let hint: string | undefined;
  if (explicitPath) {
    steps.push({
      candidates: async () => [
        { kind: "explicit", command: explicitPath, prefixArgs: [] },
      ],
      final: true,
    });
  } else if (mode === "always") {
    const usePinned = pinned.explicit && !pinned.rejected;
    if (usePinned) {
      pin = { kind: "pinned-bundle", file: lockfileFor(pinned.gemfile), gemfile: pinned.gemfile };
    } else if (projectLock) {
      pin = { kind: "lock", file: projectLock };
    } else {
      hint = '"rigor.server.useBundler" is "always", but no Gemfile.lock or pinned bundle pins rigortype.';
    }
    steps.push({
      candidates: async () =>
        usePinned ? pinnedBundleServers(pinned.gemfile, output) : [bundler],
      final: true,
    });
  } else if (mode === "auto" && projectLock) {
    pin = { kind: "lock", file: projectLock };
    steps.push({ candidates: async () => [bundler], final: true });
  } else if (mode === "auto" && pinnedLock) {
    pin = { kind: "pinned-bundle", file: pinnedLock, gemfile: pinned.gemfile };
    steps.push({
      candidates: async () => pinnedBundleServers(pinned.gemfile, output),
      final: true,
    });
  } else if (found?.scope === "project") {
    // A project mise or asdf pin: its shim selects the pinned version. A
    // global pin is the user's default, not the project's, so PATH may
    // still serve it (the managed Rigor may not).
    pin = { kind: "tool", file: found.file };
    steps.push({ candidates: shims, final: true });
  } else {
    steps.push({
      candidates: async () => {
        const { found, skipped } = pathExecutables("rigor");
        if (skipped.length > 0) {
          output.appendLine(
            `[rigor] ${folder.name}: relative PATH entries not searched: ${skipped.join(", ")}`,
          );
        }
        return found.map((command) => ({
          kind: "global" as const,
          command,
          prefixArgs: [],
        }));
      },
    });
    steps.push({ candidates: shims });
    if (managedReachable) {
      steps.push({
        candidates: async () => {
          const managed = managedServer();
          return managed ? [managed] : [];
        },
      });
    }
  }

  const started = Date.now();
  const rejected: Rejected[] = [];
  const tried = new Set<string>();
  let firstFailure: { server: ResolvedServer; probe: ProbeResult } | undefined;
  const reject = (server: ResolvedServer, reason: string): void => {
    output.appendLine(
      `[rigor] ${folder.name}: rejected ${describeCandidate(server)}: ${reason}`,
    );
    rejected.push({ server, reason });
  };
  for (const step of steps) {
    for (const server of await step.candidates()) {
      // The same file on PATH and as a shim is one candidate; the pinned
      // bundle's `bundle exec rigor` differs from the project's by its
      // BUNDLE_GEMFILE, which the display form carries.
      const id = displayCommand(server, server.prefixArgs);
      if (tried.has(id)) {
        continue;
      }
      tried.add(id);
      if (stopping) {
        reject(server, "not tried: the window is closing");
        continue;
      }
      if (!step.final && Date.now() - started > WALK_BUDGET_MS) {
        reject(server, `not tried: discovery ran past ${WALK_BUDGET_MS / 1000} s`);
        continue;
      }
      const probe = await probeServer(server, root);
      // `bundle exec rigor` runs any `rigor` on PATH when the bundle has
      // none installed, so a lockfile pin is checked against what ran.
      const locked =
        (server.kind === "bundler" || server.kind === "pinned-bundle") &&
        pin &&
        pin.kind !== "tool"
          ? lockedRigortype(pin.file)
          : undefined;
      if (
        locked &&
        (probe.ok || probe.tooOld) &&
        !lockMatches(locked, probe.fullVersion)
      ) {
        reject(
          server,
          `runs rigortype ${probe.fullVersion ?? "(no version printed)"}, but ${pin!.file} pins ${locked} (is the bundle installed?)`,
        );
        firstFailure ??= { server, probe: { ...probe, ok: false, tooOld: false } };
        continue;
      }
      if (probe.ok || probe.tooOld) {
        return { server, probe, rejected, managedReachable, pin, hint };
      }
      reject(server, probe.detail ?? "did not run");
      firstFailure ??= { server, probe };
    }
    if (step.final) {
      break;
    }
  }
  if (firstFailure) {
    return { ...firstFailure, rejected, managedReachable, pin, hint };
  }
  // Nothing to try at all.
  return {
    server: { kind: pin?.kind === "tool" ? "version-manager" : "global", command: "rigor", prefixArgs: [] },
    probe: { ok: false, notFound: true, detail: "not found" },
    rejected,
    managedReachable,
    pin,
    hint,
  };
}

/**
 * The environment for the pinned bundle: the extension's, without what
 * would redirect Ruby, RubyGems or Bundler away from this bundle
 * (`GEM_HOME`, `GEM_PATH`, `RUBYOPT`, `RUBYLIB`, `BUNDLE_BIN_PATH`,
 * `BUNDLER_*`, an inherited `BUNDLE_GEMFILE`), with `BUNDLE_GEMFILE` set to
 * the bundle's absolute Gemfile. Other `BUNDLE_*` settings (a `BUNDLE_PATH`
 * the user installs with) stay.
 */
export function pinnedBundleEnv(gemfile: string): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (
      key.startsWith("BUNDLER_") ||
      ["GEM_HOME", "GEM_PATH", "RUBYOPT", "RUBYLIB", "BUNDLE_BIN_PATH", "BUNDLE_GEMFILE"].includes(key)
    ) {
      continue;
    }
    env[key] = value;
  }
  env.BUNDLE_GEMFILE = gemfile;
  return env;
}

/**
 * The Ruby requirements the pinned bundle states for itself, most specific
 * first: the lockfile's `RUBY VERSION` (exact), then the Gemfile's `ruby`
 * line. Empty when it states neither.
 */
export function bundleRubyRequirements(gemfile: string): string[][] {
  const out: string[][] = [];
  try {
    const lock = fs.readFileSync(lockfileFor(gemfile), "utf8");
    const m = /^RUBY VERSION\r?\n\s+ruby (\d+(?:\.\d+)*)/m.exec(lock);
    if (m) {
      out.push([`= ${m[1]}`]);
    }
  } catch {
    // No lockfile: nothing stated there.
  }
  try {
    const text = fs.readFileSync(gemfile, "utf8");
    const line = /^\s*ruby\b\s*\(?\s*((?:(["'])[^"'\n]+\2\s*,?\s*)+)/m.exec(text);
    if (line) {
      const reqs = [...line[1].matchAll(/["']([^"']+)["']/g)].map((r) => r[1]);
      if (reqs.length > 0) {
        out.push(reqs);
      }
    }
  } catch {
    // No Gemfile.
  }
  return out;
}

/**
 * The pinned bundle's candidates: `<ruby> <bundle> exec rigor` under the
 * first Ruby that satisfies the bundle's own Ruby requirement (lockfile
 * `RUBY VERSION`, then the Gemfile's `ruby` line), else rigortype's
 * `required_ruby_version` (the managed runtime's search, `findRuby`), then
 * `bundle exec rigor` from `PATH`. Both run from the project root, with
 * `pinnedBundleEnv`.
 */
async function pinnedBundleServers(
  gemfile: string,
  output: OutputChannel,
): Promise<ResolvedServer[]> {
  const env = pinnedBundleEnv(gemfile);
  const servers: ResolvedServer[] = [];
  if (fs.existsSync(gemfile)) {
    const ruby = await findRubyMatching(output, bundleRubyRequirements(gemfile));
    if (ruby) {
      servers.push({
        kind: "pinned-bundle",
        command: ruby.ruby,
        prefixArgs: [ruby.bundler, "exec", "rigor"],
        env,
        // An absolute Ruby needs no shell, and a shell would split a path
        // with a space in it.
        shell: false,
      });
    }
  }
  servers.push({
    kind: "pinned-bundle",
    command: "bundle",
    prefixArgs: ["exec", "rigor"],
    env,
  });
  return servers;
}
