# Effect labels — ten user stories, adjudicated against the corpus (2026-08-23)

Status: **survey note, no design commitments.** It answers one question — *which questions can the
ADR-103 effect system actually answer today, on a real application?* — by writing down the stories a
Ruby/Rails team would bring to it and running each one against two survey checkouts. Where a story
fails, the note names the mechanism rather than the symptom.

Companion to [`20260822-effect-user-story-redmine.md`](20260822-effect-user-story-redmine.md), which
walked the *surface* a first adopter meets. This note assumes the surface and asks about the *value*.

## Harness

| | |
| --- | --- |
| Rigor | master `d4044170` (`0.3.4`), run from the repo through the Flake |
| Targets | `rigor-survey/redmine` @ `a12198ea0`, `rigor-survey/mastodon` @ `163f96cee` (v4.6.3) |
| Config | each project's own `.rigor.dist.yml`, plus `rigor-railties`, `effects: {snapshot: {reach: [rails]}}`, and a scratch cache + snapshot path. Baseline off. |
| Cleanup | every scratch config, cache and snapshot lives outside the checkouts or is deleted; both working trees are byte-identical to their pre-session state |

Cost, for the CI story (`/usr/bin/time -p`, 12-core Darwin):

| | redmine | mastodon |
| --- | --- | --- |
| `rigor effects` (cold) | 12.64 s, 31,782 lines | 24.02 s, 37,057 lines |
| `rigor effects update` (warm) | 0.97 s | 1.34 s |
| `rigor effects check` (warm) | 1.93 s | 2.54 s |

Shape of the two artefacts:

| | redmine | mastodon |
| --- | --- | --- |
| report rows | 4,234 | 7,468 |
| rows hedged ` …?` | 3,954 (93.4 %) | 6,816 (91.3 %) |
| rows saying nothing (`[] …?`) | 1,480 (35.0 %) | 2,837 (38.0 %) |
| snapshot `methods:` | 1,879, **41.2 % exhaustive** | 3,227, **44.8 % exhaustive** |
| snapshot `reach:` | 491, **2.4 % exhaustive** | 1,107, **8.7 % exhaustive** |

> **Measurement trap, recorded because it cost a round.** The snapshot's wire form omits
> `exhaustive:` when it is *true* (`snapshot.rb:63`), so a reader that does `v['exhaustive']` gets
> `nil` on every exhaustive row and reports **0 %**. Use `v.fetch('exhaustive', true)`. The first
> version of this note's headline number was that artefact.

## The catalogue

