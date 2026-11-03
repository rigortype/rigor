// Status bar item reflecting the language server lifecycle. Since the
// server otherwise works silently, this is the primary "is it alive?"
// affordance; clicking it opens the output channel.
//
// The extension runs one server per Rigor-configured folder, so the item
// shows the aggregate state and its tooltip lists every folder: which
// `rigor` it runs, found how, and at which version.

import {
  MarkdownString,
  StatusBarAlignment,
  StatusBarItem,
  ThemeColor,
  window,
} from "vscode";
import { DiscoveryKind } from "./discovery";

export type ServerState = "starting" | "running" | "stopped" | "error";

export interface FolderStatus {
  /** Workspace folder name, plus the root directory when it differs. */
  label: string;
  state: ServerState;
  /** `rigortype` version reported by the startup probe. */
  version?: string;
  kind?: DiscoveryKind;
  /** The command line the server was spawned with. */
  commandLine?: string;
}

export class StatusBar {
  private readonly item: StatusBarItem;
  private readonly folders = new Map<string, FolderStatus>();

  constructor() {
    this.item = window.createStatusBarItem(StatusBarAlignment.Left, 0);
    this.item.command = "rigor.showOutputChannel";
    this.render();
    this.item.show();
  }

  /** Record (or replace) the status of one folder's server. */
  update(key: string, status: FolderStatus): void {
    this.folders.set(key, status);
    this.render();
  }

  /** Forget a folder whose server is no longer managed. */
  remove(key: string): void {
    this.folders.delete(key);
    this.render();
  }

  /** Forget every folder. */
  clear(): void {
    this.folders.clear();
    this.render();
  }

  /** Keys of every tracked folder. */
  keys(): string[] {
    return [...this.folders.keys()];
  }

  /** Every folder's status, in insertion order. */
  entries(): FolderStatus[] {
    return [...this.folders.values()];
  }

  dispose(): void {
    this.item.dispose();
  }

  private aggregate(): ServerState {
    const states = this.entries().map((f) => f.state);
    if (states.includes("error")) {
      return "error";
    }
    if (states.includes("starting")) {
      return "starting";
    }
    if (states.includes("running")) {
      return "running";
    }
    return "stopped";
  }

  private render(): void {
    const state = this.aggregate();
    this.item.backgroundColor =
      state === "error"
        ? new ThemeColor("statusBarItem.errorBackground")
        : undefined;
    switch (state) {
      case "starting":
        this.item.text = "$(sync~spin) Rigor";
        break;
      case "running":
        this.item.text = "$(check) Rigor";
        break;
      case "stopped":
        this.item.text = "$(circle-slash) Rigor";
        break;
      case "error":
        this.item.text = "$(error) Rigor";
        break;
    }
    this.item.tooltip = this.tooltip(state);
  }

  private tooltip(state: ServerState): MarkdownString {
    const md = new MarkdownString();
    const folders = this.entries();
    if (folders.length === 0) {
      md.appendText("Rigor language server: stopped");
      return md;
    }
    md.appendText(`Rigor language server: ${state}\n\n`);
    for (const folder of folders) {
      md.appendMarkdown(`- ${escapeMarkdown(describeFolder(folder))}`);
      if (folder.commandLine) {
        md.appendMarkdown("  \n  ");
        md.appendText(folder.commandLine);
      }
      md.appendMarkdown("\n");
    }
    if (state === "error") {
      md.appendText("\nClick to view the output.");
    }
    return md;
  }
}

/** One-line summary: `api: running · rigortype 0.4.7 · version-manager`. */
export function describeFolder(folder: FolderStatus): string {
  const details = [
    folder.state,
    folder.version ? `rigortype ${folder.version}` : undefined,
    folder.kind,
  ].filter((d): d is string => d !== undefined);
  return `${folder.label}: ${details.join(" · ")}`;
}

function escapeMarkdown(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/[\\`*_{}[\]()#+\-.!|<>]/g, "\\$&");
}
