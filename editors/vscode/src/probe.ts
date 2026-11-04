// Startup probe — run `rigor version` before launching the language
// server so a missing or outdated gem produces an actionable message
// instead of an opaque spawn failure.

import { execFile } from "child_process";
import { ResolvedServer, useShell, versionArgs } from "./discovery";
import { shellInvocation } from "./proc";

/** First `rigor lsp` release. Older gems cannot serve the LSP. */
export const MIN_VERSION = "0.1.6";

/** How long one `rigor version` probe may take. */
export const PROBE_TIMEOUT_MS = 20000;

export interface ProbeResult {
  /** True when a usable server (>= MIN_VERSION) was found. */
  ok: boolean;
  /** Detected `rigortype` version, when the probe ran. */
  version?: string;
  /** True when the executable could not be spawned at all. */
  notFound?: boolean;
  /** True when a version was found but is older than MIN_VERSION. */
  tooOld?: boolean;
  /** The whole version token `rigor version` printed, prerelease included. */
  fullVersion?: string;
  /** Why a failed probe failed: the first stderr line, or the error. */
  detail?: string;
}

function compareSemver(a: string, b: string): number {
  const pa = a.split(".").map((n) => parseInt(n, 10) || 0);
  const pb = b.split(".").map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < 3; i++) {
    const diff = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (diff !== 0) {
      return diff;
    }
  }
  return 0;
}

/** Run `rigor version` in the folder and classify the outcome. */
export function probeServer(
  server: ResolvedServer,
  cwd: string,
): Promise<ProbeResult> {
  const shell = useShell(server);
  const invocation = shellInvocation(server.command, versionArgs(server), shell);
  return new Promise((resolve) => {
    execFile(
      invocation.command,
      invocation.args,
      {
        cwd,
        env: server.env,
        timeout: PROBE_TIMEOUT_MS,
        windowsHide: true,
        shell,
      },
      (error, stdout, stderr) => {
        if (error) {
          const code = (error as NodeJS.ErrnoException).code;
          const firstErr = String(stderr)
            .split("\n")
            .map((l) => l.trim())
            .find((l) => l !== "");
          resolve({
            ok: false,
            notFound: code === "ENOENT",
            detail:
              code === "ENOENT"
                ? "not found"
                : error.killed && error.signal
                  ? `timed out after ${PROBE_TIMEOUT_MS / 1000} s`
                  : firstErr ??
                    (typeof code === "number" ? `exit ${code}` : error.message),
          });
          return;
        }
        const match = /\b(\d+\.\d+\.\d+)\b/.exec(stdout);
        if (!match) {
          // The executable ran but printed no recognizable version.
          // Treat as usable rather than blocking on a parse miss.
          resolve({ ok: true });
          return;
        }
        const version = match[1];
        const tooOld = compareSemver(version, MIN_VERSION) < 0;
        // `rigor version` prints `rigor #{Rigor::VERSION}`; the full token
        // keeps a prerelease segment (`0.5.0.pre1`).
        const fullVersion = /\brigor\s+(\S+)/.exec(stdout)?.[1];
        resolve({ ok: !tooOld, version, tooOld, fullVersion });
      },
    );
  });
}
