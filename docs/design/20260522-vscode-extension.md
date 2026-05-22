# VSCode extension — first-party marketplace client for `rigor lsp`

**Status:** Draft. Not yet sliced; superseded only by a future ADR if
one is opened.

The Language Server ([`docs/design/20260517-language-server.md`](20260517-language-server.md))
landed in v0.1.6 and is bundled in the `rigortype` gem as the
`rigor lsp` subcommand ([ADR-19](../adr/19-language-server-packaging.md)).
Today VSCode users are told to wire it up through a generic LSP client
or a hand-written minimal extension — see the current
[`docs/manual/09-editor-integration.md`](../manual/09-editor-integration.md) § "VSCode". Neovim
gets a documented `lspconfig` recipe, Helix gets a `languages.toml`
block, Emacs gets Eglot / lsp-mode snippets; VSCode — the single
largest editor in the Ruby population — gets a "write your own"
placeholder.

This doc designs a **first-party VSCode extension** published to the
marketplace: one-click install, a settings UI, sane server discovery,
and a status indicator. It is the editor-side companion to ADR-19's
gem-side decision.

## Framing — why this is NOT an ADR-19 problem

ADR-19 decided where the *LSP gem code* lives, and its dominant
argument was internal-API coupling: the LSP reads `Analysis::Runner`,
`Scope#type_of`, `Environment`, `BufferTable`, etc. directly, so
splitting it into a separate gem would force those surfaces public.

**That argument does not transfer to the VSCode extension.** The
extension is a pure LSP client. It speaks JSON-RPC over stdio to
`rigor lsp` and touches *zero* Rigor Ruby APIs. There is no coupling
to redact, no public-API pledge at stake. The packaging question for
the TypeScript artifact is therefore answered on its own terms
(discoverability, build toolchain, release cadence), recorded in this
doc. A dedicated ADR is optional; if the marketplace-publishing
policy needs the weight of an ADR later, amend ADR-19 with an
editor-artifact section rather than re-deriving the gem rationale.

## Decisions

