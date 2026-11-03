// Process helpers shared by the language-server lifecycle and the CLI-backed
// commands.

import { ChildProcess, spawn } from "child_process";

import { killTree } from "./kill";

/**
 * Quote one argument for `cmd.exe`, which `shell: true` interposes on
 * Windows: whitespace splits an unquoted argument and `& | ^ < > ( ) % !`
 * are interpreted. POSIX spawns take the vector as is. Known limits: cmd.exe
 * still expands `%VAR%` inside quotes, and an argument ending in a backslash
 * before the closing quote can be mis-parsed by the child's argument parser.
 */
export function shellArg(arg: string): string {
  if (process.platform !== "win32") {
    return arg;
  }
  return arg === "" || /[\s&|^<>()%!"]/.test(arg)
    ? `"${arg.replace(/"/g, '""')}"`
    : arg;
}

const live = new Set<ChildProcess>();

/**
 * Spawn a one-shot CLI child in its own process group, with every argument
 * (and the command) quoted for the shell Windows interposes, and remember it
 * so `killAllCli` can reap it when the extension shuts down.
 */
export function spawnCli(
  command: string,
  args: string[],
  cwd: string,
): ChildProcess {
  const win = process.platform === "win32";
  const child = spawn(win ? shellArg(command) : command, win ? args.map(shellArg) : args, {
    cwd,
    shell: win,
    detached: !win,
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
  live.add(child);
  child.on("close", () => live.delete(child));
  child.on("error", () => live.delete(child));
  return child;
}

/** Kill every CLI child still running (extension deactivate). */
export function killAllCli(): void {
  for (const child of live) {
    killTree(child);
  }
  live.clear();
}

// One implementation, shared with the lifecycle and the managed install.
export { killTree };
