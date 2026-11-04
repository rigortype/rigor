// A minimal stand-in for the `vscode` module, for the unit tests only
// (`test/build.js` aliases `vscode` to this file). It carries just what the
// modules under test touch: a settable configuration, recorded messages and
// the few value classes. Anything else is deliberately absent, so a module
// that starts using a new API fails loudly here instead of silently.

import * as path from "path";

export const stub = {
  /** `"rigor.server.path"` -> value; every folder and scope reads the same map. */
  config: new Map<string, unknown>(),
  trusted: true,
  folders: [] as WorkspaceFolder[],
  /** Every `show*Message`, in order. */
  messages: [] as { level: "info" | "warning" | "error"; text: string }[],
  reset(): void {
    this.config.clear();
    this.trusted = true;
    this.folders = [];
    this.messages = [];
  },
  set(key: string, value: unknown): void {
    this.config.set(key, value);
  },
  warnings(): string[] {
    return this.messages.filter((m) => m.level === "warning").map((m) => m.text);
  },
};

export class Uri {
  private constructor(
    readonly scheme: string,
    readonly fsPath: string,
    readonly query: string,
  ) {}
  static file(p: string): Uri {
    return new Uri("file", p, "");
  }
  static from(parts: { scheme: string; path?: string; query?: string }): Uri {
    return new Uri(parts.scheme, parts.path ?? "", parts.query ?? "");
  }
  get path(): string {
    return this.fsPath;
  }
  toString(): string {
    return `${this.scheme}://${this.fsPath}${this.query ? `?${this.query}` : ""}`;
  }
}

export interface WorkspaceFolder {
  uri: Uri;
  name: string;
  index: number;
}

/** A workspace folder at `dir`, registered with the stub. */
export function addFolder(dir: string): import("vscode").WorkspaceFolder {
  const folder = { uri: Uri.file(dir), name: path.basename(dir), index: stub.folders.length };
  stub.folders.push(folder);
  return folder as unknown as import("vscode").WorkspaceFolder;
}

export class RelativePattern {
  constructor(
    readonly base: unknown,
    readonly pattern: string,
  ) {}
}

type Listener<T> = (e: T) => unknown;

export class EventEmitter<T> {
  private listeners: Listener<T>[] = [];
  readonly event = (listener: Listener<T>): { dispose(): void } => {
    this.listeners.push(listener);
    return { dispose: () => (this.listeners = this.listeners.filter((l) => l !== listener)) };
  };
  fire(e: T): void {
    for (const l of this.listeners) {
      l(e);
    }
  }
  dispose(): void {
    this.listeners = [];
  }
}

export class Disposable {
  constructor(private readonly fn: () => void) {}
  dispose(): void {
    this.fn();
  }
}

export enum ExtensionMode {
  Production = 1,
  Development = 2,
  Test = 3,
}

export enum ProgressLocation {
  Notification = 15,
}

export enum ViewColumn {
  Beside = -2,
}

export const CodeActionKind = { QuickFix: "quickfix" };

export class CodeAction {
  diagnostics?: unknown[];
  command?: { command: string; title: string; arguments?: unknown[] };
  constructor(
    readonly title: string,
    readonly kind?: string,
  ) {}
}

export const workspace = {
  get isTrusted(): boolean {
    return stub.trusted;
  },
  get workspaceFolders(): WorkspaceFolder[] {
    return stub.folders;
  },
  getWorkspaceFolder(uri: Uri): WorkspaceFolder | undefined {
    return stub.folders.find((f) => {
      const rel = path.relative(f.uri.fsPath, uri.fsPath);
      return rel !== ".." && !rel.startsWith(`..${path.sep}`) && !path.isAbsolute(rel);
    });
  },
  getConfiguration(section: string, _scope?: unknown) {
    return {
      get<T>(key: string, fallback?: T): T | undefined {
        const full = `${section}.${key}`;
        return (stub.config.has(full) ? stub.config.get(full) : fallback) as T | undefined;
      },
    };
  },
  registerTextDocumentContentProvider: () => new Disposable(() => {}),
  onDidCloseTextDocument: () => new Disposable(() => {}),
};

function message(level: "info" | "warning" | "error") {
  return (text: string): Promise<undefined> => {
    stub.messages.push({ level, text });
    return Promise.resolve(undefined);
  };
}

export const window = {
  activeTextEditor: undefined as unknown,
  showInformationMessage: message("info"),
  showWarningMessage: message("warning"),
  showErrorMessage: message("error"),
  withProgress<T>(
    _options: unknown,
    task: (progress: unknown, token: unknown) => Promise<T>,
  ): Promise<T> {
    return task({ report() {} }, { isCancellationRequested: false, onCancellationRequested: () => undefined });
  },
};

export const commands = {
  registerCommand: () => new Disposable(() => {}),
  executeCommand: () => Promise.resolve(undefined),
};

/** Providers handed to `registerCodeActionsProvider`, newest last. */
export const registeredCodeActionProviders: unknown[] = [];

export const languages = {
  registerCodeActionsProvider(_selector: unknown, provider: unknown): Disposable {
    registeredCodeActionProviders.push(provider);
    return new Disposable(() => {});
  },
};
