# ADR-39 — Plugins may invoke their target library's safe methods directly

Status: **Accepted, 2026-06-02.** The rule + harness are implemented and
validated: `Rigor::Plugin::Inflector` (slice 2) invokes the real
`ActiveSupport::Inflector` through the allow-list + rescue harness and
carries **no built-in approximation** (an approximation would emit wrong
facts → false positives; when the gem is absent it raises and the
caller's isolation boundary degrades to silence), and the three
consumers — `rigor-actionpack`,
`rigor-activerecord`, `rigor-rails-routes` (slice 4) — are migrated onto
it, deleting their hand-rolled inflection. Validated behaviour-preserving
against every plugin's golden-master integration spec **and** both
headline OSS corpora (Redmine and Mastodon `app + lib` rails-routes
diagnostics byte-identical before/after). A follow-up audit applied the
same rule to two more inflection reimplementations (`rigor-actionmailer`
view-path `underscore`, `rigor-factorybot` factory `camelize`) and to a
non-inflection case — `rigor-rspec-rails` now validates
`have_http_status(:symbol)` against the **real
`Rack::Utils::SYMBOL_TO_STATUS_CODE`** instead of a vendored snapshot
(declining when Rack is absent), confirming the rule generalises beyond
inflection to any target-library *fact* (data table) a plugin would
otherwise approximate. **Deferred (follow-on):** slice
3 (static ingestion of `config/initializers/inflections.rb` for
project-custom inflections — the default ActiveSupport ruleset already
covers the common cases; custom-rule isolation across projects in a
long-lived LSP process is the open design point), the `Ruby::Box`
isolation layer (slice 5 — the **chosen first-priority** isolation for
target-library invocation; see § "Isolation of target-library
invocation"), and the exact-version provisioning fallback (only if a
cross-version behavioural difference is
observed).

Records the decision to let a Rigor plugin **load and invoke the pure,
allow-listed methods of the library it targets**, through the same
bounded harness the engine already uses for constant folding. This is
the Ruby analogue of how a PHPStan extension runs inside the analyzed
application's autoloader and calls into the real framework classes. The
rule is deliberately narrow: it permits invoking a *trusted target
library's* pure methods; it does **not** relax ADR-2's prohibition on
executing the *analyzed application's own* code.

Motivating consumer: an inflection helper (`ActiveSupport::Inflector`)
shared by `rigor-rails-routes` / `rigor-activerecord` / `rigor-actionpack`
— see [the plugin boilerplate plan](../design/20260602-plugin-boilerplate-reduction-plan.md)
§ 0e, where unifying the hand-rolled `singularize` / `pluralize` copies
risks false positives precisely because they diverge from Rails' real
inflection rules.

## Context

### Two facts that are in tension

1. **ADR-2 forbids executing application code.** ADR-2 § "Plugin Trust
   and I/O Policy" states: *"Plugins must not execute application code.
   They may inspect parsed Ruby, RBS, generated signatures,
   configuration, dependency metadata, and cached plugin metadata."*
   This is the static-analysis identity of the tool — Rigor never runs
   the project under analysis.

2. **The engine already invokes real, pure library methods.** The
   constant-folding tier (`inference/method_dispatcher/constant_folding.rb`
   and its `*_folding.rb` siblings) evaluates literal expressions by
   calling the **real Ruby method** on a value Rigor constructed from a
   literal:

   ```ruby
   return nil unless PATHNAME_PURE_UNARY.include?(method_name)  # allow-list
   return nil unless receiver.is_a?(Pathname)                  # Rigor-built value
   result = receiver.public_send(method_name, arg)             # real invocation
   return nil unless foldable_constant_value?(result)          # result check
   Type::Combinator.constant_of(result)
   rescue StandardError                                        # total recovery
     nil
   ```

   The catalogue comment names the contract: *"pure … catalogue. Each
   method must … return a value safe to materialise … reads only …,
   writes no global state."* So Rigor's working safety model is already
   **allow-list of pure methods + Rigor-derived inputs + result check +
   rescue**, applied to Ruby core / standard-library methods.

These are only in tension if "library method" and "application code" are
conflated. They are not the same thing. Constant folding calls
`String#upcase` / `Pathname#basename` — methods of the *runtime*, not
the analyzed project's own definitions. The analyzed application's code
is never run.

### What PHPStan does

A PHPStan extension is loaded into the same process as the analyzed
application and resolves classes through the app's autoloader. Extensions
routinely **instantiate, reflect on, and call into the real framework
classes** (Doctrine metadata, Symfony container definitions, enum
cases). PHPStan's `bootstrapFiles` boot the framework so this works. The
analyzed *project source* is still not executed — but the *libraries it
depends on* are loaded and called. Rigor's constant-folding tier is the
same shape, restricted so far to core/stdlib.

### The cost of NOT allowing it

Because plugins cannot call their target library, they **reimplement**
it. The inflection helpers are the worst case: `rigor-activerecord` and
`rigor-rails-routes` each ship a hand-rolled `singularize` / `pluralize`
that approximates Rails' inflector. These approximations:

- **drift from the real rules** — they handle a handful of regular cases
  and a tiny irregular table; Rails ships a far larger default set plus
  whatever the project declares in `config/initializers/inflections.rb`.
- **feed name resolution** — an inflected model / route-helper name
  drives `unknown-helper` / `unknown-permit-key` diagnostics, so a
  divergence is not cosmetic: it is a **false positive on working code**,
  the cost Rigor weighs most heavily.

Unifying the copies (boilerplate plan § 0e) does not fix this — it just
picks one approximation. The real fix is to stop approximating.

## Working Decision

### The rule

> A Rigor plugin MAY declare a runtime dependency on the library it
> targets and **invoke that library's pure methods directly** to compute
> a result, provided every such call goes through the bounded harness
> below. Invoking a target library's safe methods is **not** "executing
> application code" in the sense ADR-2 prohibits: the target library is a
> trusted, declared dependency, distinct from the analyzed project's own
> source.

This generalises the engine's constant-folding tier from core/stdlib to
a plugin's declared target library, and brings Rigor's plugin model in
line with PHPStan's (extensions call into the real framework).

### The safety harness (the contract that makes a call permissible)

A plugin invoking a target-library method MUST satisfy all of:

1. **Pure method, by an explicit allow-list.** The plugin declares the
   exact set of methods it will call (e.g. `singularize`, `pluralize`,
   `underscore`, `camelize`, `classify`, `tableize`). Each must be
   side-effect-free, deterministic, and read no mutable global state. The
   allow-list is the greppable, auditable surface — never a dynamic
   `public_send(arbitrary_name)`.
2. **Rigor-derived inputs only.** Arguments are values Rigor constructed
   (a String read from a literal AST node, a name derived from source) —
   never an object obtained by running project code.
3. **Result is data, checked.** The return value is plain data the plugin
   converts to a type / fact (a String, an Array of Strings); the plugin
   validates the shape before use.
4. **Decline, never approximate.** When the target library cannot be
   loaded the invocation **raises** (or the caller gates on an
   `available?` check) — it does **not** fall back to a hand-rolled
   approximation. An approximation that diverges from the library's real
   behaviour is precisely the wrong fact this whole ADR exists to avoid;
   "no contribution" must mean **silence**, not a guess. The raise
   propagates to the existing per-plugin `rescue` / isolation boundary,
   so the inflection-dependent check degrades to no diagnostics (reduced
   coverage), never a wrong one and never a crash.

A method that fails any clause stays unsupported (the check degrades to
silence) — it is never answered by an approximation.

### The hard line: application code is still never executed

The rule covers the **target library**, not the **analyzed project**.
Concretely for the inflector:

- Calling `ActiveSupport::Inflector.pluralize("person")` — **allowed**
  (target-library pure method).
- Loading and running the project's
  `config/initializers/inflections.rb` to learn its custom inflections —
  **forbidden** (that is application code). The project's custom rules
  are obtained by **statically parsing** that initializer's small DSL
  (`inflect.irregular` / `plural` / `singular` / `uncountable` /
  `acronym`) with Prism — exactly as `rigor-rails-routes` already
  statically parses `config/routes.rb` — and feeding the extracted rules
  into the real inflector via its public API. No project code runs.

### Making the target library available

The plugin's **own gemspec** declares the dependency (`spec.add_dependency
"activesupport"` for an inflector plugin). When the plugin is installed,
its target is on the load path — the dependency belongs to the plugin,
not to Rigor core, so Rigor's own footprint is unchanged and a project
that does not use the plugin pays nothing. The plugin `require`s the
narrowest entry point it needs (`require "active_support/inflector"`,
not all of Rails) and loads it once.

**Version fidelity.** The default behaviour — depend on a compatible
range and use the library's own rules — is sufficient because a library's
*pure-function behaviour* (e.g. the default inflection ruleset) is stable
across versions; project-specific divergence lives in the statically
ingested config, not the gem version. Pinning the dependency to the
**exact version the analyzed project resolves** (reading its
`Gemfile.lock`, provisioning that version into a Rigor-managed isolated
gem directory) is the **maximal-fidelity fallback**, justified only if a
behavioural difference across versions is ever observed. It carries the
provisioning cost (first-run install, cache, offline-CI / hermetic-Flake
tension) and is therefore deferred until demanded.

### Isolation of target-library invocation — selectable strategy (`none` / `ruby_box` / `process`)

Loading a target library into Rigor's process risks contaminating Rigor
itself — chiefly through **monkey-patches to core classes** (a gem that
reopens `String` / `Hash` changes the Ruby that Rigor's own code runs
under) and **gem-version clashes** (Ruby allows one version of a gem per
process, so the target's version can collide with Rigor's own). How much
isolation is worth its cost depends on the deployment, so the isolation
is a **configurable strategy** (`.rigor.yml` `plugins_isolation:` /
`RIGOR_PLUGIN_ISOLATION` env), with three backends behind one interface:

| Strategy | Isolation | Crash containment | Cost | Notes |
| --- | --- | --- | --- | --- |
| `none` (direct) — **default** | none (loads into main space) | none | lowest | The library is trusted + pure, so for the common case this is fine; current slices 2/4 path. |
| `ruby_box` | monkey-patch + version (per-box) | **no** (a native crash still kills the process) | low (in-process) | Ruby 4.0 `Ruby::Box`, `RUBY_BOX=1` (re-exec). Experimental. |
| `process` (fork) | **full** (separate OS process) | **yes** (a child crash is contained; the parent declines) | higher (fork + IPC) | Forks a worker, loads + calls the library there, returns data (Marshal) over a pipe. Reuses Rigor's fork model (ADR-15). |

The key contrast: `ruby_box` isolates *correctness* contamination but a
native crash in the boxed work still takes the whole process down (as
observed — see below); `process` gives **true crash containment** because
the work runs in a child whose `SIGSEGV` the parent survives and turns
into a decline. So `process` is the most robust (and the natural answer
to the segfault that blocks the box path), at the cost of fork + IPC per
invocation (mitigable with a persistent worker). `none` stays the default
because the invoked libraries are trusted + pure and the contamination
risk is low for the common case.

The first-priority *in-process* option remains `ruby_box` (namespace
isolation, enabled by `RUBY_BOX=1`): target-library invocation runs
inside a `Ruby::Box`, whose boundary isolates class/method/constant
definitions and core-class monkey-patches per box, and lets multiple
versions of the same gem coexist.

Validated in the Flake Ruby (4.0.5): `Ruby::Box.new` + `box.require` +
`box.eval` load and call into a gem, returned data crosses the boundary,
and a monkey-patch defined inside a box does **not** leak to the main
space. So a box is a sufficient **contamination boundary** to keep a
target library from destructively polluting Rigor. (Reference:
[`Ruby::Box`](https://docs.ruby-lang.org/en/4.0/Ruby/Box.html), the link
the interpreter's own experimental warning points to.)

**What the box does and does not buy** (its scope is deliberately
limited, matching this ADR's trust model):

- **Does:** prevents core-class monkey-patch leakage into Rigor, allows
  the target's version to coexist with Rigor's own (so the
  maximal-fidelity "use the project's exact version" path becomes
  feasible without a process-wide version clash), and contains
  constant/name collisions. This is the destructive-contamination
  boundary the rule needs.
- **Does NOT:** `Ruby::Box` is **explicitly not a security sandbox** —
  the gem's code still executes in the same OS process with full
  privileges (it cannot make running *untrusted* code safe), it does not
  cross the same-Ruby-version / native-extension (ABI) boundary, and a C
  extension crash still takes the process down. These are acceptable
  here precisely because the rule only ever invokes a **declared,
  trusted, pure** target library (no untrusted-code or native-load
  requirement); for stronger isolation a **separate OS process** is the
  documented secondary option.

**Status / plan.** `Ruby::Box` is experimental (the interpreter prints a
"behavior may change" warning) and is a process-start flag (`RUBY_BOX=1`,
not toggleable at runtime). Because the flag is process-wide, isolating
just the target library means **the whole Rigor process runs in box
mode** — there is no "box only the inflector" without enabling boxes
process-wide. Adopting it therefore touches the launcher.

The **scaffolding is landed as an opt-in, off by default**:
`Rigor::Plugin::Box` (the wrapper), the `Plugin::Inflector` box-routing,
and an `exe/rigor` opt-in that re-execs under `RUBY_BOX=1` only when the
`RIGOR_BOX` env is set. With the opt-in off, every target-library
invocation keeps its main-space path and behaviour is unchanged
(`make verify` green).

**Empirical status of the box path (Ruby 4.0.5):** mixed.
- The isolation mechanism is validated — a target library loads + answers
  inside a box and does not leak into the main space; `Plugin::Inflector`
  routes through the box under `RUBY_BOX=1` (unit-tested).
- A trivial `rigor check` runs fine under `RUBY_BOX=1`.
- BUT a **full real-world analysis can segfault**: `rigor check` over
  Redmine `app` under `RUBY_BOX=1` crashed (`SIGSEGV`), apparently on the
  error path for that project's own malformed `sig/`
  (`RBS::DuplicatedDeclarationError`) which the non-box run handles
  gracefully. The crash is a NULL deref in the VM method-lookup path
  (`prepare_callable_method_entry`), reproducible with no user sub-boxes
  (only the process-wide `RUBY_BOX=1`) — it is **not** triggered by
  Rigor's `Plugin::Box`. A Ruby bug-report draft is in
  [`docs/notes/20260602-ruby-box-segfault-bug-report.md`](../notes/20260602-ruby-box-segfault-bug-report.md).

So the box path is **landed but gated as experimental and not yet
production-usable**: the chosen first-priority direction, blocked on
upstream `Ruby::Box` stabilisation. The current consumers
(`Plugin::Inflector`, the Rack catalogue) keep using Rigor's own pinned
dependency by default; the box + exact-version loading become the
recommended path once `Ruby::Box` is stable for Rigor's full pipeline.

### Engine support

The pattern is small enough that no new engine surface is strictly
required — a plugin can hold its allow-list, `require` its target, and
`rescue`. If the pattern recurs, the engine MAY offer a thin
`Plugin::Base` helper (a `safe_invoke(receiver, method, *args)` that
enforces an allow-list + rescue, mirroring the folding harness) and the
capability catalogue (ADR-37 § "capabilities") MAY surface a plugin's
declared target-library + allow-list so `rigor plugins --capabilities`
shows exactly which real methods a plugin will call. Both are additive
and deferred until the second consumer.

## Slices

1. **This ADR** — establish the rule + harness + the application-code
   line. (Revises ADR-2's blanket "no library calls" reading; ADR-2's
   *application-code* prohibition is unchanged.)
2. **`Plugin::Inflector` over the real `ActiveSupport::Inflector`** — the
   first consumer. A bundled helper that calls the real inflector through
   the harness and carries **no approximation**: when the gem is absent it
   raises `Inflector::Unavailable` (caught by the caller's isolation
   boundary → silence), never a guessed inflection. This is the
   FP-reducing replacement for boilerplate plan § 0e.
3. **Static ingestion of `config/initializers/inflections.rb`** — parse
   the custom-inflection DSL with Prism and feed it into the inflector,
   so project-specific irregulars are authoritative. Published as a
   cross-plugin fact (`produces: :inflections`) so routes / activerecord
   / actionpack consume one shared, correct inflector.
4. **Migrate the consumers** — `rigor-activerecord` / `rigor-rails-routes`
   / `rigor-actionpack` drop their hand-rolled `singularize` /
   `pluralize` / `underscore` copies onto the shared inflector. Each is
   verified behaviour-preserving-or-better against its golden-master
   integration spec **and** the OSS survey (rails-routes' Mastodon /
   Redmine run), since inflection feeds name-resolution diagnostics.

Slices 2–4 are the concrete landing of boilerplate plan § 0e, now
reframed from "unify the approximations" to "use the real library."

5. **Selectable isolation strategy** (see § "Isolation of target-library
   invocation"). A `plugins_isolation:` config (`none` / `ruby_box` /
   `process`; `RIGOR_PLUGIN_ISOLATION` env) selecting one of three
   backends behind a common interface, with `none` (direct, main-space)
   the default. **Landed:** `none` + `ruby_box` (the `Plugin::Box`
   wrapper + `exe/rigor` `RUBY_BOX=1` re-exec; `Plugin::Inflector` routes
   through it). **Planned:** `process` (fork) — forks a worker that loads
   + calls the library and returns data over a pipe, giving **crash
   containment** (a child `SIGSEGV` is contained, the parent declines) —
   the robust answer to the box path's segfault, reusing Rigor's fork
   model (ADR-15). `ruby_box` also unlocks the maximal-fidelity "load the
   project's exact gem version" path (a box per resolved version, no
   process-wide clash). The default (`none`) keeps the current
   pinned-dependency path, so behaviour is unchanged unless a project
   opts into a stronger strategy.

## Relationship to other ADRs

- **ADR-2** — clarifies its "Plugins must not execute application code"
  rule by distinguishing the analyzed *application's* code (still never
  executed) from a *trusted target library's* pure methods (now
  invocable through the harness). The Scope / Type / FactStore / IoBoundary
  contracts are unchanged; this adds a permitted computation source, it
  does not widen what plugins may *read* from the project.
- **ADR-31** — supply-chain policy. A plugin declaring a dependency on a
  well-known target gem and calling its pure methods is within the trust
  envelope a user already accepts by installing the plugin; the allow-list
  + rescue discipline bounds it. ADR-31's third-party-author routing is
  unaffected.
- **Constant folding** (ADR-1 value lattice / dispatcher) — this is the
  same `public_send` + allow-list + rescue model the engine uses for
  core/stdlib, generalised to plugin target libraries. No change to the
  folding tier itself.
- **ADR-37** — the capability catalogue can enumerate a plugin's declared
  target-library invocations, keeping the AI-legibility property: an
  agent sees exactly which real methods each plugin calls.
- **ADR-15** — the target library is loaded once per process; per-worker
  (fork / future Ractor) loading is the same consideration as any
  Rigor dependency and carries no per-run mutable dispatch state.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| Keep hand-rolling inflection (boilerplate § 0e as a dedup only) | Rejected | Picks one approximation; the FP-divergence from Rails' real rules — the actual problem — remains. |
| Keep a built-in approximation as a fallback when the target library is absent | Rejected | An approximation that diverges from the library's real rules emits a wrong fact (a wrong inflected name → a bogus `unknown-helper`), the exact false positive this ADR removes. Absence must degrade to **silence** (raise → isolation boundary), never a guess. The library is a declared dependency, so absence is a misconfiguration, not a routine path. |
| Execute the project's `inflections.rb` to learn custom rules | Rejected | That is application code; ADR-2 forbids running it. Static Prism parse of its DSL gets the same rules without executing project code. |
| Provision the project's exact target version per run (isolated install) | Deferred | Maximal fidelity, but brings install/cache/offline-CI/hermetic-Flake cost; default range-dependency + static custom-rule ingestion covers the real fidelity need. The chosen vehicle when pursued is the `Ruby::Box` isolation layer (slice 5), which lets the exact version coexist with Rigor's own without a process-wide clash. |
| Run target-library invocation with no isolation (current pinned-dependency path) | Accepted (interim) | Works and needs no box for correctness (the invoked libraries are trusted + pure; inflection rules are version-stable). Superseded by the `Ruby::Box` layer (slice 5) once that lands, which adds the contamination boundary + exact-version coexistence. |
| Isolate via `Ruby::Box` (namespace isolation) | **Chosen (slice 5)** | Contains core-class monkey-patch leakage + lets the target's version coexist with Rigor's own — the destructive-contamination boundary the rule needs. Not a security sandbox and does not cross the Ruby-version / native-extension boundary, but the rule only invokes declared, trusted, pure libraries, so that is acceptable; a separate OS process is the secondary option for stronger isolation. Experimental (`RUBY_BOX=1`). |
| Add `activesupport` to Rigor core's own dependencies | Rejected | Couples the whole toolchain to a heavy gem for one plugin's need; the dependency belongs on the plugin's gemspec so non-users pay nothing. |
| A general "call any target method" escape (no allow-list) | Rejected | Reintroduces the un-auditable, possibly-impure surface the harness exists to prevent; dynamic `public_send(arbitrary)` is never permitted. |

## Consequences

Positive:

- Plugins compute with their target library's **real** behaviour instead
  of an approximation, removing a class of false positives (inflection-
  driven name-resolution) rather than relocating it.
- The plugin model matches PHPStan's (extensions call into the real
  framework), which authors coming from PHPStan expect.
- The rule is bounded by an explicit, greppable allow-list + rescue, the
  same model the engine already trusts for constant folding.
- The analyzed application's code is still never executed — the
  static-analysis identity is preserved, and the boundary is now written
  down rather than implied.

Negative:

- A plugin that uses the rule grows a real runtime dependency on its
  target gem (load cost, version-range maintenance).
- A new trust consideration to document per plugin: which target library
  it loads and which methods it calls (mitigated by the allow-list and
  the optional capability-catalogue surface).
- The exact-version-fidelity path, if ever needed, carries provisioning
  machinery that is in tension with hermetic / offline runs.
