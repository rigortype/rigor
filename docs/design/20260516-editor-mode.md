# Editor mode — single-file fast-response analysis

**Status:** Draft. Not yet sliced; superseded only by a future ADR if
one is opened.

Rigor today is project-oriented: `rigor check lib` walks every `.rb`
under `paths:`, builds one Environment, and emits diagnostics. The
editor / IDE / LSP use case is the opposite — the user edits a single
buffer and expects feedback in milliseconds, not seconds. This doc
designs the CLI surface and the runner-side substitutions Rigor needs
to support that workload without committing to a full LSP today.

The shape of the contract mirrors PHPStan's "Editor Mode" (see
[`references/phpstan/website/src/user-guide/editor-mode.md`](../../references/phpstan/website/src/user-guide/editor-mode.md))
because the design problem is the same: the editor maintains an
unsaved buffer, an external tool writes it to a temp file, and the
analyser must act as if that temp file replaced one file inside the
project.

## Motivation

[ADR-0](../adr/0-concept.md) deliberately deferred LSP integration so
the CLI-first inference engine could mature. That decision still
stands. But "CLI-first" does not have to mean "project-only" — an
editor extension can shell out per buffer save / debounced keystroke,
get one diagnostic stream back, and render it inline. The MVP for
"editor-driven Rigor" is **a CLI invocation that takes a buffer and
returns diagnostics for that buffer fast**.

What "fast" means today:

- Cold start (no cache, full pre-pass): bounded by `rigor check`'s
  project-wide setup cost. Out of scope for this design.
- Warm start (cache present, no source changes elsewhere): target
  **under 1 s per buffer** for a 5 K-file project on a current
  laptop. The single-file analysis path is fast already; the
  blocker is that Rigor today re-walks the whole project even
  when only one buffer changed.

## Contract (CLI surface)

`rigor check` gains two paired options that bind a logical project
path to a physical buffer file:

```sh
rigor check \
  --tmp-file=/tmp/9539itfeh2.rb \
  --instead-of=lib/foo.rb \
  lib
```

Semantics:

- `--tmp-file=PATH` — the physical file Rigor MUST parse bytes from.
  Must exist and be readable; missing file is exit 64 (usage).
- `--instead-of=PATH` — the logical project path the buffer
  represents. The analyser acts as if `lib/foo.rb` had the contents
  of `/tmp/9539itfeh2.rb`. Diagnostics MUST report `path:
  lib/foo.rb` so the editor highlights the right buffer.
- The two flags MUST appear together. Either alone is a usage error
  (`EXIT_USAGE`).
- The original file at `--instead-of=PATH` is NOT analysed. If it is
  in the path expansion (typical), it is silently skipped in favour
  of the buffer.
- Multi-buffer (`--buffer A=B --buffer C=D`) is out of scope for v1.
  A single-buffer command is what editors call between debounced
  keystrokes; multi-buffer becomes interesting once an LSP daemon
  multiplexes save events.

The same flag pair extends to `rigor type-of` (the hover-to-type use
case that an editor calls more often than `check`). `type-of` already
separates `source:` from `filepath:` at the Prism boundary, so the
substitution there is a one-line plumbing change.

`rigor type-scan`, `rigor explain`, `rigor diff`, and `rigor sig-gen`
do NOT gain editor-mode flags. They are project-wide or stream-shape
tools, not per-buffer probes.

## Mapping the substitution into the runner

The runner today walks files through three layers:

1. **Path expansion** — `Analysis::Runner#expand_paths` resolves the
   `paths:` list into a `[String]` of concrete `.rb` files.
2. **Per-file parse** — `Runner#analyze_file` (sequential) and
   `WorkerSession#analyze` (pool mode) call `Prism.parse_file(path,
   version:)` for each path.
3. **Project pre-passes** — `SyntheticMethodScanner`,
   `ProjectPatchedScanner`, plugin `#prepare`, dependency-source
   walker — each reads its own input set.

Editor mode is a substitution applied at all three layers:

| Layer | Sequential change | Reason |
|---|---|---|
| Expand | `lib/foo.rb` → `/tmp/9539itfeh2.rb` in the file list, but the original path is remembered as the *logical* identity. | Lets the engine treat the buffer like any other file while reporting the logical path. |
| Parse | `Prism.parse_file(physical, version:)` *or* `Prism.parse(File.read(physical), filepath: logical, version:)`. The latter is preferred because it lets the parsed source's `filepath:` already equal the logical path. | Diagnostic location data uses the logical path automatically. |
| Pre-passes | Same substitution; each scanner's parse step routes through one helper that knows about the buffer binding. | Pre-passes must see the buffer's bytes, otherwise plugin facts / project-patch registry / synthetic methods miss the in-flight edits. |

The wiring point is one value object — call it `BufferBinding` —
threaded through `Runner.new(... buffer: BufferBinding.new(
logical:, physical:))`. Default `nil` keeps the legacy path
bit-for-bit unchanged.

