# The AMS `object` recognizer, measured on Mastodon

**Date:** 2026-09-17
**Issue:** [#534](https://github.com/rigortype/rigor/issues/534) item 6
**Plugin:** `plugins/rigor-active-model-serializers/`

The 2026-09-01 corpus opacity sweep named `object` Mastodon's single largest unresolved
implicit-self send and recorded that no plugin owned ActiveModelSerializers. This is the before/after
that shipped the recognizer, and — more usefully — the record of what a zero-diagnostic-delta corpus
diff could NOT see, which is what the derivation rule ended up being built around.

## Method

A private copy of the survey checkout (`rsync -a --exclude .rigor`), so the measurement state under
`rigor-survey/` is untouched. Two configurations, identical but for one `plugins:` entry, both
derived from the project's `.rigor.dist.yml` with `baseline:` removed so every diagnostic is emitted,
both run `--no-cache` — a warm run can serve a pre-change answer and has silently masked exactly this
kind of diff before.

## What the corpus diff cannot see, and why the name is not enough

The first version of this plugin derived `object` from the `<Model>Serializer` naming convention
alone, checked only against the existence of a model of that name. It produced a byte-identical
diagnostic set on Mastodon, and it was **wrong on three serializers**:

| serializer | derived | actual resource |
| --- | --- | --- |
| `REST::ConversationSerializer` | `Conversation` | `AccountConversation` |
| `REST::InstanceSerializer` | `Instance` | `InstancePresenter` |
| `REST::V1::InstanceSerializer` | `Instance` | `InstancePresenter` |

Nothing in the diff moved, because an Active Record model's method surface is open: a
wrong-but-real model absorbs every read in silence. **A corpus diagnostic diff is not evidence that a
contributed type is correct** — it is evidence that the type did not make the checker louder. For a
plugin whose whole product is a type, the check has to be a positive one made before the answer is
contributed.

So the rule gained a second, independent signal: the model must ANSWER the serializer. Every name the
serializer reads off its resource — the `attributes` / `attribute` / `has_many` / `has_one` /
`belongs_to` declarations it does not define itself, plus every `object.<name>` in its body — must be
a column, per-column predicate, association, enum, alias or scope of the candidate model, or a method
the project defines on that model or an ancestor. One unanswered name declines the whole serializer.

All three rows above now resolve to `Dynamic[top]`, verified by a `Rigor.dump_type(object)` probe
reopened onto each; a control (`REST::ScheduledStatusSerializer`) still derives `ScheduledStatus` in
the same run.

## Numbers

| | plugin off | plugin on |
| --- | --- | --- |
| diagnostics | 2358 | 2358 |
| precise expressions, `app/serializers` | 4893 / 9575 (51.1 %) | 5093 / 9575 (53.2 %) |

The sorted `path:line:column:rule:message` sets are byte-identical. Reach: **173 serializers
discovered, 52 resolve a unique model name, 33 derive.**

The byte-identical set is also the answer to the one risky thing the bundled signature does.
`ActiveModel::Serializer` is declared with an empty body and 93 of Mastodon's serializers inherit
from it directly; `ActiveModelSerializers::Model` is subclassed by eight of its models. Every member
the signature omits stayed lenient, as the manifest's `open_receivers:` rows intend.

## The 19 declines that are the model index's gap, not the serializer's

Of the 52 serializers that resolve a name, 19 are declined by the surface check. Three are the
genuine misses above. The other 16 name a model that IS the right one and whose surface the
`:model_index` fact cannot fully see:

| serializer | unanswered | why the model does answer it |
| --- | --- | --- |
| `REST::AccountSerializer` | `followers_count`, `following_count`, `statuses_count`, `user`, `moved_to_account`, `avatar`, `header`, … | `delegate … to: :account_stat` in `Account::Counters`; associations declared in a concern's `included do`; Paperclip attachment macros |
| `REST::StatusSerializer` | `limited_visibility?` | a concern-declared method |
| `REST::MediaAttachmentSerializer` | `file`, `thumbnail` | attachment macros |
| `REST::PreviewCardSerializer` | `image`, `image?`, `original_url` | attachment macros + a concern |

The cause is one thing wearing three hats: `delegate`, concern-declared associations, and attachment
macros are all model surface that `rigor-activerecord`'s discoverer does not fold. #534 item 5 just
landed the same fold for concern-declared SCOPES; extending it to associations and `delegate` is the
lever that would recover Mastodon's two largest serializers here, and it belongs in that plugin
rather than this one.

Declining is the safe direction — the site keeps the answer it had — so this ships as it is rather
than loosening the check. A proportional or best-candidate rule was considered and rejected: a
decorator around a model shares most of the model's surface, so "most names answered" is exactly the
shape the `InstancePresenter` case has.

## The ancestry closure needs `app/lib`

The default `serializer_search_paths` is `["app/serializers", "app/lib"]`, and the second entry is
load-bearing rather than decorative. `ActivityPub::Serializer`, the parent of 60 of Mastodon's
serializers, lives at `app/lib/activitypub/serializer.rb`. Measured index size:

| search paths | serializers discovered |
| --- | --- |
| `["app/serializers"]` | 108 |
| `["app/serializers", "app/lib"]` | 173 |

Membership of that closure is the ONLY serializer gate. An earlier version also admitted any class
whose name ended with `Serializer`, which typed `object` inside a `Json::ConversationSerializer` with
no serializer ancestry and an `object` method of its own — erasing a true positive. `object` is an
ordinary method name and the suffix is not evidence.

## Deliberately not measured

SimpleForm inputs. The sweep's 875-site `object` count mixes AMS serializers (751 sites in
`app/serializers`) with `SimpleForm::Inputs::Base#object`, whose resource is named by the
`simple_form_for` call site rather than by the input class — a different gem and a different
derivation, for a `rigor-simple-form` that does not exist yet.

`rigor-pundit` (`authorize`, 317 sites) and `rigor-devise` (`current_user`, 196) remain
silent-but-loaded on Mastodon exactly as the sweep measured them. Nothing here touches either.
