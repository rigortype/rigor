// Parsing `rigor check` text output, one line at a time. Pure: no `vscode`
// import, so the unit tests run it directly. The pattern is the `$rigor`
// problem matcher's (package.json), which a test holds equal.

import * as path from "path";

/** `PATH:LINE:COL: SEVERITY: MESSAGE [RULE]`; the trailing rule is optional. */
export const CHECK_LINE_PATTERN =
  "^(.+?):(\\d+):(\\d+): (error|warning|info): (.*?)(?: \\[([^\\[\\]\\s]+)\\])?$";

const CHECK_LINE = new RegExp(CHECK_LINE_PATTERN);

export type CheckSeverity = "error" | "warning" | "info";

export interface CheckFinding {
  /** Absolute path (a relative one is resolved against the project root). */
  file: string;
  /** 0-based. */
  line: number;
  /** 0-based. */
  column: number;
  severity: CheckSeverity;
  message: string;
  rule?: string;
}

/** Absolute in either path flavour: output may carry `C:\` paths on any host. */
function isAbsolute(file: string): boolean {
  return path.posix.isAbsolute(file) || path.win32.isAbsolute(file);
}

/**
 * The finding on one output line, or undefined for anything else (summary
 * and statistics lines, the CLI's own stderr). A trailing `\r` is ignored.
 */
export function parseCheckLine(rawLine: string, root: string): CheckFinding | undefined {
  const m = CHECK_LINE.exec(rawLine.replace(/\r$/, ""));
  if (!m) {
    return undefined;
  }
  const file = isAbsolute(m[1]) ? m[1] : path.resolve(root, m[1]);
  return {
    file,
    line: Math.max(0, Number(m[2]) - 1),
    column: Math.max(0, Number(m[3]) - 1),
    severity: m[4] as CheckSeverity,
    message: m[5],
    rule: m[6],
  };
}

/** Splits a chunked stream into lines; `flush` returns the unterminated tail. */
export class LineSplitter {
  private tail = "";

  push(chunk: string): string[] {
    const parts = (this.tail + chunk).split("\n");
    this.tail = parts.pop() ?? "";
    return parts;
  }

  flush(): string[] {
    const rest = this.tail;
    this.tail = "";
    return rest === "" ? [] : [rest];
  }
}