```ruby
BufferBinding = Data.define(:logical_path, :physical_path) do
  def resolve(path)
    path == logical_path ? physical_path : path
  end

  def display_path(path)
    path == physical_path ? logical_path : path
  end
end
```

The two helpers (`resolve` for reads, `display_path` for diagnostic
emission) cover every callsite that currently consumes a path.
Existing single-shot `Diagnostic.new(path: path, ...)` callsites
either pass the logical path directly (because parse already saw
`filepath: logical`) or run through `binding.display_path(path)` at
the runner boundary before emission.

## Cache behaviour

PHPStan editor mode restores the result cache but does not save it.
Rigor's `Cache::Store` (ADR-6) is content-addressed and sharded with
per-entry flocks; reads are lock-free, writes are atomic per-entry.
Two changes:

- **Read-only mode** — A `Cache::Store::ReadOnly` wrapper (or a
  flag on `Store`) suppresses every `#fetch_or_compute` write
  side-effect. The producer block still runs on miss; the result is
  returned to the caller but NOT persisted. Existing on-disk entries
  serve hits unchanged.
- **Concurrent safety** — Multiple editor-mode runs against the
  same cache root are safe because no writer is involved. ADR-6's
  per-file flock invariant is unchanged.

Editor mode forces read-only cache automatically when `--tmp-file`
is set. `--no-cache` still works (skips disk reads too).

Rigor today does NOT have a per-file *diagnostic* cache. PHPStan's
"only the edited file is reanalysed" speed depends on one, so the
fastest path Rigor can offer today is **single-file scope** rather
than "incremental project". See § "Scope choice" below.

## Scope choice — what gets analysed

Three viable shapes:

- **(A) Single-file scope.** When `--tmp-file` is set, Rigor analyses
  *only* the buffer. The rest of `paths:` is loaded as Environment
  context (RBS, plugin facts, synthetic-method index, project-patch
  registry) but no per-file diagnostics are emitted for other files.
- **(B) Project scope with buffer substitution.** PHPStan-shape.
  Whole project is analysed; the edited file is substituted.
  Requires a per-file diagnostic cache to be fast, which Rigor does
  not have yet (ADR-17 slice 3b is the queued lever).
- **(C) Single-file plus caller-declared dependents.** The editor
  passes `--also=lib/bar.rb,lib/baz.rb` for files known to depend on
  the buffer's public surface (return type, constant value, exported
  module).

**v1 ships (A).** It's the smallest cut that delivers the speed
target, and it composes forward: when a per-file diagnostic cache
exists, the same CLI shape upgrades to (B) with no flag rename.

The editor extension can layer (C) on top of (A) by issuing multiple
single-file invocations (one per affected file). Rigor doesn't owe
the caller dependency tracking until a per-file cache exists.

## Project pre-pass interaction

`SyntheticMethodScanner`, `ProjectPatchedScanner`, plugin `#prepare`,
and the dependency-source walker each build project-wide state
before per-file analysis fires. In single-file editor mode three
things must hold:

- The pre-passes see the buffer's bytes at the logical path.
  `BufferBinding.resolve` threads through their parse helpers.
- The pre-passes are NOT pessimistically rerun on every keystroke
  if their inputs haven't changed. v1 reruns them per invocation
  (cheap-ish on small-medium projects but not free); a follow-up
  designs a project-context snapshot cache keyed on
  `(plugin-manifest digest, project file mtime + size list)`.
- Plugin `#prepare` runs once per editor-mode invocation, same as
  today. Plugins that publish cross-plugin facts (`:dry_type_aliases`,
  `:helper_table`, `:model_index`) MUST be idempotent so repeated
  editor-mode runs converge — they already are by ADR-9's design.

## Ractor pool mode

ADR-15 Phase 4b's Ractor pool warms up an RBS cache and spawns N
workers. For a one-file run the pool warm-up cost dominates wall
time. Editor mode therefore forces `workers: 0` (sequential) when
`--tmp-file` is set, regardless of `--workers=N` / `RIGOR_RACTOR_WORKERS`
/ `parallel.workers:`. The override is silent — pool mode is a
project-scale knob; editor mode is per-buffer.

## Diagnostic ordering and inline disable markers

- `# rigor:disable <rule>` end-of-line markers come from
  `parse_result.comments` of the parsed source, which IS the
  buffer's source. They naturally track the buffer's current line
  numbers. No special handling needed.
- Project-level `.rigor.yml` `disable:` keys are path-independent
  and apply unchanged.
- Severity profile + per-rule overrides apply unchanged.

## Run stats

`RunStats` is on by default. Editor mode should keep it on so the
editor's log surface can show "analysed lib/foo.rb (buffer) in
N ms, wall: Xs, RBS classes: K". One new field on the stats object:
`buffer_logical_path: String` (nil under non-editor runs). The text
summary appends `(editor mode: lib/foo.rb)` when present. JSON
consumers see the field directly.