- **Location: monorepo, new top-level `editors/vscode/`.** A new
  `editors/` tree joins `plugins/`, `examples/`, `skills/`. Keeps the
  extension versioned next to `docs/manual/09-editor-integration.md`, discoverable
  in one repo, and reserves `editors/` for future editor artifacts
  (a Zed extension, an Emacs package) without re-litigating layout.
  Rejected: `plugins/` (that tree is the Ruby-gem plugin catalogue
  per [`plugins/README.md`](../../plugins/README.md) — a TypeScript
  artifact breaks the catalogue's premise) and a separate
  `rigor-vscode` repo (forces docs / extension sync across repos for
  no coupling benefit, since there is no coupling).
- **Language: TypeScript.** VSCode extension standard.
- **Client library: `vscode-languageclient`** (Microsoft). Wraps the
  LSP lifecycle, capability negotiation, and the diagnostics / hover /
  completion / documentSymbol → VSCode-UI plumbing. The extension
  spawns the server and registers the client; it implements no
  language features itself.
- **Server transport: stdio.** Matches the LSP's only v1 transport.
- **Build: `esbuild` bundle + `@vscode/vsce` for packaging.** Minimal
  toolchain; `npm` scripts under `editors/vscode/`.
- **Release cadence is independent of the gem.** The extension has
  its own semver line and its own `CHANGELOG.md`. It declares a
  *minimum* compatible `rigortype` version, not a lockstep one — the
  LSP wire surface is stable LSP, so extension UX changes (settings,
  status bar) must not force a gem bump, and analyzer type-correctness
  releases must not force an extension bump. Mirrors ADR-19's
  reversibility / independent-cadence reasoning, applied to the
  TypeScript artifact.
- **Publish to VS Marketplace AND Open VSX.** Open VSX covers
  VSCodium / Cursor / Gitpod. Both publishes are manual and
  authorisation-gated, same discipline as `rake release` for the gem.
- **The extension does not bundle the gem.** The user installs
  `rigortype` (Gemfile or global gem); the extension is a thin
  client. The not-installed case is handled gracefully (see § Server
  discovery).

## Identity

- Marketplace publisher: the Rigor org publisher id.
- Extension id: `rigor`. Display name: **"Rigor — Ruby type checker"**.
- Categories: `Programming Languages`, `Linters`.
- Keywords: `ruby`, `rbs`, `type checking`, `static analysis`, `lsp`.

## What the extension gives VSCode users

Everything the LSP already advertises lights up automatically once
`vscode-languageclient` connects — the extension writes no feature
code for these:

| LSP capability | VSCode UI it drives |
|---|---|
| `publishDiagnostics` | Problems panel + inline squiggles, `source: "rigor"`, severity-mapped, `code` = rule id |
| `hover` | Hover tooltip (type-aware markdown) |
| `completion` | IntelliSense after `.` / `::` |
| `documentSymbol` | Outline view + breadcrumbs + symbol search |
| `didChangeWatchedFiles` | Config / file-save invalidation (see § File watching) |

The extension's *own* surface is the parts the LSP cannot provide
from inside a stdio server: discovery, configuration UI, lifecycle
commands, status.

## Server discovery

The extension must locate the `rigor` executable. Precedence chain,
first match wins, evaluated per workspace folder:

1. **`rigor.server.path` setting** — explicit absolute path or
   command. The escape hatch for non-standard installs (asdf shims,
   monorepo subdirs, Docker wrappers).
2. **Bundler** — when `rigor.server.useBundler` resolves true and the
   folder has a `Gemfile.lock` listing `rigortype` →
   `bundle exec rigor lsp`. `useBundler` is an enum
   `auto` / `always` / `never`; `auto` (default) resolves true iff a
   `Gemfile.lock` mentioning `rigortype` is found. Most Ruby projects
   pin the gem in the Gemfile, so this is the common path.
3. **Global `PATH`** — bare `rigor lsp`.
4. **Not found** — no crash. Surface an actionable notification
   ("Rigor: `rigortype` gem not found in this workspace") with a
   button linking to the install docs. The extension stays loaded so
   the user can fix the Gemfile and run `Rigor: Restart Server`.

Server working directory = the workspace folder root, so
`Configuration.discover` walks `.rigor.yml` / `.rigor.dist.yml`
exactly as the CLI does. On startup the extension probes
`rigor version` (cheap) and warns if it is older than the minimum —
a precise "gem too old" message beats an opaque spawn failure.

Windows note: `bundle exec` resolution needs `bundle.bat` /
`shell: true` handling. The LSP's own Windows path-encoding open
question ([`20260517-language-server.md`](20260517-language-server.md)
§ "Open questions") is inherited, not solved here.

## Configuration contributions

`contributes.configuration`, all under the `rigor.` prefix:

| Setting | Type | Default | Effect |
|---|---|---|---|
| `rigor.enable` | boolean | `true` | Master switch; `false` stops the client |
| `rigor.server.path` | string | `""` | Explicit executable path / command |
| `rigor.server.useBundler` | enum `auto`/`always`/`never` | `auto` | Bundler resolution policy |
| `rigor.server.configPath` | string | `""` | Passed as `--config=PATH` |
| `rigor.server.logPath` | string | `""` | Passed as `--log=PATH` |
| `rigor.trace.server` | enum `off`/`messages`/`verbose` | `off` | Standard LSP-client wire trace into the output channel |

`resource`-scoped where it makes sense, so multi-root workspaces can
override per folder.

**Restart semantics.** Settings that change the *process invocation*
(`server.path`, `server.useBundler`, `server.configPath`,
`server.logPath`) require a client **restart** — they are not
`workspace/didChangeConfiguration` payloads. The extension watches
its own settings and restarts the affected client automatically. The
LSP v1 ignores the `didChangeConfiguration` payload and re-runs
`Configuration.discover` anyway, so the project-config surface is
driven by file watching, not by VSCode settings.

## File watching

`vscode-languageclient` honours server-requested dynamic
registration of `workspace/didChangeWatchedFiles`. The extension also
sets `synchronize.fileEvents` for `**/.rigor.yml`,
`**/.rigor.dist.yml`, and `**/Gemfile.lock` so config edits and gem
changes reach the server and invalidate its `ProjectContext` (per the
LSP design's § "Project context refresh"). Buffer edits go through
ordinary `didChange` — no watcher needed.

## Activation

`activationEvents`:

- `onLanguage:ruby`
- `workspaceContains:**/.rigor.yml`
- `workspaceContains:**/.rigor.dist.yml`

No `*` eager activation — VSCode startup-perf guidance. A project
with a Rigor config warms the server before the first Ruby file
opens; a project without one only activates when Ruby is touched.

## Commands

`contributes.commands`:

- `rigor.restartServer` — restart the language client (after a gem
  update, a Gemfile change, or a server-affecting setting edit).
- `rigor.showOutputChannel` — reveal the "Rigor" output channel.
- `rigor.showServerLog` — open the `--log` file if `server.logPath`
  is set.

Deferred (see § Out of scope): `rigor.checkWorkspace`.

## Status bar

A status bar item reflects client state — `starting` / `running` /
`stopped` / `error` — and clicking it opens the output channel.
Since the LSP otherwise works silently, this is the primary
"is it alive?" affordance. Standard shape (Sorbet / Steep extensions
do the same).

## Multi-root workspaces

LSP v1 is single-root ([`20260517-language-server.md`](20260517-language-server.md)
§ "Out of scope for v1"). The extension reconciles that with VSCode
multi-root workspaces by spawning **one `LanguageClient` per
workspace folder** that contains a `.rigor.yml` / `.rigor.dist.yml` /
`Gemfile`, each rooted at its folder. A folder with no Rigor config
gets no client. Files outside every Rigor-configured folder get no
diagnostics — documented as a known limitation, lifted for free if
the LSP later gains multi-root support.

`documentSelector`: `{ scheme: 'file', language: 'ruby' }`. Untitled
and non-`file` buffers are unsupported — the analyzer needs a project
root on disk.

## Coexistence with other Ruby tooling

VSCode users routinely run Shopify Ruby LSP / Solargraph / Sorbet
alongside each other; VSCode multiplexes multiple servers per
language without conflict. To stay a good citizen the Rigor
extension:

- declares **no** `contributes.languages` / `grammars` — it consumes
  the existing `ruby` language id, never claims it (syntax
  highlighting stays the user's chosen grammar extension);
- registers **no** formatter (RuboCop's job, per the LSP design);
- relies on `source: "rigor"` on every diagnostic for visual
  attribution in the Problems panel.

The README recommends a pairing setup for users who also run another
Ruby LSP.

## Out of scope for v1

- **`rigor.checkWorkspace`** — a whole-project `rigor check` run. The
  LSP is single-file scope; project-wide diagnostics belong to the
  editor-mode "option B" follow-up (ROADMAP § "Editor / IDE
  integration"). Once the LSP publishes workspace diagnostics, an
  explicit command is redundant — defer until then. If demanded
  sooner, ship it as a `contributes.tasks` task, not a command.
- **Bundled `rigortype`** — the gem is a user install.
- **Telemetry** — none. Stated explicitly for privacy.
- **Debug adapter / test runner integration.**
- **Snippets, code lenses, inlay hints** — wait for the matching LSP
  capabilities (all queued in the ROADMAP).

## Packaging & release

`editors/vscode/` contents:

```
editors/vscode/
  package.json          extension manifest + contributes
  tsconfig.json
  esbuild.js            bundle script
  src/extension.ts      activate / deactivate, client wiring
  src/discovery.ts      server-discovery chain
  src/status.ts         status bar item
  .vscodeignore
  README.md             marketplace landing page
  CHANGELOG.md          extension's own semver line
  LICENSE
  icon.png
```

- Build: `npm run compile` (esbuild). Package: `npm run package`
  (`vsce package` → `.vsix`).
- Publish: `vsce publish` (VS Marketplace) + `ovsx publish`
  (Open VSX). **Manual, authorisation-gated** — same rule as
  `bundle exec rake release`. Record this in `AGENTS.md` alongside
  the gem-release gate.
- CI: a GitHub Actions job scoped to `editors/vscode/` runs
  `npm ci && npm run compile && npm run package` to catch breakage.
  Publishing stays manual.
- The extension build is **not** wired into `make verify` and Node is
  **not** added to the Flake dev shell — Ruby contributors must not
  be forced through a Node toolchain. `editors/vscode/` carries its
  own `npm` scripts; `AGENTS.md` documents the separation. (Symmetry
  with ADR-19: there, CI-only gem users still pay the
  `language_server-protocol` dep; here, Ruby contributors do not pay
  the Node dep.)

## Compatibility matrix

- VSCode `engines.vscode`: a recent `^1.8x.0` baseline.
- `vscode-languageclient`: pin the major version.
- Minimum `rigortype`: **v0.1.6** (first release shipping
  `rigor lsp`). The startup `rigor version` probe enforces it.
- Position encoding: the LSP advertises `utf-16`, the VSCode default
  — no negotiation issue.

## Slicing

Each slice ships its own commit; same discipline as the LSP design.

1. **Scaffold `editors/vscode/`** — `package.json`, `tsconfig`,
   `esbuild.js`, a hello-world `activate`. No LSP yet.
2. **LanguageClient wiring** — spawn `rigor lsp` over stdio,
   `documentSelector` ruby. Diagnostics / hover / completion /
   outline light up. First user-visible payoff.
3. **Configuration contributions** — settings → server args
   (`--config`, `--log`); restart-on-server-setting-change.
4. **Server discovery chain** — `path` / bundler-`auto` / global +
   actionable not-found notification + `rigor version` probe.
5. **Status bar item + commands** — `restartServer`,
   `showOutputChannel`, `showServerLog`.
6. **Multi-root** — one client per Rigor-configured folder.
7. **File watching** — `.rigor.yml` / `Gemfile.lock` synchronisation.
8. **Marketplace metadata** — README, icon, categories, keywords;
   Open VSX manifest.
9. **CI job** — build + `vsce package` (no publish).
10. *(deferred)* `rigor.checkWorkspace` task; capability follow-ups
    tracking new LSP features.

After slice 7 the extension is feature-complete for the
"install from the marketplace, get keystroke-fast diagnostics +
hover + completion + outline" experience. Slices 8–9 are the
publishing path.

## Docs follow-through

When the extension ships, rewrite [`docs/manual/09-editor-integration.md`](../manual/09-editor-integration.md)
§ "VSCode": replace the generic-client / hand-written-extension
workaround with "install the **Rigor** extension from the
Marketplace (or Open VSX)", keeping the manual-wiring snippet only as
a fallback for users on unsupported VSCode forks.

## Open questions

- **Open VSX automation** — token storage / rotation for an
  automated `ovsx publish`. Defer; v1 publishes manually.
- **Icon / branding asset** — needs a real designed asset before the
  first marketplace submission.
- **`rigor version` probe failure modes** — distinguish "gem absent"
  from "gem present but `lsp` subcommand absent" (pre-v0.1.6) from
  "spawn blocked by the OS". v1 collapses the last two into one
  message; refine if it confuses users.
- **Pre-release channel** — VS Marketplace supports a `pre-release`
  flag. Decide whether to use it for tracking unreleased LSP
  capabilities. Defer until there is an LSP feature worth a preview.
- **Workspace trust** — VSCode "restricted mode" blocks spawning
  workspace executables. The extension should detect untrusted
  workspaces and show a clear "trust this workspace to run Rigor"
  prompt rather than failing silently.
