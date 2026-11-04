// CLI-backed commands for the open file. Each one runs the same `rigor`
// executable the language server uses (same discovery, same project root,
// same `--config`) when the user asks, and shows the result. Nothing they
// learn is fed back into the language server.

import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import {
  CancellationToken,
  CodeAction,
  CodeActionKind,
  CodeActionProvider,
  Diagnostic,
  Disposable,
  Event,
  EventEmitter,
  ExtensionContext,
  ExtensionMode,
  OutputChannel,
  ProgressLocation,
  TextDocument,
  TextDocumentContentProvider,
  Uri,
  ViewColumn,
  WorkspaceFolder,
  commands,
  languages,
  window,
  workspace,
} from "vscode";
import {
  displayCommand,
  projectRoot,
  shouldManageFolder,
  useShell,
} from "./discovery";
import { describeCandidate, resolveRigor } from "./resolve";
import { killTree, spawnCli } from "./proc";

export const OUTPUT_SCHEME = "rigor-output";

/**
 * Internal argument of the commands that ask before writing. The Extension
 * Development Host test runner cannot click a modal, so it passes
 * `{ confirmed: true }`. It is honoured only outside Production mode
 * (`allowUnconfirmed`), so no other extension can skip the confirmation in
 * an installed copy; the palette never passes it.
 */
export interface CommandOptions {
  confirmed?: boolean;
}

interface CliResult {
  code: number | null;
  stdout: string;
  stderr: string;
  cancelled: boolean;
}

/** Content of the read-only virtual documents, keyed by URI string. */
class OutputProvider implements TextDocumentContentProvider {
  private readonly contents = new Map<string, string>();
  private readonly emitter = new EventEmitter<Uri>();
  private counter = 0;
  readonly onDidChange: Event<Uri> = this.emitter.event;

  provideTextDocumentContent(uri: Uri): string {
    return this.contents.get(uri.toString()) ?? "";
  }

  /** Register `text` under a fresh URI whose path ends in `title`. */
  add(title: string, text: string): Uri {
    this.counter += 1;
    const uri = Uri.from({
      scheme: OUTPUT_SCHEME,
      path: `/${title}`,
      query: String(this.counter),
    });
    this.contents.set(uri.toString(), text);
    return uri;
  }

  forget(uri: Uri): void {
    this.contents.delete(uri.toString());
  }
}

let out: OutputChannel;
let provider: OutputProvider;
let allowUnconfirmed = false;
/**
 * Rule ids `rigor explain` knows, per project root. `null` is a failed load,
 * kept until `clearRuleCache()` so a broken environment is not re-run on
 * every lightbulb request.
 */
const ruleCache = new Map<string, Set<string> | null>();
/** One in-flight quiet load per root. */
const ruleLoads = new Map<string, Promise<unknown>>();
/**
 * Bumped by `clearRuleCache()`. A load started under an older generation
 * neither writes its result into the cache nor clears a newer load's slot.
 */
let ruleGeneration = 0;

/** Forget the cached rule lists (the gem may have changed on restart). */
export function clearRuleCache(): void {
  ruleCache.clear();
  ruleLoads.clear();
  ruleGeneration++;
}

function confirmedBy(options?: CommandOptions): boolean {
  return allowUnconfirmed && options?.confirmed === true;
}

export function registerCommands(
  context: ExtensionContext,
  channel: OutputChannel,
): void {
  out = channel;
  allowUnconfirmed = context.extensionMode !== ExtensionMode.Production;
  provider = new OutputProvider();
  context.subscriptions.push(
    workspace.registerTextDocumentContentProvider(OUTPUT_SCHEME, provider),
    workspace.onDidCloseTextDocument((doc) => {
      if (doc.uri.scheme === OUTPUT_SCHEME) {
        provider.forget(doc.uri);
      }
    }),
    commands.registerCommand("rigor.showTypeAtCursor", () => showTypeAtCursor()),
    commands.registerCommand("rigor.explainRule", (rule?: unknown) =>
      explainRule(typeof rule === "string" ? rule : undefined),
    ),
    commands.registerCommand("rigor.openConfig", (o?: CommandOptions) =>
      openConfig(o),
    ),
    commands.registerCommand("rigor.generateSignatures", (o?: CommandOptions) =>
      generateSignatures(o),
    ),
    commands.registerCommand("rigor.updateBaseline", (o?: CommandOptions) =>
      updateBaseline(o),
    ),
    languages.registerCodeActionsProvider(
      { language: "ruby" },
      new ExplainActions(),
      { providedCodeActionKinds: [CodeActionKind.QuickFix] },
    ),
  );
}