## Failure envelope

- `--tmp-file=X` without `--instead-of=Y`, or vice versa → exit 64,
  `usage: --tmp-file and --instead-of must appear together`.
- `--tmp-file=X` with `X` not readable → exit 1, one
  `Diagnostic(path: '.rigor.yml', severity: :error)` explaining the
  read failure.
- `--instead-of=Y` with `Y` not under any `paths:` directory →
  treated as a valid logical identity for the buffer; the buffer
  is still analysed. This is intentional: editors sometimes call
  Rigor against files that don't formally belong to `paths:`
  (e.g. files in `spec/` analysed without `spec/` in `paths:`).
- Parse errors in the buffer surface as today's parse-error
  diagnostics, with `path: lib/foo.rb`.

## Out of scope for v1

- Multi-buffer (`--buffer A=B --buffer C=D`).
- LSP daemon, persistent process, file-watch.
- Per-file diagnostic cache (ADR-17 slice 3b territory). Unblocks
  scope shape (B).
- Project-context snapshot cache for pre-pass reuse. **LANDED for
  the LSP path** as `Rigor::Analysis::ProjectScan` +
  `Runner#prepare_project_scan` + `Runner.new(prebuilt:)`
  (v0.1.6); the LSP's `ProjectContext` lazy-builds the snapshot
  and `DiagnosticPublisher` threads it through every per-publish
  `Runner.new`. CLI `rigor check --tmp-file` does not yet
  consume the snapshot — each invocation is a fresh process; a
  disk-backed snapshot cache keyed on `(plugin-manifest digest,
  project file mtime + size list)` would let one-shot CLI
  invocations skip pre-passes too. Demand-driven.
- Caller-declared dependent files (`--also=...`). Trivial CLI
  extension once (A) ships; defer until an editor extension actually
  needs it.
- Caching at the `rigor type-of` boundary. Editor mode for
  `type-of` should be as cheap as the existing per-call path
  already is.

## Slicing

1. **`BufferBinding` value object** + `Runner` parameter plumbing.
   Default nil; existing tests stay green.
2. **`Runner#analyze_file` / `WorkerSession#analyze` honor the
   binding** for parse + diagnostic emission. Single-file editor-mode
   integration spec covers the happy path.
3. **`Cache::Store::ReadOnly` wrapper** + CLI auto-enables it under
   `--tmp-file`. Spec: a buffer-mode run against an empty cache root
   leaves the cache root empty afterward.
4. **CLI flags on `rigor check`** + usage / error envelope. Spec
   covers the missing-pair / missing-file cases.
5. **Single-file scope mode** — when `--tmp-file` is set, the runner
   analyses only the buffer (option A); other files contribute
   Environment context only. Pre-passes rerun once per invocation
   with the buffer substituted. Spec: a buffer-mode run against a
   project with N files produces diagnostics only for the buffer.
6. **`rigor type-of` editor flags** — same `--tmp-file` /
   `--instead-of` semantics. Spec: hovering inside the buffer at
   `(line, col)` reports a type derived from the buffer bytes, not
   the on-disk file.
7. **Ractor pool degrades to sequential** under editor mode; CLI
   prints no warning (the override is part of the contract, not a
   pool failure). Spec: `--workers=4 --tmp-file=...` runs sequentially.

After slice 7 the v1 contract is complete. Slices for the queued
items (project-context snapshot cache, per-file diagnostic cache,
`--also`, multi-buffer) open separately when the editor extension
that consumes editor mode surfaces concrete need.

## Open questions

- **Plugin trust policy under editor mode.** A buffer file may live
  outside any allowed-read-root. Today plugins enforce I/O policy
  through `Plugin::IoBoundary`. Decision: read of the physical file
  is performed by Rigor's runner, not by a plugin; the buffer's
  bytes flow through `Scope`-level state, not through
  `IoBoundary#read_file`. So the trust policy is unaffected. If a
  plugin needs to re-read the buffer's logical path (rare —
  rigor-actioncable / rigor-rails-i18n do not), it would see the
  on-disk file, not the buffer. This is a documented edge case
  rather than a v1 design problem.
- **Whether to expose a `--cwd=PATH` flag** so editors can run
  Rigor from outside the project root. PHPStan exposes one; Rigor
  resolves config via `Configuration.discover`. Decision deferred
  until an editor extension reports the working-directory
  assumption is wrong for them.
- **What to do when `--instead-of` names a file with parse errors
  on disk** (the on-disk version has errors but the buffer fixes
  them). Today the runner expands `paths:` and would include the
  on-disk file's parse errors. Decision: under editor mode, the
  logical-path's on-disk file is skipped wholesale — only the
  buffer is parsed.
