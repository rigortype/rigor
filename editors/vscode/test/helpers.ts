// Shared fixtures: a sandbox directory tree, a pinned environment and fake
// executables (shell scripts), so the tests exercise the real filesystem
// and process code with nothing from the machine leaking in.

import * as fs from "fs";
import * as os from "os";
import * as path from "path";

export interface Sandbox {
  /** Everything lives below this. */
  dir: string;
  /** `HOME`: the project is below it, as a project under `~/work` is. */
  home: string;
  /** A project directory below `home`. */
  project: string;
  /** Put fake executables here and list it in `PATH`. */
  bin: string;
  /** The system tools the fake scripts need; keep it last in a `PATH`. */
  sysbin: string;
  /** Restore the environment and delete the tree. */
  dispose(): void;
}

const ENV_KEYS = [
  "HOME",
  "PATH",
  "MISE_ENV",
  "MISE_CONFIG_DIR",
  "MISE_GLOBAL_CONFIG_FILE",
  "MISE_DATA_DIR",
  "ASDF_DATA_DIR",
  "XDG_CONFIG_HOME",
  "XDG_DATA_HOME",
  "LOCALAPPDATA",
  "BUNDLE_GEMFILE",
  "GEM_HOME",
];

/**
 * A fresh tree with `HOME`, `PATH` and the version managers' variables
 * pointed into it. `PATH` is `bin` plus `sysbin`, which links only the few
 * system tools the fake scripts use, so a `ruby`, `bundle` or `rigor` the
 * machine happens to have (CI images ship one) never answers a probe.
 */
export function sandbox(): Sandbox {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "rigor-vscode-test-")));
  const home = path.join(dir, "home");
  const project = path.join(home, "proj");
  const bin = path.join(dir, "bin");
  fs.mkdirSync(project, { recursive: true });
  fs.mkdirSync(bin, { recursive: true });
  const sysbin = path.join(dir, "sysbin");
  fs.mkdirSync(sysbin);
  for (const tool of ["sh", "sleep", "cat", "env", "true", "false"]) {
    const found = ["/bin", "/usr/bin"].map((d) => path.join(d, tool)).find((f) => fs.existsSync(f));
    if (found) {
      fs.symlinkSync(found, path.join(sysbin, tool));
    }
  }
  const saved = new Map<string, string | undefined>();
  for (const key of ENV_KEYS) {
    saved.set(key, process.env[key]);
    delete process.env[key];
  }
  process.env.HOME = home;
  process.env.PATH = `${bin}:${sysbin}`;
  process.env.MISE_DATA_DIR = path.join(dir, "mise-data");
  process.env.ASDF_DATA_DIR = path.join(dir, "asdf-data");
  return {
    dir,
    home,
    project,
    bin,
    sysbin,
    dispose() {
      for (const [key, value] of saved) {
        if (value === undefined) {
          delete process.env[key];
        } else {
          process.env[key] = value;
        }
      }
      fs.rmSync(dir, { recursive: true, force: true });
    },
  };
}

/** Write `contents` to `file`, creating its directory. */
export function write(file: string, contents = ""): string {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, contents);
  return file;
}

/** An executable shell script. */
export function script(file: string, body: string): string {
  write(file, `#!/bin/sh\n${body}\n`);
  fs.chmodSync(file, 0o755);
  return file;
}

/** A fake `rigor` that prints `rigor <version>` for any arguments. */
export function fakeRigor(file: string, version: string): string {
  return script(file, `echo "rigor ${version}"`);
}

/** A Bundler lockfile pinning rigortype at `version`. */
export function lockfile(version: string): string {
  return [
    "GEM",
    "  remote: https://rubygems.org/",
    "  specs:",
    `    rigortype (${version})`,
    "",
    "PLATFORMS",
    "  ruby",
    "",
  ].join("\n");
}

/** Collects what a module writes to an `OutputChannel`. */
export function fakeOutput(): { lines: string[]; appendLine(s: string): void } {
  const lines: string[] = [];
  return { lines, appendLine: (s: string) => void lines.push(s) };
}

/** Run `fn` with `process.platform` reading as `platform`. */
export async function withPlatform<T>(platform: NodeJS.Platform, fn: () => T | Promise<T>): Promise<T> {
  const original = Object.getOwnPropertyDescriptor(process, "platform")!;
  Object.defineProperty(process, "platform", { value: platform });
  try {
    return await fn();
  } finally {
    Object.defineProperty(process, "platform", original);
  }
}

/** The slice of `ExtensionContext` `initRuntime` and `registerCommands` read. */
export function fakeContext(storageDir: string, mode: number): import("vscode").ExtensionContext {
  const state = new Map<string, unknown>();
  const context = {
    globalStorageUri: { fsPath: storageDir },
    extensionMode: mode,
    subscriptions: [] as unknown[],
    globalState: {
      get: (key: string, fallback?: unknown) => (state.has(key) ? state.get(key) : fallback),
      update: (key: string, value: unknown) => {
        state.set(key, value);
        return Promise.resolve();
      },
    },
  };
  return context as unknown as import("vscode").ExtensionContext;
}

/** Poll until `check()` holds, or fail after `ms`. */
export async function waitFor(check: () => boolean, what: string, ms = 5000): Promise<void> {
  const until = Date.now() + ms;
  while (!check()) {
    if (Date.now() > until) {
      throw new Error(`timed out waiting for ${what}`);
    }
    await new Promise((r) => setTimeout(r, 20));
  }
}