// ---- folder selection ----------------------------------------------------

/** Refuse in an untrusted workspace. */
function trusted(): boolean {
  if (workspace.isTrusted) {
    return true;
  }
  void window.showWarningMessage(
    "Rigor: this command runs the `rigor` executable from the workspace, " +
      "which is withheld in an untrusted workspace. Trust the workspace first.",
  );
  return false;
}

/** The managed folder (and its project root) that holds `uri`, if any. */
function folderOf(uri: Uri): { folder: WorkspaceFolder; root: string } | undefined {
  const folder = workspace.getWorkspaceFolder(uri);
  if (!folder || !shouldManageFolder(folder)) {
    return undefined;
  }
  const root = projectRoot(folder);
  if (!root) {
    return undefined;
  }
  const rel = path.relative(root, uri.fsPath);
  if (rel === ".." || rel.startsWith(`..${path.sep}`) || path.isAbsolute(rel)) {
    return undefined;
  }
  return { folder, root };
}

/** The active file's folder, else the only managed folder, else ask. */
async function pickFolder(): Promise<
  { folder: WorkspaceFolder; root: string } | undefined
> {
  const active = window.activeTextEditor?.document;
  if (active && active.uri.scheme === "file") {
    const hit = folderOf(active.uri);
    if (hit) {
      return hit;
    }
  }
  const managed = (workspace.workspaceFolders ?? [])
    .filter((f) => shouldManageFolder(f))
    .map((folder) => ({ folder, root: projectRoot(folder) ?? folder.uri.fsPath }));
  if (managed.length <= 1) {
    if (managed.length === 0) {
      void window.showInformationMessage("Rigor: no workspace folder is managed.");
    }
    return managed[0];
  }
  const choice = await window.showQuickPick(
    managed.map((m) => ({ label: m.folder.name, description: m.root, m })),
    { placeHolder: "Rigor project" },
  );
  return choice?.m;
}

/** The active Ruby file under a managed project root, or a message. */
function activeFile():
  | { document: TextDocument; folder: WorkspaceFolder; root: string }
  | undefined {
  const document = window.activeTextEditor?.document;
  if (!document || document.uri.scheme !== "file") {
    void window.showInformationMessage("Rigor: open a Ruby file first.");
    return undefined;
  }
  const hit = folderOf(document.uri);
  if (!hit) {
    void window.showInformationMessage(
      "Rigor: this file is not under a folder managed by Rigor.",
    );
    return undefined;
  }
  return { document, ...hit };
}

// ---- running the CLI -----------------------------------------------------

/** Config flag for the subcommands that accept it. */
function configArgs(folder: WorkspaceFolder): string[] {
  const configPath = (
    workspace.getConfiguration("rigor", folder.uri).get<string>("server.configPath") ?? ""
  ).trim();
  return configPath ? [`--config=${configPath}`] : [];
}

