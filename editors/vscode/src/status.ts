// Status bar item reflecting the language server lifecycle. Since the
// server otherwise works silently, this is the primary "is it alive?"
// affordance; clicking it opens the output channel.

import { StatusBarAlignment, StatusBarItem, ThemeColor, window } from "vscode";

export type ServerState = "starting" | "running" | "stopped" | "error";

export class StatusBar {
  private readonly item: StatusBarItem;

  constructor() {
    this.item = window.createStatusBarItem(StatusBarAlignment.Left, 0);
    this.item.command = "rigor.showOutputChannel";
    this.set("stopped");
    this.item.show();
  }

  set(state: ServerState): void {
    const errorBg = new ThemeColor("statusBarItem.errorBackground");
    switch (state) {
      case "starting":
        this.item.text = "$(sync~spin) Rigor";
        this.item.tooltip = "Rigor language server: starting…";
        this.item.backgroundColor = undefined;
        break;
      case "running":
        this.item.text = "$(check) Rigor";
        this.item.tooltip = "Rigor language server: running";
        this.item.backgroundColor = undefined;
        break;
      case "stopped":
        this.item.text = "$(circle-slash) Rigor";
        this.item.tooltip = "Rigor language server: stopped";
        this.item.backgroundColor = undefined;
        break;
      case "error":
        this.item.text = "$(error) Rigor";
        this.item.tooltip =
          "Rigor language server: error — click to view the output";
        this.item.backgroundColor = errorBg;
        break;
    }
  }

  dispose(): void {
    this.item.dispose();
  }
}
