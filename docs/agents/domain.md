# Domain Docs

How the engineering skills consume this repo's domain documentation when exploring the codebase.

This is a **single-context** repo.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — the domain glossary (trap terms + pointers to the canonical
  vocabulary docs).
- **`docs/adr/`** — ADRs that touch the area you are about to work in. Files are `N-slug.md`;
  the index (title + status for all of them) is `docs/adr/README.md`. The premises an agent must
  know regardless of area are listed in `AGENTS.md` § "Architecture Decision Records".

If a file is missing, proceed silently; `/domain-modeling` creates them lazily when terms or
decisions actually get resolved.

## Use the glossary's vocabulary

When your output names a domain concept (an issue title, a refactor proposal, a hypothesis, a test
name), use the term as `CONTEXT.md` defines it. Two terms are actively trapped in this repo —
"interface" and "protocol" — see the glossary before using either.

If the concept you need is not in the glossary, that is a signal: either you are inventing language
the project does not use (reconsider), or there is a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-43 (allow-list ancestor resolution) — but worth reopening because…_

Remember the repo's own rule: when an ADR and the spec corpus disagree on analyzer behaviour, the
**spec binds** (`docs/type-specification/`, `docs/internal-spec/`); the ADR records why.