async function runRigor(
  folder: WorkspaceFolder,
  root: string,
  subArgs: string[],
  token?: CancellationToken,
): Promise<CliResult> {
  // The same resolution as the language server's (#2748).
  const { server, probe, rejected } = await resolveRigor(folder, out);
  if (token?.isCancellationRequested) {
    return { code: null, stdout: "", stderr: "", cancelled: true };
  }
  if (!probe.ok && !probe.tooOld) {
    const tried = rejected
      .map((r) => `${describeCandidate(r.server)}: ${r.reason}`)
      .join("; ");
    const stderr = `could not run Rigor in ${folder.name}${tried ? ` (tried ${tried})` : ": no \`rigor\` was found"}; fix the setup, then run "Rigor: Restart Server"\n`;
    out.appendLine(`[rigor] ${stderr.trimEnd()}`);
    return { code: null, stdout: "", stderr, cancelled: false };
  }
  const args = [...server.prefixArgs, ...subArgs];
  out.appendLine(`[rigor] $ ${displayCommand(server, args)}  (cwd ${root})`);
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let cancelled = false;
    let settled = false;
    const finish = (code: number | null): void => {
      if (settled) {
        return;
      }
      settled = true;
      sub?.dispose();
      if (stdout) {
        out.appendLine(stdout.replace(/\n$/, ""));
      }
      if (stderr) {
        out.appendLine(stderr.replace(/\n$/, ""));
      }
      resolve({ code, stdout, stderr, cancelled });
    };
    const child = spawnCli(server.command, args, root, {
      shell: useShell(server),
      env: server.env,
    });
    const sub: Disposable | undefined = token?.onCancellationRequested(() => {
      cancelled = true;
      killTree(child);
    });
    child.stdout?.on("data", (d: Buffer) => (stdout += d.toString()));
    child.stderr?.on("data", (d: Buffer) => (stderr += d.toString()));
    child.on("error", (err) => {
      stderr += `${String(err)}\n`;
      finish(null);
    });
    child.on("close", (code) => finish(code));
  });
}

/** Run with a cancellable progress notification. */
function runWithProgress(
  title: string,
  folder: WorkspaceFolder,
  root: string,
  subArgs: string[],
): Promise<CliResult> {
  return Promise.resolve(
    window.withProgress(
      { location: ProgressLocation.Notification, title, cancellable: true },
      (_progress, token) => runRigor(folder, root, subArgs, token),
    ),
  );
}

/** Report a failed run; true when the caller should stop. */
function failed(what: string, r: CliResult, okCodes: number[] = [0]): boolean {
  if (r.cancelled) {
    void window.showInformationMessage(`Rigor: ${what} was cancelled.`);
    return true;
  }
  if (r.code === null || !okCodes.includes(r.code)) {
    const detail = firstLine(r.stderr) || firstLine(r.stdout) || `exit ${r.code}`;
    void window
      .showErrorMessage(`Rigor: ${what} failed — ${detail}`, "Show Output")
      .then((c) => c && out.show());
    return true;
  }
  return false;
}

function firstLine(text: string): string {
  return (
    text
      .split("\n")
      .map((l) => l.trim())
      .find((l) => l !== "" && !l.startsWith("Ignoring ")) ?? ""
  );
}

/** A relative path as a CLI argument: never mistaken for an option. */
function pathArg(rel: string): string {
  return rel.startsWith("-") ? `./${rel}` : rel;
}

/** Whether the CLI can analyse this document (plain Ruby). */
function isRuby(document: TextDocument, what: string): boolean {
  if (document.languageId === "ruby") {
    return true;
  }
  void window.showInformationMessage(
    `Rigor: ${what} works on Ruby files; this one is ${document.languageId}.`,
  );
  return false;
}

/** Drop the rubygems "Ignoring … extensions are not built" noise, and the
 * type-of JSON schema-change notice (the shape is handled defensively). */
function cleanStderr(text: string): string {
  return text
    .split("\n")
    .filter((l) => !l.startsWith("Ignoring ") && !/schema_version/.test(l))
    .join("\n")
    .trim();
}

async function showVirtual(
  title: string,
  text: string,
  languageId?: string,
): Promise<TextDocument> {
  const uri = provider.add(title, text);
  let doc = await workspace.openTextDocument(uri);
  if (languageId) {
    doc = await languages.setTextDocumentLanguage(doc, languageId);
  }
  await window.showTextDocument(doc, {
    viewColumn: ViewColumn.Beside,
    preserveFocus: true,
    preview: true,
  });
  return doc;
}

