---
name: rigor-unused-adjudicate
description: |
  Find dead code in a Ruby project with `rigor unused` — establish what the report can see on THIS project first, then adjudicate every row before proposing any deletion. Use this whenever someone asks to find or remove dead code, unused classes, unused constants, or "code nobody calls", whenever they ask what a `rigor unused` report means or which rows are safe to delete, and whenever a dead-code cleanup, codebase inventory, or legacy audit comes up — even if they never say "rigor". The report is a review queue and not a defect list; on an adjudicated corpus target only 4 of 57 rows were genuinely dead, so acting on it directly produces mostly wrong deletions. NOT for deleting a specific class you already know is dead, and NOT for `rigor check` diagnostics (those are ordinary type errors).
license: MPL-2.0
metadata:
  version: 0.2.0
  homepage: https://github.com/rigortype/rigor
---

# Adjudicating `rigor unused`

`rigor unused` answers *which project classes and modules does no reachable
code name?* — not *what can I delete*. Closing that gap is the work, and the
manual chapter has the method:

```sh
rigor docs 18-removing-dead-code
```

Read it before adjudicating anything. It carries the false-positive shapes with
their measured frequencies, the pre-deletion checklist, and how to report the
result. This skill exists for the part the chapter cannot do for you: **work out
what the report can and cannot see on this particular project, before you trust
a single row.**

Do that first, because every check below changes how the output should be read —
and skipping one is how a live class ends up on a deletion list.

## Establish the ground first

Run the report and answer these against the project in front of you.

**Are framework roots actually supplied?** The summary prints
`roots: N (M from plugins, …)`. On a framework application `0 from plugins`
means nothing is naming your controllers, jobs or policies, so most of the
report is noise. Stop and fix the plugin configuration — `rigor docs
07-plugins` — rather than adjudicating hundreds of rows.

**Does the project ship signatures?** If `signature_paths:` is configured, also
run with it emptied and compare:

```sh
rigor unused                            # normal
rigor unused --config /tmp/no-sig.yml   # a copy of your config with signature_paths: []
```

Adjudicate the union. On one application the signature-free run surfaced three
genuinely dead classes that the default run never showed. Rows that appear only
without signatures are still worth checking — signatures reference classes, and
a reference the report counts is not always one a human would.

**What do `paths:` actually cover?** Only Ruby under those paths is analysed.
Views are the common gap: a helper called from `app/views/**/*.erb` has no Ruby
caller at all, and will land in the report looking unused. Before believing any
helper or presenter row, grep the view tree for it.

**Is the git history usable?** The chapter's checklist uses "when did this file
last change" as evidence. In a shallow clone, or one whose history is all
dependency bumps, that signal is empty — notice it and say so rather than
reporting a bot commit as the file's age.

## Then hand off to the chapter

With that established, follow the chapter. Two things worth holding onto as you
go, because they are what the report's own design is built around:

**Framework conventions and configuration reach code without naming it.** The
chapter lists the shapes; the ones that recur hardest are a class named as a
*string* in `config/*.yml` (a recurring-job schedule, a queue definition), a
convention that derives one name from another (`FooHelper` from
`FooController`, a decorator from a model, a join model from
`has_many :speakers_talks`), and a registration DSL called inside the class
body. None of these appear as a constant anywhere.

**Wrong rows cascade.** A class used only by a wrongly-classified class follows
it into the report. When a row turns out to be live, re-check what it
references before treating those rows as independent findings.

## Two habits that keep the answer honest

**A search that finds nothing proves nothing until it has found something.**
Before concluding a name appears nowhere, run the same search against a name you
know is used. Silence from a broken command and silence from dead code look
identical.

**Over-claiming hides dead code; under-claiming does not.** If you cannot settle
a row, leave it in the report and say you could not settle it. A row left on the
list is visible to a human; a row you dismissed on a hunch is invisible to
everyone.
