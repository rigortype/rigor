# ADR-39 — Plugins may invoke their target library's safe methods directly

Status: **Accepted, 2026-06-02.** The rule + harness are implemented and
validated: `Rigor::Plugin::Inflector` (slice 2) invokes the real
`ActiveSupport::Inflector` through the allow-list + rescue harness with a
built-in fallback, and the three consumers — `rigor-actionpack`,
`rigor-activerecord`, `rigor-rails-routes` (slice 4) — are migrated onto
it, deleting their hand-rolled inflection. Validated behaviour-preserving
against every plugin's golden-master integration spec **and** both
headline OSS corpora (Redmine and Mastodon `app + lib` rails-routes
diagnostics byte-identical before/after). **Deferred (follow-on):** slice
3 (static ingestion of `config/initializers/inflections.rb` for
project-custom inflections — the default ActiveSupport ruleset already
covers the common cases; custom-rule isolation across projects in a
long-lived LSP process is the open design point), and the exact-version
provisioning fallback (only if a cross-version behavioural difference is
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
4. **Total recovery.** The whole invocation is wrapped so any
   failure (load error, unexpected version, raised exception) degrades to
   "no contribution" (`nil` / `[]`), never a crash. Same `rescue
   StandardError` discipline as folding, under the existing per-plugin
   isolation boundary.

A method that fails any clause stays reimplemented or unsupported.

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
   the harness, with the hand-rolled regular-form algorithm kept only as
   the rescue-path fallback when the gem is absent. This is the
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
| Execute the project's `inflections.rb` to learn custom rules | Rejected | That is application code; ADR-2 forbids running it. Static Prism parse of its DSL gets the same rules without executing project code. |
| Provision the project's exact target version per run (isolated install) | Deferred | Maximal fidelity, but brings install/cache/offline-CI/hermetic-Flake cost; default range-dependency + static custom-rule ingestion covers the real fidelity need. Revisit only if a cross-version behavioural difference is observed. |
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