// ---- Show Type at Cursor -------------------------------------------------

async function showTypeAtCursor(): Promise<void> {
  if (!trusted()) {
    return;
  }
  const active = activeFile();
  const editor = window.activeTextEditor;
  if (!active || !editor) {
    return;
  }
  const { document, folder, root } = active;
  if (!isRuby(document, "Show Type at Cursor")) {
    return;
  }
  const pos = editor.selection.active;
  // The CLI counts 1-based BYTE columns; VS Code counts UTF-16 units.
  const prefix = document.lineAt(pos.line).text.slice(0, pos.character);
  const column = Buffer.byteLength(prefix, "utf8") + 1;
  const line = pos.line + 1;
  const rel = path.relative(root, document.uri.fsPath);

  let tmpDir: string | undefined;
  const extra: string[] = [];
  if (document.isDirty) {
    // Probe the buffer, not the stale file on disk. A private directory and
    // a 0600 file: the buffer may hold anything.
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "rigor-"));
    const tmp = path.join(tmpDir, "buffer.rb");
    fs.writeFileSync(tmp, document.getText(), { mode: 0o600 });
    extra.push(`--tmp-file=${tmp}`, `--instead-of=${pathArg(rel)}`);
  }
  try {
    const r = await runWithProgress("Rigor: type at cursor", folder, root, [
      "type-of",
      "--format=json",
      ...configArgs(folder),
      ...extra,
      `${pathArg(rel)}:${line}:${column}`,
    ]);
    // Exit 1 = no expression at the position; its stdout/stderr says why.
    if (failed("type-of", r, [0, 1])) {
      return;
    }
    const text = renderTypeOf(r, `${rel}:${line}:${column}`);
    await showVirtual(`type-of ${path.basename(rel)}:${line}:${column}`, text);
  } finally {
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  }
}

/**
 * Render `type-of --format=json`. The shape is not stable (a flat object
 * today, `{ results: [...] }` after the next minor), so read what is there
 * and fall back to the raw text for anything else.
 */
