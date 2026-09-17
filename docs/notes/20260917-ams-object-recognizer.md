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
discovered, 52 resolve a unique model name, 34 derive.**

The byte-identical set is also the answer to the one risky thing the bundled signature does.
`ActiveModel::Serializer` is declared with an empty body and 93 of Mastodon's serializers inherit
from it directly; `ActiveModelSerializers::Model` is subclassed by eight of its models. Every member
the signature omits stayed lenient, as the manifest's `open_receivers:` rows intend.

## The 18 declines, and why 15 of them are the model index's gap

Of the 52 serializers that resolve a name, 18 are declined by the surface check. Three are the
genuine misses above. The other 15 name a model that IS the right one and whose surface the
`:model_index` fact cannot fully see:

| serializer | unanswered | why the model does answer it |
| --- | --- | --- |
| `REST::AccountSerializer` | `followers_count`, `following_count`, `statuses_count`, `user`, `moved_to_account`, `avatar`, `header`, … | `delegate … to: :account_stat` in `Account::Counters`; associations declared in a concern's `included do`; Paperclip attachment macros |
| `REST::StatusSerializer` | `limited_visibility?` | a concern-declared method |
| `REST::MediaAttachmentSerializer` | `file`, `thumbnail` | attachment macros |
| `REST::PreviewCardSerializer` | `image`, `image?`, `original_url` | attachment macros + a concern |

