// The Problems-panel results of `rigor check`, kept per workspace folder.
//
// A contributed problem matcher has one static owner, so two folders' tasks
// would replace each other's problems. The task therefore parses the output
// itself and publishes into one collection through this index: a folder's run
// replaces only that folder's earlier files, and a file two folders report
// (nested roots) shows both folders' findings.

import {
  Diagnostic,
  DiagnosticCollection,
  DiagnosticSeverity,
  Range,
  Uri,
  languages,
} from "vscode";
import { CheckFinding } from "./checkOutput";

export const CHECK_SOURCE = "rigor check";

/** Where the merged diagnostics land; `DiagnosticCollection` fits via `collectionSink`. */
export interface Sink<D> {
  set(file: string, diagnostics: D[]): void;
  delete(file: string): void;
}

export class CheckResults<D> {
  private readonly byFolder = new Map<string, Map<string, D[]>>();

  constructor(private readonly sink: Sink<D>) {}

  /** Replace folder's results with `entries` (file -> its findings). */
  replace(folder: string, entries: Map<string, D[]>): void {
    const touched = new Set<string>(this.byFolder.get(folder)?.keys());
    for (const file of entries.keys()) {
      touched.add(file);
    }
    if (entries.size === 0) {
      this.byFolder.delete(folder);
    } else {
      this.byFolder.set(folder, entries);
    }
    this.publish(touched);
  }

  clear(folder: string): void {
    this.replace(folder, new Map());
  }

  clearAll(): void {
    for (const folder of [...this.byFolder.keys()]) {
      this.clear(folder);
    }
  }

  /** Folders that currently hold results. */
  folders(): string[] {
    return [...this.byFolder.keys()];
  }

  private publish(files: Iterable<string>): void {
    for (const file of files) {
      const merged: D[] = [];
      for (const entries of this.byFolder.values()) {
        merged.push(...(entries.get(file) ?? []));
      }
      if (merged.length === 0) {
        this.sink.delete(file);
      } else {
        this.sink.set(file, merged);
      }
    }
  }
}

const SEVERITY: Record<CheckFinding["severity"], DiagnosticSeverity> = {
  error: DiagnosticSeverity.Error,
  warning: DiagnosticSeverity.Warning,
  info: DiagnosticSeverity.Information,
};

export function toDiagnostic(finding: CheckFinding): Diagnostic {
  const range = new Range(finding.line, finding.column, finding.line, finding.column);
  const diagnostic = new Diagnostic(range, finding.message, SEVERITY[finding.severity]);
  diagnostic.source = CHECK_SOURCE;
  if (finding.rule !== undefined) {
    diagnostic.code = finding.rule;
  }
  return diagnostic;
}

/** Group findings by file, as diagnostics. */
export function groupFindings(findings: CheckFinding[]): Map<string, Diagnostic[]> {
  const out = new Map<string, Diagnostic[]>();
  for (const finding of findings) {
    const list = out.get(finding.file) ?? [];
    list.push(toDiagnostic(finding));
    out.set(finding.file, list);
  }
  return out;
}

export function collectionSink(collection: DiagnosticCollection): Sink<Diagnostic> {
  return {
    set: (file, diagnostics) => collection.set(Uri.file(file), diagnostics),
    delete: (file) => collection.delete(Uri.file(file)),
  };
}

export function createCheckCollection(): DiagnosticCollection {
  return languages.createDiagnosticCollection("rigor check");
}