export function renderTypeOf(r: CliResult, where: string): string {
  const stderr = cleanStderr(r.stderr);
  let parsed: unknown;
  try {
    parsed = JSON.parse(r.stdout);
  } catch {
    parsed = undefined;
  }
  const results: unknown[] = Array.isArray(parsed)
    ? parsed
    : isRecord(parsed) && Array.isArray(parsed.results)
      ? parsed.results
      : parsed !== undefined
        ? [parsed]
        : [];
  const lines: string[] = [`Rigor type at ${where}`, ""];
  let understood = false;
  for (const item of results) {
    if (isRecord(item) && typeof item.type === "string") {
      understood = true;
      lines.push(`type:    ${item.type}`);
      if (typeof item.erased === "string") {
        lines.push(`erased:  ${item.erased}`);
      }
      if (typeof item.node === "string") {
        lines.push(`node:    ${item.node}`);
      }
      for (const [k, v] of Object.entries(item)) {
        if (["type", "erased", "node", "file", "line", "column"].includes(k)) {
          continue;
        }
        lines.push(`${k}: ${typeof v === "string" ? v : JSON.stringify(v)}`);
      }
      lines.push("");
    }
  }
  if (!understood) {
    lines.push((r.stdout.trim() || "(no output)"));
  }
  if (stderr) {
    lines.push("", stderr);
  }
  return `${lines.join("\n").trimEnd()}\n`;
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

// ---- Explain Rule ----------------------------------------------------------

/** Rules `rigor explain` lists for a project root (cached per root). */
async function loadRules(
  folder: WorkspaceFolder,
  root: string,
  quiet = false,
): Promise<{ id: string; summary: string }[] | undefined> {
  const args = ["explain", "--format=json"];
  const generation = ruleGeneration;
  // A quiet load backs the lightbulb: no progress toast.
  const list = quiet
    ? await runRigor(folder, root, args)
    : await runWithProgress("Rigor: listing rules", folder, root, args);
  // A load that a restart overtook must not refill the cache from the old gem.
  const current = generation === ruleGeneration;
  // Only the lightbulb's quiet load caches a failure, and only over an empty
  // slot: a palette failure or a late failure never wipes a good Set.
  const cacheFailure = (why: string): void => {
    if (quiet && current && ruleCache.get(root) === undefined) {
      ruleCache.set(root, null);
      out.appendLine(
        `[rigor] explain rule list unavailable (${why}); lightbulb explain actions are off until Restart Server.`,
      );
    }
  };
  if (quiet && list.code !== 0) {
    cacheFailure(`exit ${list.code}`);
    return undefined;
  }
  if (!quiet && failed("explain", list)) {
    return undefined;
  }
  const rules = parseRuleList(list.stdout);
  if (rules === undefined) {
    // Exit 0 with no rules array is a failure, not an empty rule set.
    if (quiet) {
      cacheFailure("output is not a rule list");
    } else {
      void window.showErrorMessage("Rigor: `rigor explain --format=json` did not return a rule list.");
    }
    return undefined;
  }
  if (current) {
    ruleCache.set(root, new Set(rules.map((r) => r.id)));
  }
  return rules;
}

async function explainRule(rule?: string): Promise<void> {
  if (!trusted()) {
    return;
  }
  const hit = await pickFolder();
  if (!hit) {
    return;
  }
  const { folder, root } = hit;
  let chosen = rule;
  if (!chosen) {
    const items = await loadRules(folder, root);
    if (!items) {
      return;
    }
    if (items.length === 0) {
      void window.showWarningMessage("Rigor: `rigor explain` listed no rules.");
      return;
    }
    const pick = await window.showQuickPick(
      items.map((i) => ({ label: i.id, description: i.summary })),
      { placeHolder: "Explain which rule?", matchOnDescription: true },
    );
    chosen = pick?.label;
  }
  if (!chosen) {
    return;
  }
  const r = await runWithProgress(`Rigor: explain ${chosen}`, folder, root, [
    "explain",
    chosen,
  ]);
  if (failed(`explain ${chosen}`, r)) {
    return;
  }
  await showVirtual(`explain ${chosen}`, r.stdout);
}

/**
 * Rules from `explain --format=json`: an array now, `{ rules }` later.
 * `undefined` when the output is not JSON or has no rules array, so a broken
 * run is not mistaken for an empty rule set.
 */
export function parseRuleList(
  stdout: string,
): { id: string; summary: string }[] | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    return undefined;
  }
  const rows: unknown[] | undefined = Array.isArray(parsed)
    ? parsed
    : isRecord(parsed) && Array.isArray(parsed.rules)
      ? parsed.rules
      : undefined;
  if (rows === undefined) {
    return undefined;
  }
  const rules: { id: string; summary: string }[] = [];
  for (const row of rows) {
    if (isRecord(row) && typeof row.id === "string") {
      rules.push({
        id: row.id,
        summary: typeof row.summary === "string" ? row.summary : "",
      });
    }
  }
  return rules;
}

