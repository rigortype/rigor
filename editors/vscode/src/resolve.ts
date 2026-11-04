// The one resolution path (#2748): which `rigor` serves a folder. The
// language server, the `rigor: check` task and every CLI-backed command
// ask `resolveRigor`, so all three run the same executable.
//
// Candidates, in order (README "Server discovery"):
//
// 1. `rigor.server.path` — the user's choice: reported when it fails, never
//    replaced.
// 2. `bundle exec rigor` for a project `Gemfile.lock` pinning rigortype.
// 3. The pinned bundle (ADR-27 WD9, #2750): `.github/rigor/Gemfile.lock`
//    pinning rigortype, or `rigor.server.bundleGemfile`.
// 4. Every `rigor` on `PATH`, in `PATH` order.
// 5. Every mise / asdf shim.
// 6. The managed Rigor, for a project with no pin.
//
// `rigor.server.useBundler: always` makes 2 or 3 the only candidate (3 when
// `rigor.server.bundleGemfile` is set); `never` skips both. The first
// candidate whose `rigor version` probe passes wins. One that runs but is
// too old stops the walk: it is the user's own install, and gets the
// upgrade warning instead of being hidden behind a later one.

import * as fs from "fs";
import { OutputChannel, WorkspaceFolder, workspace } from "vscode";
import {
  BundlerMode,
  ResolvedServer,
  displayCommand,
  lockPinsRigortype,
  lockfileFor,
  lockfileHasRigortype,
  pathExecutables,
  pinnedBundleGemfile,
  projectRoot,
  rigortypePin,
  versionManagerShims,
} from "./discovery";
import { ProbeResult, probeServer } from "./probe";
import { findRuby, managedServer } from "./runtime";

export interface Rejected {
  server: ResolvedServer;
  reason: string;
}

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
}

/** A group of candidates; `final` ends the walk after it. */
interface Step {
  candidates: () => Promise<ResolvedServer[]>;
  final?: boolean;
}

const cache = new Map<string, Promise<Resolution>>();

/**
 * Resolve the `rigor` for a folder. The result, passing or failing, is
 * cached until `forgetResolutions` (a restart, a settings change, a pin
 * lockfile change): VS Code asks the task provider often, and a failing
 * walk can probe every candidate. The not-found message says to restart.
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
  const pending = walk(folder, output);
  cache.set(key, pending);
  pending.catch(() => {
    if (cache.get(key) === pending) {
      cache.delete(key);
    }
  });
  return pending;
}

/** Drop the cached resolution of one folder, or of every folder. */
export function forgetResolutions(folder?: WorkspaceFolder): void {
  if (folder) {
    cache.delete(folder.uri.toString());
  } else {
    cache.clear();
  }
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
  const pinnedLock = lockfileFor(pinned.gemfile);
  const pin =
    rigortypePin(root) ??
    (lockPinsRigortype(pinnedLock) ? pinnedLock : undefined);
  const managedReachable =
    !explicitPath && mode !== "always" && pin === undefined;

  const bundler: ResolvedServer = {
    kind: "bundler",
    command: "bundle",
    prefixArgs: ["exec", "rigor"],
  };
  const steps: Step[] = [];
  if (explicitPath) {
    steps.push({
      candidates: async () => [
        { kind: "explicit", command: explicitPath, prefixArgs: [] },
      ],
      final: true,
    });
  } else if (mode === "always") {
    steps.push({
      candidates: async () =>
        pinned.explicit ? pinnedBundleServers(pinned.gemfile, output) : [bundler],
      final: true,
    });
  } else {
    if (mode === "auto") {
      steps.push({
        candidates: async () => (lockfileHasRigortype(root) ? [bundler] : []),
      });
      steps.push({
        candidates: async () =>
          lockPinsRigortype(pinnedLock)
            ? pinnedBundleServers(pinned.gemfile, output)
            : [],
      });
    }
    steps.push({
      candidates: async () =>
        pathExecutables("rigor").map((command) => ({
          kind: "global" as const,
          command,
          prefixArgs: [],
        })),
    });
    steps.push({
      candidates: async () =>
        versionManagerShims().map((command) => ({
          kind: "version-manager" as const,
          command,
          prefixArgs: [],
        })),
    });
    if (managedReachable) {
      steps.push({
        candidates: async () => {
          const managed = managedServer();
          return managed ? [managed] : [];
        },
      });
    }
  }

  const rejected: Rejected[] = [];
  const tried = new Set<string>();
  let firstFailure: { server: ResolvedServer; probe: ProbeResult } | undefined;
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
      const probe = await probeServer(server, root);
      if (probe.ok || probe.tooOld) {
        return { server, probe, rejected, managedReachable };
      }
      const reason = probe.detail ?? "did not run";
      output.appendLine(
        `[rigor] ${folder.name}: rejected ${describeCandidate(server)}: ${reason}`,
      );
      rejected.push({ server, reason });
      firstFailure ??= { server, probe };
    }
    if (step.final) {
      break;
    }
  }
  if (firstFailure) {
    return { ...firstFailure, rejected, managedReachable };
  }
  // Nothing to try at all.
  return {
    server: { kind: "global", command: "rigor", prefixArgs: [] },
    probe: { ok: false, notFound: true, detail: "not found" },
    rejected,
    managedReachable,
  };
}

/**
 * The pinned bundle's candidates: `<ruby> <bundle> exec rigor` under the
 * first Ruby that satisfies rigortype's `required_ruby_version` (the
 * managed runtime's search, `findRuby`), then `bundle exec rigor` from
 * `PATH`. Both with `BUNDLE_GEMFILE` set to the absolute Gemfile and run
 * from the project root.
 */
async function pinnedBundleServers(
  gemfile: string,
  output: OutputChannel,
): Promise<ResolvedServer[]> {
  const env = { ...process.env, BUNDLE_GEMFILE: gemfile };
  const servers: ResolvedServer[] = [];
  if (fs.existsSync(gemfile)) {
    const ruby = await findRuby(output);
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