| # | Story | Verdict |
| --- | --- | --- |
| US-1 | *As a reviewer, I want to see whether this PR grew an entry point's effect footprint.* | ✅ **works, and is the feature's best surface** |
| US-2 | *As a maintainer, I want `Time.now` / `rand` kept out of a layer so its tests are deterministic.* | ✅ works |
| US-3 | *As an auditor, I want every request path that reads `ENV` or can end the process.* | ✅ works |
| US-4 | *As CI, I want a gate that fails when the footprint drifts.* | ✅ works, ~2 s warm |
| US-5 | *As an architect, I want "this layer does not touch the database" enforced.* | ⚠️ **the snapshot gate catches it; no diagnostic ever can** |
| US-6 | *As an on-call engineer, I want to know which code talks to the network.* | ⚠️ right answer for the wrong reason (redmine); absent (mastodon); one config line recovers the report |
| US-7 | *As an adopter, I want my provably pure methods so I can annotate them.* | ⚠️ 449 of them exist and are omitted by default |
| US-8 | *As an SRE, I want the actions I can route to a read-only replica.* | ❌ **empirically wrong: 0 of 27 `#update` actions record a DB write** |
| US-9 | *As a reviewer, I want to follow job enqueues, mail sends and cache writes.* | ❌ `job.*` / `email.*` have **zero producers** across 11,702 rows |
| US-10 | *As a new adopter, I want a first look at what my app does.* | ❌ 31k–37k unpaged lines ([#434](https://github.com/rigortype/rigor/issues/434)) |

Four work, three work partially, three do not.

---

## ✅ US-1 — "did this PR grow an entry point's footprint?"

A one-line edit standing in for a plausible PR, in `Issue.load_visible_relations`:

```ruby
Net::HTTP.get(URI("#{Setting.host_name}/api/relation-metrics")) if Setting.rest_api_enabled?
```

`rigor effects check` — ten lines, exit 1:

```
methods:
  Issue.load_visible_relations  +symbol [io.net.http] …?

reach:
  IssuesController#index  + io.net.http
```

and `rigor effects explain` names the path without being asked which symbol:

```
reach:
  IssuesController#index → Issue.load_visible_relations → Net::HTTP.get [io.net.http]
```

This is the whole promise, delivered: a reviewer who has never seen the file learns that the issue
list now makes an HTTP request. `explain` is uniformly good — the chains it prints on untouched code
are legible too (`IssuesController#index → QueriesHelper#query_to_csv → … → Redmine::Themes.scan_themes
→ Dir.glob [io.fs.read]`).

One wart: the method's own row reads `+symbol`, not "gained `io.net.http`", because the method had no
snapshot row before the edit — it had no effects, so [#411](https://github.com/rigortype/rigor/issues/411)
omitted it. The *reach* row carries the news, which is the row that matters.

## ✅ US-2 — determinism as a layer bound

`effects.envelopes:` over a layer, `effect: []`, is the surface that works. On redmine
`app/helpers/**/*.rb`: **343 findings across 25 files** (matching chapter 03's number). On mastodon
`app/serializers/**/*.rb`: **56 across 4**. What they name:

| label | redmine helpers | mastodon serializers |
| --- | --- | --- |
| `mutate.self` | 91 | 45 |
| `mutate.static` | 86 | 1 |
| `io.fs.read` | 83 | — |
| `mutate.instance` | 38 | — |
| `global.read` | 16 | 7 |
| `io.output.stderr` / `exit` | 13 / 13 | — |
| `nondet.time` | 3 | 3 |
| **`io.db.*`** | **0** | **0** |

Every one of these is real and every message carries its chain. For the deterministic-layer story
that is enough: `nondet.time`, `nondet.random`, `global.read`, `io.fs.*` are all proven labels, so a
bound over them fires.

## ✅ US-3 — the audit stories

Proven labels, whole-report counts:

```
redmine   mutate.self 1648  mutate.local 660  mutate.static 642  io.fs.read 501  mutate.instance 350
          global.read 339   io.output.stderr 248  exit 248  io.net 215  io.fs.write 138
          nondet.time 100   io.process 94   io 84   nondet.random 62
mastodon  mutate.self 2659  global.read 669  mutate.static 616  nondet.time 569  nondet.random 401
          mutate.local 263  io.fs 118  io.fs.write 108  mutate.instance 50  global.write 47
          io 37  io.net 36  io.fs.read 18
```

Spot-checked and true: redmine's 248 `exit` rows all descend from lazy configuration loading —

```
ApplicationController#user_setup → … → Redmine::Configuration.[] → Redmine::Configuration.load → Kernel#abort [exit]
```

— i.e. *every request path in Redmine can abort the process on a malformed `configuration.yml`*. That
is a genuinely useful thing to have learned from a tool, and no reviewer would have found it by eye.

## ✅ US-4 — the CI gate

`rigor effects check` warm is 1.93 s (redmine) / 2.54 s (mastodon) and exits 1 on drift. Nothing
about the gate is in question; it is the cheapest surface in the feature.

---

## ⚠️ US-5 — "this layer must not touch the database"

The flagship Rails policy. It cannot be a diagnostic, and it can be a gate.

**Why no diagnostic.** `io.db.read` and `io.db.write` are, across 11,702 report rows on two Rails
applications, **never once in the proven lane**:

| | redmine | mastodon |
| --- | --- | --- |
| `io.db.read` proven / declared | 0 / 709 | 0 / 1,975 |
| `io.db.write` proven / declared | 0 / 644 | 0 / 1,283 |

They are plugin facts, and `plugin_facts.rb` routes every plugin row through `add_declared`
(`unit_scan.rb:296`). `EnvelopeCheck` reads the proven lane only, deliberately and documented as
load-bearing (`envelope_check.rb:14-20`). So the two rules compose into: *no envelope, no `%a{pure}`,
no `effect.envelope-exceeded` can ever fire on a database access.*

The corpus shows what that looks like from the reader's chair.
`REST::V1::InstanceSerializer#invites_enabled` sits under an `effect: []` envelope and reports:

```
warning: Method REST::V1::InstanceSerializer#invites_enabled performs mutate.self
  (receiver-mutation via UserRole.everyone → UserRole.create! → UserRole#set_position),
  but is declared effect: [] at .rigor.yml effects.envelopes[0], so mutate.self exceeds the envelope.
```

The chain the message prints goes through **`UserRole.create!`**. Rigor saw the write, walked through
it, and reported the ivar assignment beyond it. The serializer's own report row reads
`≤ [io.db.read, io.db.write]`, so the fact is in the file — in the lane the judge is forbidden to read.

**Why it is still a gate.** The snapshot records the declared lane and diffs it. Adding
`Journal.create!(:notes => "audit")` to the same call path produces:

```
reach:
  IssuesController#index  + io.net
  IssuesController#index  ≤+ io.db.write
```

`≤+` is a first-class drift marker. So "no new database writes in this layer" *is* enforceable
today — through `rigor effects check`, not through `effects.envelopes:`. Nothing in the manual says
so; chapter 19 presents declared bounds as the place Rigor judges and the snapshot as the place it
observes, which is exactly backwards for the label a Rails team cares most about.

## ⚠️ US-6 — "which code talks to the network?"

**Redmine answers, for the wrong reason.** 215 rows carry proven `io.net`, including every
`Mailer#*`, every model `save`/`create!`, and `Redmine::IMAP.check`. The origin, on every sampled row
outside `WebhookEndpointValidator`:

```
Redmine::IMAP.check → MailHandler.safe_receive → … → Mailer#mail → Mailer.message_id_for
  → Mailer.token_for → Socket.gethostname [io.net]
```

`Socket.gethostname` — building a Message-ID. The IMAP connection that method opens is invisible; so
is SMTP delivery. `Mailer.deliver_lost_password` reads `[io.net, mutate.instance, mutate.local,
mutate.self] ≤ [global.read, rails.i18n.translate]` — no `email.send`, no `io.net.smtp`, nothing from
`rigor-actionmailer` about delivery at all. A reviewer who trusts the label reaches the right
conclusion by luck, and 5 % of the application is coloured "network" by a hostname lookup.

**Mastodon does not answer.** An application whose entire purpose is federated HTTP proves `io.net`
on 36 of 7,468 rows and `io.net.http` on 1. Its HTTP chokepoint reads:

```
Request#perform: [mutate.self] …?
```

because the request is issued through the `http.rb` gem, which has no signatures and no plugin — so
the call taints and proves nothing.

**What the user can do today, and it works.** One line of configuration:

```yaml
effects:
  attribution:
    "Request#perform": [io.net.http]
```

takes mastodon from 1 row to **250** carrying `io.net.http`, including `AccountAlias#invalid?` —
which really does perform a remote ActivityPub fetch during validation:

```
AccountAlias#invalid? → AccountAlias#set_uri → ResolveAccountService#call → ResolveAccountService#fetch_account!
  → ActivityPub::FetchRemoteAccountService#call → … → ActivityPub::ProcessAccountService#call → Time.now [nondet.time]
```

That is a finding worth the price of the whole feature — *validating a model performs a network
fetch* — and it arrives from one config line. But it lands in the declared lane (US-5's rule), so it
can inform a review and can gate the snapshot, and can never be a bound.

## ⚠️ US-7 — "which of my methods are provably pure?"

`rigor effects --full` on redmine: 32,231 lines, of which **449 rows are exhaustive with nothing
beyond `mutate.local` and no declared lane** — `AnonymousUser#destroy`, `AnonymousUser#admin`,
`ActiveRecord::Acts::Tree::InstanceMethods#root`, … These are exactly the methods worth annotating
`%a{pure}`, worth memoising, worth calling from a view. The default report omits them by
construction, the snapshot omits them too, and no flag asks for them.

The general shape: **the report has no query surface.** There is no `--label io.net`, no
`--only-exhaustive`, no `--pure`, no ordering but alphabetical. Every question in this note was
answered with `grep` and a Ruby script over the artefacts. [#434](https://github.com/rigortype/rigor/issues/434)
proposes to make the report *smaller*; being able to *ask* it something is a different feature.

---

## ❌ US-8 — "which actions can go to a read-only replica?"

The negative query. It fails, and it fails in the worst way: the answer looks confident and is wrong.

| | redmine | mastodon |
| --- | --- | --- |
| `reach:` entries carrying `io.db.write` | 27 / 491 | 114 / 1,107 |
| `#create` actions carrying it | 9 / 30 | 35 / 86 |
| `#update` actions carrying it | **0 / 27** | 8 / 41 |
| `#destroy` actions carrying it | 1 / 32 | 9 / 59 |

Redmine has twenty-seven `#update` actions and not one of them records a database write.

**The A/B, inside one controller.** `GroupsController` — same class, same `@group.save` call:

```ruby
def create
  @group = Group.new                    # ← assigned here
  @group.safe_attributes = params[:group]
  … if @group.save                      # → reach records ["io.db.read", "io.db.write"]

def update
  @group.safe_attributes = params[:group]   # @group comes from `before_action :find_group`
  … if @group.save                          # → reach records []
```

> **Correction, 2026-08-24 — this note first read that pair as "an ivar assigned by a `before_action`
> is untyped", and that was wrong.** `find_group` is in `GroupsController` itself, not in a
> superclass, so nothing here is a cross-class flow. Two separate mechanisms were being read as one:
>
> 1. **A union receiver projected to no class at all** ([#455](https://github.com/rigortype/rigor/issues/455), fixed
>    2026-08-24). [ADR-58](../adr/58-ivar-field-typing.md) contributes a declaration-sourced `nil` to
>    every ivar `initialize` does not write, so *every cross-method ivar read is a `T | nil`* — and the
>    effect collector's receiver projection had no union arm. The call contributed no label and no edge
>    **while the row still read exhaustive**. The same hole swallowed every `find_by` + `&.` site, which
>    is why it was worth more than the ivar framing: `featured_tag&.destroy!` in Mastodon's
>    `ActivityPub::Activity::Remove#remove_featured_tags` is an ivar-free instance of it.
> 2. **`Group.visible.find(params[:id])` types `Dynamic`** — an ActiveRecord scope chain nothing models
>    — so `GroupsController#update` is a plain `dynamic-receiver`, which the report *does* disclose. It
>    is an ordinary inference gap, not a silent one, and the union fix does not touch it. What separated
>    the two actions was never where the ivar was assigned but how it was *produced*: `Group.new` types,
>    a scope chain does not.
>
> With #455 fixed, the table's after-figures are: redmine `io.db.write` reach entries **27 → 35** and
> `#update` **0 / 27 → 3 / 27**; mastodon **114 → 169** and `#update` **8 / 41 → 21 / 43**,
> `#destroy` **9 / 59 → 23 / 64**. `rigor check`'s diagnostic stream is byte-identical on both. The
> verdict on the story does not change — a negative reading is still unlicensed — but its size does.

`IssuesController#update` shows the second mechanism from the other side: its reach explains
`mutate.self`, `mutate.local`, `mutate.static` and `global.read` through
`save_issue_with_child_records`, and (before #455) nothing at all about `@issue.save`.

**So the effect system's Rails value is bounded by receiver typing** — the union projection above, and
beyond it the ActiveRecord scope chains that type `Dynamic`. Every US-5 and US-8 number in this note
moves when those move.

Compounding it: `reach:` rows are exhaustive for **2.4 %** (redmine) / **8.7 %** (mastodon) of entry
points, so a negative reading is unlicensed 91–98 % of the time — and the report says so only through
a trailing ` …?` that is present on nine rows in ten, which is not a signal, it is wallpaper.

## ❌ US-9 — jobs, mail, cache

The application-meaning labels — the vocabulary layer that exists precisely so a policy can name
something a person cares about — have no producers on either application:

| label | redmine | mastodon |
| --- | --- | --- |
| `job.enqueue` | 0 | 0 |
| `email.send` | 0 | 0 |
| `cache.read` / `cache.write` | 0 / 0 | declared only, 108 / 518 |
| `telemetry` | declared only, 65 | declared only, 265 |

Mastodon runs on Sidekiq with `rigor-sidekiq` loaded and has 219 `perform_async` / `perform_later`-shaped call sites;
redmine has 97 `deliver_*` call sites with `rigor-actionmailer` loaded. Neither plugin attributes
the label its own domain owns. `docs/manual/19-effect-labels.md` prints all five meaning labels in the
vocabulary table with no indication that nothing produces them.

## ❌ US-10 — the first look

Unchanged from the 2026-08-22 walk and already filed as
[#434](https://github.com/rigortype/rigor/issues/434): 31,782 / 37,057 unpaged lines, 35–38 % of rows
content-free.

---

## Three findings that outlive the stories

1. **The proven lane is about the process; the declared lane is about the application — and only the
   proven lane can be judged.** `mutate.*`, `io.fs.*`, `nondet.*`, `global.*`, `exit` are proven and
   enforceable. `io.db.*`, `cache.*`, `telemetry`, every `rails.*` and every `attribution:` the user
   writes are declared and unenforceable. That split is correct per ADR-103's discriminating
   criterion — an unverified claim must not manufacture a finding — but its consequence has never
   been stated: **on a Rails application, every effect a team would write a policy about is in the
   unjudgeable lane.** The snapshot's `≤+` marker is the escape hatch and is undocumented as such.

2. **Rails effect visibility equals receiver typing.** The `GroupsController#create` / `#update` A/B is
   the whole story in nine lines of application code — but see the correction under US-8: it is two
   mechanisms, not one. The first, a union receiver projecting to no class, was an effects bug and is
   [#455](https://github.com/rigortype/rigor/issues/455), fixed 2026-08-24 (+8 / +55 write-recording
   entry points). The second, an ActiveRecord scope chain typing `Dynamic`, is an inference gap and
   remains the highest-value lever — and it is not an effects issue.

3. **A negative reading is never licensed and nothing at the point of reading says so.** 2.4 % / 8.7 %
   exhaustive on `reach:`. The ` …?` hedge cannot carry that weight at 93 % density; a reader needs the
   *summary* ("2.4 % of entry points are exhaustive — absence means nothing here") before the rows.

## Filed

- [#454](https://github.com/rigortype/rigor/issues/454) — every label a Rails policy would name lives in the lane no diagnostic can read (design call)
- [#455](https://github.com/rigortype/rigor/issues/455) — a union-typed receiver projected to no class, so every cross-method ivar read and every `find_by` + `&.` contributed nothing while reading exhaustive (**fixed 2026-08-24**; filed under a mechanism that turned out to be wrong — see the correction under US-8)
- [#456](https://github.com/rigortype/rigor/issues/456) — `job.*` and `email.*` have zero producers; the Rails plugins attribute neither
- [#457](https://github.com/rigortype/rigor/issues/457) — `rigor effects` has no query surface; the pure set (449 methods on redmine) is the one answer nobody can ask for
- [#458](https://github.com/rigortype/rigor/issues/458) — `Socket.gethostname` proves `io.net`, colouring 5 % of Redmine's rows as network

US-10 is [#434](https://github.com/rigortype/rigor/issues/434), already open.