class ExplainActions implements CodeActionProvider {
  provideCodeActions(
    document: TextDocument,
    _range: unknown,
    context: { diagnostics: readonly Diagnostic[] },
    token: CancellationToken,
  ): CodeAction[] {
    const hit = document.uri.scheme === "file" ? folderOf(document.uri) : undefined;
    if (!hit || !workspace.isTrusted) {
      return [];
    }
    // Only ids `rigor explain` knows: a plugin rule is not explainable, and
    // its bare id could collide with a core one.
    const known = ruleCache.get(hit.root);
    if (known === null) {
      // The load failed; that failure is cached until clearRuleCache().
      return [];
    }
    if (!known) {
      // Do not block the lightbulb on a CLI boot: fill the cache in the
      // background (one load per root) and offer the action from the next
      // request on.
      if (
        !token.isCancellationRequested &&
        !ruleLoads.has(hit.root) &&
        context.diagnostics.some((d) => d.source === "rigor")
      ) {
        const load: Promise<unknown> = loadRules(hit.folder, hit.root, true).finally(
          () => {
            // Only the slot this load owns: a restart may have replaced it.
            if (ruleLoads.get(hit.root) === load) {
              ruleLoads.delete(hit.root);
            }
          },
        );
        ruleLoads.set(hit.root, load);
      }
      return [];
    }
    if (token.isCancellationRequested) {
      return [];
    }
    const seen = new Set<string>();
    const actions: CodeAction[] = [];
    for (const d of context.diagnostics) {
      const code =
        typeof d.code === "object" && d.code !== null ? d.code.value : d.code;
      if (d.source !== "rigor" || code === undefined || code === "") {
        continue;
      }
      const rule = String(code);
      if (seen.has(rule) || !known.has(rule)) {
        continue;
      }
      seen.add(rule);
      const action = new CodeAction(`Explain ${rule}`, CodeActionKind.QuickFix);
      action.diagnostics = [d];
      action.command = {
        command: "rigor.explainRule",
        title: `Explain ${rule}`,
        arguments: [rule],
      };
      actions.push(action);
    }
    return actions;
  }
}

// ---- Open Config -------------------------------------------------------------

async function openConfig(options?: CommandOptions): Promise<void> {
  if (!trusted()) {
    return;
  }
  const hit = await pickFolder();
  if (!hit) {
    return;
  }
  const { folder, root } = hit;
  const found = findConfig(folder, root);
  if (found) {
    await window.showTextDocument(await workspace.openTextDocument(Uri.file(found)));
    return;
  }
  const configured = configuredPath(folder, root);
  if (configured) {
    void window.showWarningMessage(
      `Rigor: "rigor.server.configPath" points to ${configured}, which does not exist.`,
    );
    return;
  }
  if (!confirmedBy(options)) {
    const choice = await window.showInformationMessage(
      `No .rigor.yml or .rigor.dist.yml in ${root}. Run \`rigor init\` there to create .rigor.dist.yml?`,
      { modal: true },
      "Run rigor init",
    );
    if (choice !== "Run rigor init") {
      return;
    }
  }
  const r = await runWithProgress("Rigor: init", folder, root, ["init"]);
  if (failed("init", r)) {
    return;
  }
  const created = findConfig(folder, root);
  if (created) {
    await window.showTextDocument(await workspace.openTextDocument(Uri.file(created)));
  }
}

function configuredPath(folder: WorkspaceFolder, root: string): string | undefined {
  const p = (
    workspace.getConfiguration("rigor", folder.uri).get<string>("server.configPath") ?? ""
  ).trim();
  return p ? path.resolve(root, p) : undefined;
}

function findConfig(folder: WorkspaceFolder, root: string): string | undefined {
  const configured = configuredPath(folder, root);
  const candidates = configured
    ? [configured]
    : [path.join(root, ".rigor.yml"), path.join(root, ".rigor.dist.yml")];
  return candidates.find((c) => fs.existsSync(c));
}

// ---- Generate Signatures -----------------------------------------------------

