# Draw the line between serious decisions and post-hoc ones where contribution-flow.md now draws it

- **PR:** [#2138](https://github.com/rigortype/rigor/pull/2138)
- **Issue:** none
- **Class:** process
- **Precedent:** none — sets one
- **Decided:** 2026-10-19

## Background

The maintainer asked that agents decide everything except serious changes on their own, following
precedent, and report afterwards. "Serious" needed a definition an agent can apply without asking,
because a wrong reading either brings back the wait (too wide) or lands something costly to undo
(too narrow).

## Options and trade-offs

- **Narrow: only releases and publishing stay gated.** Fastest, but a default users see, a broken
  CLI or plugin contract, or a loosened gate would then ship to `master` and depend on someone
  noticing at release time; some of these (a new cache format) also shape later work before they
  are ratified.
- **Wide: anything touching behaviour or a gate file waits.** Safe, but it is the old flow: every
  ADR-119 gate row in the v0.4.5 batch would have waited again, though each was approved as
  proposed.
- **The middle line taken:** wait for what is costly to undo after merge or visible to users once
  released (releases, user-visible defaults, public contract breaks, cache formats and native code,
  new runtime dependencies, new or reversed ADR decisions, gates that check less without a
  precedent, repository settings, rejected severe findings, non-converging designs,
  `ready-for-human` issues); decide the rest by precedent, with an entry.

## Decision

The middle line. It keeps the exceptions the maintainer already set when delegating design calls on
2026-09-28 (defaults such as #120, cache formats and native code), adds the classes that are hard
to undo or that weaken a check, and leaves precedented gate rows, open readings and scope splits to
the agent. Tightening, and outcomes a `ready-for-agent` issue already stated, need no entry at all.

## To undo

Edit the list in `docs/agents/contribution-flow.md` § "Decisions and the approval queue" and the
matching sentence in ADR-123. Entries made under the old line stay in the queue for ratification as
they are.
