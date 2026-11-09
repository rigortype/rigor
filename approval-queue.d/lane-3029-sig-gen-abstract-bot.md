# sig-gen skips a `bot` proposal for overridden, abstract and template methods under three new reasons

- **PR:** [#3037](https://github.com/rigortype/rigor/pull/3037)
- **Issue:** [#3029](https://github.com/rigortype/rigor/issues/3029)
- **Class:** open-choice
- **Precedent:** [#745](https://github.com/rigortype/rigor/pull/745)
- **Decided:** 2026-11-10

## Background

The gem_rbs_collection audit re-run found `rigor sig-gen` proposing `-> bot` for abstract base methods and for
template methods that call an overridden hook. Each checked case was wrong. The issue asked for a skip, suggested
`sig.skipped.abstract-method` as an example name, and left the reason names, the shape of an "abstract" body,
and how precisely to match an override or a hook call open.

## Options and trade-offs

- One reason for all three readings. It is simpler, but `rigor explain` could not tell an author whether the
  override is in the analysed code or might be outside it, and that decides what they write.
- Three reasons: `overridden-bot`, `abstract-method` and `template-method`. Each says what the author should
  look for.
- Precise matching: resolve ancestors and call receivers with the engine. It skips fewer proposals, but it
  costs a typed walk per call, and an unresolved receiver would still have to fall back to something.
- Name-based matching. A `superclass` or `include` token stands for every class its nesting could name, and a
  call matches a method of its name on any receiver. It over-skips `bot` proposals only, which is the safe
  direction for a proposal.

## Decision

Three reasons, and name-based matching. #745 set the precedent: sig-gen withholds a base declaration that an
override would contradict, and it accepts the lost proposal. An abstract body is a receiverless `raise` / `fail`
as the last statement, of `NotImplementedError`, of an `Abstract…` / `NotImplemented…` class, or with a message
matching implement / abstract / overrid / subclass. That message test keeps mini_magick's "you must call
#format on an Image directly" as a final `bot`. A body that ends in a direct `raise` / `fail` / `throw` /
`exit` / `abort` is not read as a template method, so sinatra's `halt` keeps its `bot`.

## To undo

Remove `BotProposalGuard`, its call in `Generator#run`, the three `SKIP_DIAGNOSTIC_IDS` and catalogue entries,
and their lines in `docs/handbook/11-sig-gen.md` and `docs/type-specification/diagnostic-policy.md`. Nothing
else depends on the reasons.