async function generateSignatures(options?: CommandOptions): Promise<void> {
  if (!trusted()) {
    return;
  }
  const active = activeFile();
  if (!active) {
    return;
  }
  const { document, folder, root } = active;
  if (!isRuby(document, "Generate Signatures")) {
    return;
  }
  if (document.isDirty) {
    void window.showWarningMessage(
      "Rigor: save the file first. `rigor sig-gen` reads it from disk.",
    );
    return;
  }
  const rel = path.relative(root, document.uri.fsPath);
  const base = ["sig-gen", ...configArgs(folder)];
  // `--diff` prints "No candidates" and exits 0 when there is nothing to
  // write, so the exit status of `--check` (1 = `--write` would change
  // sig/) decides whether to show anything.
  const check = await runWithProgress("Rigor: sig-gen --check", folder, root, [
    ...base,
    "--check",
    pathArg(rel),
  ]);
  let diff: CliResult | undefined;
  if (check.code === 64 && /invalid option: --check/.test(check.stderr)) {
    // `--check` arrived in rigortype 0.4.0. On an older gem, `--diff` itself
    // says "No candidates" (exit 0) when there is nothing to write.
    diff = await runWithProgress("Rigor: sig-gen --diff", folder, root, [
      ...base,
      "--diff",
      pathArg(rel),
    ]);
    if (failed("sig-gen --diff", diff)) {
      return;
    }
    if (diff.stdout.trim() === "" || diff.stdout.trim() === "No candidates") {
      void window.showInformationMessage(
        `Rigor: nothing to write — sig/ already matches ${rel}.`,
      );
      return;
    }
  } else {
    if (failed("sig-gen --check", check, [0, 1])) {
      return;
    }
    if (check.code === 0) {
      void window.showInformationMessage(
        `Rigor: nothing to write — sig/ already matches ${rel}.`,
      );
      return;
    }
    diff = await runWithProgress("Rigor: sig-gen --diff", folder, root, [
      ...base,
      "--diff",
      pathArg(rel),
    ]);
    if (failed("sig-gen --diff", diff)) {
      return;
    }
  }
  await showVirtual(`sig-gen ${path.basename(rel)}.diff`, diff.stdout, "diff");
  if (!confirmedBy(options)) {
    const choice = await window.showWarningMessage(
      `Write the signatures shown in the diff for ${rel} into sig/ ?`,
      { modal: true, detail: "The diff is open beside the editor." },
      "Write",
    );
    if (choice !== "Write") {
      return;
    }
  }
  const w = await runWithProgress("Rigor: sig-gen --write", folder, root, [
    ...base,
    "--write",
    pathArg(rel),
  ]);
  if (failed("sig-gen --write", w)) {
    return;
  }
  void window.showInformationMessage(
    `Rigor: ${firstLine(w.stdout) || "signatures written"}`,
  );
}

// ---- Update Baseline ---------------------------------------------------------

type BaselineLookup =
  | { kind: "file"; rel: string }
  /** `unset`: no `baseline:` key at all (the CLI default is no baseline). */
  | { kind: "off"; unset?: boolean }
  /** The config pulls in other files; which one wins is not guessed here. */
  | { kind: "ambiguous" };

/**
 * The baseline file the top-level `baseline:` of the config names. A missing
 * key means no baseline (the CLI default is nil; a `.rigor-baseline.yml` on
 * disk alone does not activate one). The null and false spellings are the
 * ones Psych reads as nil or false. A config with `includes:` may set the key
 * in an included file (later files override), and a bare `baseline:` followed
 * by an indented line takes that line as its value, so neither is guessed.
 */
