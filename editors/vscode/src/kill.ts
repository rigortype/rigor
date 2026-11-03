// Process-tree kill, shared by the language server and the managed
// install's `bundle install`.

import { ChildProcess, execFileSync } from "child_process";

/**
 * Kill a process and everything it started. On POSIX the process must
 * have been spawned `detached`, so it leads its own process group and the
 * group kill reaches its children (the server's fork-based worker pool,
 * the compilers `bundle install` runs). On Windows `taskkill /T` walks the
 * tree, which also reaches the `ruby.exe` behind a `cmd.exe` that
 * `shell: true` interposes.
 */
export function killTree(child: ChildProcess): void {
  const pid = child.pid;
  if (pid === undefined) {
    return;
  }
  try {
    if (process.platform === "win32") {
      execFileSync("taskkill", ["/T", "/F", "/PID", String(pid)], {
        stdio: "ignore",
        windowsHide: true,
      });
    } else {
      process.kill(-pid, "SIGKILL");
    }
  } catch {
    child.kill("SIGKILL");
  }
}
