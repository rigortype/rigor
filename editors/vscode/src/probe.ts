// Startup probe — run `rigor version` before launching the language
// server so a missing or outdated gem produces an actionable message
// instead of an opaque spawn failure.

import { execFile } from "child_process";
import { ResolvedServer, versionArgs } from "./discovery";

/** First `rigor lsp` release. Older gems cannot serve the LSP. */
export const MIN_VERSION = "0.1.6";

export interface ProbeResult {
  /** True when a usable server (>= MIN_VERSION) was found. */
  ok: boolean;
  /** Detected `rigortype` version, when the probe ran. */
  version?: string;
  /** True when the executable could not be spawned at all. */
  notFound?: boolean;
  /** True when a version was found but is older than MIN_VERSION. */
  tooOld?: boolean;
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
  return new Promise((resolve) => {
    execFile(
      server.command,
      versionArgs(server),
      {
        cwd,
        timeout: 20000,
        windowsHide: true,
        shell: process.platform === "win32",
      },
      (error, stdout) => {
        if (error) {
          const code = (error as NodeJS.ErrnoException).code;
          resolve({ ok: false, notFound: code === "ENOENT" });
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
        resolve({ ok: !tooOld, version, tooOld });
      },
    );
  });
}