function baselineLookup(folder: WorkspaceFolder, root: string): BaselineLookup {
  const cfg = findConfig(folder, root);
  let text = "";
  if (cfg) {
    try {
      text = fs.readFileSync(cfg, "utf8");
    } catch {
      // Unreadable config — treated as no key.
    }
  }
  if (/^includes[ \t]*:(?![ \t]*\[[ \t]*\][ \t]*(?:#.*)?$)/m.test(text)) {
    return { kind: "ambiguous" };
  }
  // A bare `baseline:` whose next non-blank, non-comment line is indented is a
  // block scalar (Psych: `baseline:\n  custom.yml` is "custom.yml").
  if (/^baseline[ \t]*:[ \t]*(?:#.*)?$(?:\r?\n[ \t]*(?:#.*)?$)*\r?\n[ \t]+[^\s#]/m.test(text)) {
    return { kind: "ambiguous" };
  }
  // The value is optional: a bare `baseline:` (YAML null) is off.
  const m = /^baseline[ \t]*:[ \t]*(?:"([^"]*)"|'([^']*)'|([^\s#]+))?[ \t]*(?:#.*)?$/m.exec(text);
  if (!m) {
    return { kind: "off", unset: true };
  }
  const value = m[1] ?? m[2] ?? m[3] ?? "";
  // Psych (YAML 1.1) nil and false spellings, case-insensitive.
  if (value === "" || /^(?:null|~|false|no|off)$/i.test(value)) {
    return { kind: "off" };
  }
  return { kind: "file", rel: value };
}

async function updateBaseline(options?: CommandOptions): Promise<void> {
  if (!trusted()) {
    return;
  }
  const hit = await pickFolder();
  if (!hit) {
    return;
  }
  const { folder, root } = hit;
  const lookup = baselineLookup(folder, root);
  if (lookup.kind === "off") {
    void window.showInformationMessage(
      lookup.unset
        ? "Rigor: no baseline is configured; set `baseline:` in .rigor.yml or run `rigor baseline generate`."
        : "Rigor: no baseline is in use: `baseline:` is set to false/null in the configuration.",
    );
    return;
  }
  let rel: string;
  if (lookup.kind === "ambiguous") {
    // The config includes other files; ask instead of guessing which one sets `baseline:`.
    const picked = await window.showOpenDialog({
      defaultUri: Uri.file(root),
      openLabel: "Use this baseline file",
      title: "Rigor: which file is the baseline?",
      canSelectMany: false,
      filters: { YAML: ["yml", "yaml"] },
    });
    if (!picked || picked.length === 0) {
      return;
    }
    const chosen = picked[0].fsPath;
    rel = path.relative(root, chosen);
    const configs = [
      path.join(root, ".rigor.yml"),
      path.join(root, ".rigor.dist.yml"),
      configuredPath(folder, root),
    ];
    if (
      rel === ".." ||
      rel.startsWith(`..${path.sep}`) ||
      path.isAbsolute(rel) ||
      configs.some((c) => c !== undefined && path.resolve(c) === path.resolve(chosen))
    ) {
      void window.showWarningMessage(
        "Rigor: pick the baseline file inside the project, not a config file.",
      );
      return;
    }
    // Every baseline `rigor baseline generate` writes has a top-level `ignored:`.
    let isBaseline = false;
    try {
      isBaseline = /^ignored[ \t]*:/m.test(fs.readFileSync(chosen, "utf8"));
    } catch {
      // Unreadable — treated as not a baseline.
    }
    if (!isBaseline) {
      void window.showWarningMessage(
        `Rigor: ${rel} does not look like a Rigor baseline (no top-level \`ignored:\`).`,
      );
      return;
    }
  } else {
    rel = lookup.rel;
  }
  const abs = path.resolve(root, rel);
  if (!fs.existsSync(abs)) {
    void window.showInformationMessage(
      `Rigor: no baseline at ${rel}. Create one with \`rigor baseline generate\` first.`,
    );
    return;
  }
  if (!confirmedBy(options)) {
    const choice = await window.showWarningMessage(
      `Rewrite ${rel} from the current diagnostics?`,
      {
        modal: true,
        detail:
          "The baseline file is shared by the whole team and committed to the repository. " +
          "Regenerating it records every current diagnostic, including any new ones.",
      },
      "Rewrite Baseline",
    );
    if (choice !== "Rewrite Baseline") {
      return;
    }
  }
  // Keep the existing row form: message-mode rows carry a `message:` key.
  let mode: string[] = [];
  try {
    if (/^\s*(-\s+)?message:/m.test(fs.readFileSync(abs, "utf8"))) {
      mode = ["--match-mode=message"];
    }
  } catch {
    // Unreadable — the CLI reports it.
  }
  const r = await runWithProgress("Rigor: baseline regenerate", folder, root, [
    "baseline",
    "regenerate",
    ...configArgs(folder),
    `--output=${rel}`,
    ...mode,
  ]);
  if (failed("baseline regenerate", r)) {
    return;
  }
  await showVirtual("baseline regenerate", `${r.stdout}${cleanStderr(r.stderr)}\n`);
}
