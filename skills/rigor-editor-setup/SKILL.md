---
name: rigor-editor-setup
description: |
  Wire Rigor's bundled language server (`rigor lsp`) into the developer's editor for live diagnostics, hover-to-type, outline, and type-aware completion. The per-editor config snippets live in the manual; this skill identifies the editor, applies the right one, and verifies the server attaches. Triggers: "set up Rigor in my editor", "rigor LSP / language server", "live Rigor diagnostics in VS Code / Neovim / Helix / Emacs", "hover types in my editor". NOT for CI integration (use rigor-ci-setup) or first-time project setup (use rigor-project-init).
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor Editor Setup

`rigor lsp` is the in-process Language Server bundled with the
`rigortype` gem. It speaks LSP over stdio and turns Rigor's analyzer
into a live editor experience: diagnostics as you type, hover-to-type,
an outline view, and type-aware completion. This skill wires it into the
developer's editor.

The authoritative, per-editor configuration lives in the manual. With
Rigor installed, read it **offline** with no network round-trip:

```sh
rigor docs editor-integration
```

(Web fallback, only before Rigor is installed:
**[Rigor LSP — Editor Integration](https://github.com/rigortype/rigor/blob/master/docs/manual/09-editor-integration.md)**.)
This skill is the *workflow* around it (identify the editor → apply the
manual's snippet → verify), so it does not duplicate (and cannot
stale-out) the config details.

## First: load the version-current copy

The config details already come live from `rigor docs`; this section keeps
the *workflow itself* current too. Prefer the copy of this skill that ships
with the **installed** Rigor over any vendored or frozen copy of this file:

```sh
rigor skill --full rigor-editor-setup
```

If you already loaded this skill *via* `rigor skill` you have the current
copy — just proceed. If `rigor` is not on `PATH`, this task needs it: run
**`rigor-next-steps`** to install Rigor first, then come back.

## When to use

- A developer wants Rigor feedback live in their editor, not just from
  `rigor check` on the command line.
- A project commits a shared editor config (e.g. `.vscode/`) and you want
  to add Rigor's LSP to it so the whole team gets it.

## When NOT to use

- Wiring Rigor into CI — that is `rigor-ci-setup`.
- The project has no Rigor config yet — run `rigor-project-init` first
  (the LSP uses the same `.rigor.yml` discovery as `rigor check`).

## The one stable fact

Every editor snippet simply launches **`rigor lsp`** (stdio) and needs
**`rigor` on the editor's `PATH`** — the same executable `rigor check`
uses. For GUI editors that do not inherit your shell, the `mise` shim
path is the most reliable channel (see `rigor docs install`, or
[Installing Rigor](https://github.com/rigortype/rigor/blob/master/docs/install.md)
on the web). Do **not** add `rigortype` to the project's `Gemfile` — it
is a tool, not a library.

## Procedure

### Phase 1 — confirm the analyzer works from the CLI first

```sh
rigor check <a-file-or-dir>
```

The LSP shares `rigor check`'s config discovery and analysis. If `check`
works from the project root, the LSP will too; if it fails, fix that
first — the editor would only surface the same failure.

### Phase 2 — identify the editor

Ask the developer which editor they use, or detect it (a committed
`.vscode/`, a Neovim `init.lua`, `~/.config/helix/`, an Emacs config).
The manual chapter covers:

- **Neovim** (nvim-lspconfig)
- **VS Code** (generic LSP-client wrapper / minimal extension)
- **Helix** (`languages.toml`)
- **Emacs** (Eglot and lsp-mode)

### Phase 3 — apply the matching config

Open the manual's **Editor wiring** section and apply the snippet for
the developer's editor verbatim:

```sh
rigor docs editor-integration
```

(or, pre-install, the web copy:
<https://github.com/rigortype/rigor/blob/master/docs/manual/09-editor-integration.md>)

All snippets invoke `rigor lsp` directly. (Only if the project still
uses a legacy bundler-local install do you swap in
`bundle exec rigor lsp` — the manual notes this per editor.)

If the project commits a shared editor config (e.g. `.vscode/`), add the
Rigor LSP wiring there and commit it, so every contributor gets the same
setup rather than configuring it individually.

### Phase 4 — verify

Open a Ruby file inside a Rigor-configured project and confirm:

- diagnostics appear (on save / as you type), and
- hover over a method or local shows its inferred type.

If the server starts but nothing appears, work the manual's
**Troubleshooting** section (most often: `rigor` not on the editor's
PATH, or no `.rigor.yml` at the project root). Capture the LSP log with
`rigor lsp --log=/tmp/rigor-lsp.log` when filing an issue.

## Next step

Re-run `rigor skill describe` for the next move — with live feedback in
the editor, raising protection (`rigor-protection-uplift`) or reducing a
baseline (`rigor-baseline-reduce`) is a tighter loop.
