# 06 — Install the agent type-contract into AGENTS.md / CLAUDE.md

Covers **Phase 8b**. Input: an onboarded project (config written, sigs
generated, baseline decided). Output: one section in the file the
project's coding agents read at startup.

## Why this is part of onboarding

Everything the earlier phases produced — `sig/`, the baseline, the
severity profile — is a record of what Rigor *proved*. The moment an AI
agent starts contributing to the project, it can write types that Rigor
never proved: a `@param currency [String]` in a doc comment, an
rbs-inline `#:` that Rigor then ingests as a live contract. Those enter
the same files, look identical to derived types, and are believed.

The fix is not a tool. It is one paragraph in the project's agent
contract, so the rule is in context every session rather than only when
a skill happens to trigger: **a type not obtained from Rigor is a guess,
and a guessed type is never written.**

## The text

The canonical fragment is served by the installed Rigor, so it stays
current with the CLI it names:

```sh
rigor skill --full rigor-type-oracle
```

Its `references/02-agents-md-fragment.md` section carries the paragraph
and the five bullets. Copy that block **verbatim** — including its
single-long-line shape, which is deliberate (some renderers turn a
newline inside a paragraph into a line break).

Do not paraphrase it from memory, and do not shorten it: the five bullets
are the load-bearing part — expression, method signature, parameter,
the gap rule, and provenance.

## Where it goes

| Project state | What to do |
| --- | --- |
| `AGENTS.md` exists | **Append** the section at the end. Do not reorganise the file. |
| Only `CLAUDE.md` exists | Append it there. |
| Both exist | Put it in `AGENTS.md`. Add `@AGENTS.md` to `CLAUDE.md` only if it is not already pulled in. |
| Neither exists | **Create `AGENTS.md`** with this as its first section. |
| A types / type-checking section already exists | Merge into it; keep the five bullets intact. Never write a second, competing rule. |

Never overwrite unrelated content. If the project already states a rule
about type authorship that contradicts this one, stop and show the user
the conflict — the project's own rule wins until they say otherwise.

## Report it in the final step

This is a change to the file that governs every future agent session in
the repo, so it belongs in Phase 9's file inventory, not in a silent
diff. Recommend committing it: the point is that every contributor's
agent reads the same rule.

## When to skip

- The project has no coding-agent contract file **and** the user has said
  they do not use AI agents on it. Offer once, accept "no".
- The user declined it earlier in this session.

Otherwise install it — an unonboarded agent is the one contributor that
cannot be trained by review.
