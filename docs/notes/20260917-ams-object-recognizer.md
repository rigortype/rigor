# The AMS `object` recognizer, measured on Mastodon

**Date:** 2026-09-17
**Issue:** [#534](https://github.com/rigortype/rigor/issues/534) item 6
**Plugin:** `plugins/rigor-active-model-serializers/`

The 2026-09-01 corpus opacity sweep named `object` Mastodon's single largest unresolved
implicit-self send and recorded that no plugin owned ActiveModelSerializers. This is the
before/after that shipped the recognizer, and the evidence for the one risky thing it does:
declaring `ActiveModel::Serializer`, a class the project's own code inherits from.

## Method

A private copy of the survey checkout (`rsync -a --exclude .rigor`), so the measurement state under
`rigor-survey/` is untouched. Two configurations, identical but for one `plugins:` entry, both
derived from the project's `.rigor.dist.yml` with `baseline:` removed so every diagnostic is
emitted, both run `--no-cache` — a warm run can serve a pre-change answer and has silently masked
exactly this kind of diff before.

## Diagnostics: no change at all

| run | diagnostics |
| --- | --- |
| plugin off | 2358 |
| plugin on | 2358 |

The sorted `path:line:column:rule:message` sets are **byte-identical**. No new diagnostic, false
positive or otherwise, and none lost.

That is the answer to the declaration risk. `ActiveModel::Serializer` is declared with an empty body
and 93 of Mastodon's serializers inherit from it directly, with 60 more reaching it through
`ActivityPub::Serializer`; every member the signature omits — `object`, `scope`, `attributes`,
`has_many`, `read_attribute_for_serialization` — stayed lenient, as the manifest's `open_receivers:`
row intends. The same holds for `ActiveModelSerializers::Model`, which eight Mastodon models
subclass.

## Precision: +7.1 points on `app/serializers`

| run | precise expressions |
| --- | --- |
| plugin off | 4893 / 9575 (51.1%) |
| plugin on | 5572 / 9575 (58.2%) |

Same lens, same scope, same commit, one plugin entry apart — the only comparison of two coverage
numbers this project treats as meaningful.

## What the derivation answers, and what it declines

Probed with `Rigor.dump_type(object)` reopened onto three real serializers:

| serializer | off | on |
| --- | --- | --- |
| `REST::AccountSerializer` | `Dynamic[top]` | `Account` |
| `REST::StatusSerializer` | `Dynamic[top]` | `Status` |
| `REST::ContextSerializer` | `Dynamic[top]` | `Dynamic[top]` |

The third row is the design, not a miss. `Context` exists in Mastodon — as
`class Context < ActiveModelSerializers::Model`, a plain value object, so it is absent from
`rigor-activerecord`'s model index and nothing corroborates the name. The recognizer declines rather
than naming a class it cannot check, which is what keeps the diagnostic delta at zero.

## Deliberately not measured

SimpleForm inputs. The sweep's 875-site `object` count mixes AMS serializers (751 sites in
`app/serializers`) with `SimpleForm::Inputs::Base#object`, whose resource is named by the
`simple_form_for` call site rather than by the input class — a different gem and a different
derivation, for a `rigor-simple-form` that does not exist yet.

`rigor-pundit` (`authorize`, 317 sites) and `rigor-devise` (`current_user`, 196) remain
silent-but-loaded on Mastodon exactly as the sweep measured them. Nothing here touches either.
