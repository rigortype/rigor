# The Rigor User Manual

How to install, run, configure, and operate Rigor. Where the
[handbook](../handbook/README.md) teaches the *type model* —
what carriers Rigor infers and why — this manual is the
*operational* reference: the command line, the configuration
file, the diagnostic catalogue, and the workflows for adopting
Rigor on a real project.

The two are companions. Reach for the handbook to understand
what a diagnostic *means*; reach for the manual to look up the
flag, key, or command that *acts* on it.

## Contents

### Getting started

1. [Installing Rigor](01-installation.md) — `mise`, `asdf`,
   `gem install`, Nix, and the dev-container guidance. Rigor
   is a tool, not a project dependency.
14. [Rigor for Rails — step-by-step setup with mise](14-rails-quickstart.md) —
    install Ruby 4.0 + Rigor via `mise`, activate the Rails
    plugin set, run `rigor check`, and share the config with
    your team in about ten minutes.

### Reference

2. [CLI command reference](02-cli-reference.md) — every
   subcommand (`check`, `annotate`, `type-of`, `sig-gen`,
   `baseline`, `triage`, `lsp`, …), its flags, and its exit
   codes.
3. [Configuration](03-configuration.md) — the `.rigor.yml`
   key reference, config discovery, and `includes:` layering.
4. [Diagnostics](04-diagnostics.md) — the rule-ID catalogue,
   severity profiles, and `# rigor:disable` suppression.
5. [Inspecting inferred types](05-inspecting-types.md) — the
   `assert_type` / `dump_type` source helpers and the
   `rigor annotate` / `rigor type-of` commands.

### Adopting Rigor on a project

6. [Baselines](06-baseline.md) — `.rigor-baseline.yml`, the
   `rigor baseline` subcommands, and `rigor triage`.
7. [Using plugins](07-plugins.md) — activating framework and
   gem plugins through the `plugins:` config key. Per-plugin
   user docs live under [Plugin reference](plugins/README.md).
8. [Provided skills](08-skills.md) — the bundled Agent Skills
   for onboarding and baseline reduction.
15. [Type-protection coverage](15-type-protection-coverage.md) —
    measuring whether a bug would be *caught*, fusing your types
    and your tests into one safety net (`rigor coverage
    --protection [--mutation --with-tests --include-dynamic]`).

### Integration and operations

9. [Editor integration](09-editor-integration.md) — wiring
   `rigor lsp` into Neovim, VS Code, Helix, and Emacs.
10. [MCP server](10-mcp-server.md) — exposing Rigor's
    analysis tools to AI coding agents (Claude Code, Cursor,
    Cline, …) via `rigor mcp`.
11. [Running Rigor in CI](11-ci.md) — a clean CI job, inline
    PR/MR diagnostics (SARIF / GitHub Actions / GitLab Code
    Quality), copy-paste [templates](ci-templates/), and
    version pinning.
12. [Caching](12-caching.md) — where the cache lives, what
    invalidates it, and how to clear it.
13. [Troubleshooting](13-troubleshooting.md) — common
    problems and their fixes.

## See also

- [The Rigor Handbook](../handbook/README.md) — the type-model
  walkthrough.
- [`docs/types.md`](../types.md) — one-page type-system guide.
- [`docs/type-specification/`](../type-specification/README.md)
  — the normative spec corpus.
- [`docs/adr/`](../adr/) — architecture decision records.