The cause is one thing wearing three hats: `delegate`, concern-declared associations, and attachment
macros are all model surface that `rigor-activerecord`'s discoverer does not fold. #534 item 5 landed
the same fold for concern-declared SCOPES and nothing covers these three, so the follow-up is filed
as [#1049](https://github.com/rigortype/rigor/issues/1049), with the full per-serializer table and an
acceptance gate that re-runs the reach probe below. That fold has since landed — see the dated
section at the end of this note for the re-measurement, which recovers seven of the fifteen. It belongs in that plugin rather than this one:
the other consumers of `:model_index` fail OPEN on an unseen name and are merely quieter for it,
while this one fails closed and is the reason the gap is now visible.

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

## Reader spellings the check does not read

A handful of ways to read the resource are not collected as evidence, so a serializer that uses one
declines even where the model is right: `object[:key]`, `object.title = x`, `object.try(:name)`,
`object.present?` (an ActiveSupport method, absent from the model's index row), and an
`attribute(:x) { ... }` block form, whose name is still required of the model although the block
renders it. Each is the safe direction — a decline, not a wrong type — and none of them occurs in
Mastodon's `app/serializers`, so the measured reach above is unaffected.

## Deliberately not measured

SimpleForm inputs. The sweep's 875-site `object` count mixes AMS serializers (751 sites in
`app/serializers`) with `SimpleForm::Inputs::Base#object`, whose resource is named by the
`simple_form_for` call site rather than by the input class — a different gem and a different
derivation, for a `rigor-simple-form` that does not exist yet.

`rigor-pundit` (`authorize`, 317 sites) and `rigor-devise` (`current_user`, 196) remain
silent-but-loaded on Mastodon exactly as the sweep measured them. Nothing here touches either.

---

## 2026-09-17 — after the `:model_index` macro fold (#1049)

`rigor-activerecord` 0.10.0 folds three macro families into the model entry and the published fact:
`delegate` (model body, a concern's `included do`, and a concern module's own top level), the
associations a concern declares in its `included do`, and the Paperclip / Active Storage attachment
macros — plus an `enum`'s per-value predicates, which the table above counts under the concern
family. This is the re-measurement the acceptance gate asked for.

### Method

Same as above, with one change: the two arms are the SAME plugin set on the SAME private copy, and
what differs between them is `plugins/` at `origin/master` versus at this branch's HEAD. The plugin
is on in both arms, because what is being measured is the fold, not the recognizer.

The reach probe is a `def __rigor_probe__ = Rigor.dump_type(object)` inserted into every class under
`app/serializers` on a second private copy, so the count covers every serializer rather than the ones
that happen to read `object` already. That method costs two numbers of comparability with the table
above: it probes 256 classes rather than the 173 the discoverer indexes (it probes nested and
non-serializer classes too), and its pre-change derive count is 36 rather than 34 (this is a later
checkout of the survey copy than the one measured above).

### Corpus adjudication

| | `plugins/` at origin/master | `plugins/` at this branch |
| --- | --- | --- |
| Mastodon diagnostics | 2536 | 2536 |
| Redmine diagnostics | 1702 | 1702 |

Sorted `path:line:column:rule:message` sets **byte-identical on both projects**. That is the result
the issue predicted and the one the fold has to produce: every consumer of `:model_index` WIDENS a
known-name set with what is folded here, so a new firing would mean a fold that invented a name.

The concern fold does one thing that is not purely a widening, and it is worth naming: a concern's
`has_one :account_stat` now narrows `account.account_stat` to `AccountStat | nil` where it used to
be `Dynamic`, and a narrowed receiver is a receiver whose calls get checked. The byte-identical
Mastodon set is the evidence that this did not turn into a new `call.undefined-method`.

### Reach

| | before | after |
| --- | --- | --- |
| serializer classes probed | 256 | 256 |
| `object` derives a model | 36 | 43 |

Seven of the issue's fifteen declines are recovered, including both of the project's largest
serializers:

| serializer | `object` now types as | family |
| --- | --- | --- |
| `REST::AccountSerializer` | `Account` | 1 + 2 + 3 |
| `REST::Admin::AccountSerializer` | `Account` | 1 + 2 |
| `REST::StatusSerializer` | `Status` | enum predicates from a concern |
| `REST::MediaAttachmentSerializer` | `MediaAttachment` | 3 |
| `ActivityPub::NoteSerializer::MediaAttachmentSerializer` | `MediaAttachment` | 3 |
| `REST::CollectionItemSerializer` | `CollectionItem` | 2 |
| `REST::AccountRelationshipSeveranceEventSerializer` | `AccountRelationshipSeveranceEvent` | 2 |

Nothing that derived before stopped deriving, and the three genuine misses
(`REST::ConversationSerializer`, `REST::InstanceSerializer`, `REST::V1::InstanceSerializer`) still
resolve to `Dynamic[top]` — the surface check is what keeps them there, and folding more surface
into the model does not weaken it.

### The eight still declined, and what they are actually blocked on

They are NOT blocked on the three families. Reading the unanswered names off each:

| serializer | unanswered after the fold | what defines it |
| --- | --- | --- |
| `REST::PreviewCardSerializer`, `ActivityPub::NoteSerializer::PreviewCardSerializer` | `original_url` | `attr_accessor :original_url` on `PreviewCard` |
| `REST::NotificationPolicySerializer`, `REST::V1::NotificationPolicySerializer` | `pending_requests_count`, `pending_notifications_count` | `attr_reader` on `NotificationPolicy` |
| `REST::ReportSerializer` | `collection_ids` | Rails' `<singular>_ids` reader, generated by `has_many :collections` |
| `REST::CustomEmojiSerializer` | `association(:category)` | `ActiveRecord::Base#association`, the framework's own instance API |
| `REST::TranslationSerializer::PollSerializer` | `poll_options` | not an Active Record model at all — `TranslationService::Translation::Poll` |

Three separate follow-ups, none of them a macro family this change covers: a plain `attr_*` on a
model that the engine's `user_def_through_ancestors` walk does not answer for; the `<singular>_ids` /
`<singular>_ids=` readers a collection association generates, which would be a one-line extension of
family 2 and recovers `REST::ReportSerializer`; and the un-modelled part of Active Record's own
instance surface. The last row is a `model_overrides` case, not a fold.

### Deliberately not folded

A concern's `included do` `enums:`, `validations:` and `callbacks:` stay where they were. The
name-only sets folded here can only make a consumer quieter; `enums:` drives
`Analyzer#validate_enum_value`, which FIRES, so folding a concern's enum COLUMN would put new
`unknown-enum-value` diagnostics on a corpus whose acceptance gate is "no new diagnostic". The enum's
value PREDICATES carry no such risk and are folded, which is what recovers `REST::StatusSerializer`.
