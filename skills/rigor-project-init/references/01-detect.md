# 01 — Detect the project shape & select plugins

Covers **Phase 1** (detect) and **Phase 3** (plugin selection). Run
Phase 2 — the mode choice — from `SKILL.md` between them.

## Phase 1 — Detect

Read two files at the project root. Do not run code; just parse them.

### `Gemfile` — framework family

Scan the `gem "…"` lines for the markers below. A project can match
more than one row (a Rails app with RSpec and Sidekiq matches three).

| Marker gems | Family |
| --- | --- |
| `rails`, `railties`, `actionpack`, `activerecord` | Rails |
| `sinatra` | Sinatra |
| `dry-types`, `dry-struct`, `dry-schema`, `dry-validation` | dry-rb |
| `rspec`, `rspec-core` | RSpec test suite |
| `sorbet`, `sorbet-runtime` | Sorbet-typed |
| none of the above | plain Ruby |

Also note per-gem markers that have their own plugin: `devise`,
`pundit`, `sidekiq`.

### `Gemfile.lock` — versions & RBS state

- Read the **locked versions** of the framework gems — a plugin
  recommendation can depend on a major version.
- Check for `rbs_collection.lock.yaml` at the project root AND whether
  `.gem_rbs_collection/` exists alongside it.
  - **Lockfile present, `.gem_rbs_collection/` present** → the collection
    is installed; Rigor will auto-detect and consume it via
    `rbs_collection.auto_detect: true` (the default).
  - **Lockfile present, `.gem_rbs_collection/` absent** → the lockfile
    was generated but the gems were never downloaded. Rigor loads the
    lockfile but finds no RBS files. **Act now — see below.**
  - **Both absent** → note it; Phase 6's triage may recommend
    `rbs collection install` if `gem-without-rbs` hints appear.

### RBS collection — install if absent

When `rbs_collection.lock.yaml` is present **and** `.gem_rbs_collection/`
is absent, the collection was configured (e.g. by Steep or `rbs_rails`)
but never installed. Installing it now — before writing the config or
running triage — gives Rigor community RBS for dozens of gems and avoids
a triage → config-fix → re-triage cycle.

Offer to run:

```sh
bundle exec rbs collection install
```

Use `bundle exec` when `rbs` appears in `Gemfile` or `Gemfile.lock`
(the common case — Steep / rbs_rails workflows put it there). If `rbs`
is not in the Gemfile, use the bare `rbs collection install` instead.

Ask the user for permission before running, since this installs files
into `.gem_rbs_collection/` (a generated directory that belongs in
`.gitignore`). Only proceed with their confirmation.

After installation, verify with:

```sh
ls .gem_rbs_collection/
```

The directory should contain RBS gem subdirectories. Continue to
Phase 2 — the collection will be auto-detected by Rigor at analysis
time.

**Note: RBS collision after install.** Some gems (e.g. `cgi`, `logger`,
`base64`) were extracted from Ruby's stdlib into standalone gems from
Ruby 3.3 onwards. When these appear in both `.gem_rbs_collection/` and
Rigor's bundled stdlib, `rigor triage` may print a
`RBS::DuplicatedDeclarationError`. If this happens, note the error and
continue — plugin-based diagnostics are unaffected. File a Rigor issue
at <https://github.com/rigortype/rigor/issues> so the engine can
deduplicate stdlib gems from the collection automatically.

### Path scope

Note the conventional source roots so Phase 4 can set `paths:`:

- Rails → `app`, `lib`.
- gem / library → `lib`.
- plain app → `lib`, or the directory holding the code.

`spec/` and `test/` are normally **excluded** from `paths:` — they
are checked differently and inflate the diagnostic count. `vendor/`
and `tmp/` are always excluded.

## Phase 3 — Plugin selection

Propose a plugin set from the detected families. Present it to the
user as a list they can trim — do not silently enable everything.

| Family | Recommended plugins |
| --- | --- |
| Rails | `rigor-actionpack`, `rigor-activerecord`, `rigor-actionmailer`, `rigor-rails-routes`, `rigor-rails-i18n`, plus `rigor-activesupport-core-ext` (almost always needed — see below) |
| dry-rb | `rigor-dry-types`, `rigor-dry-struct`, and `rigor-dry-schema` / `rigor-dry-validation` when those gems are present |
| Sinatra | `rigor-sinatra` |
| RSpec | `rigor-rspec` |
| Devise / Pundit / Sidekiq present | `rigor-devise` / `rigor-pundit` / `rigor-sidekiq` |
| Sorbet present | `rigor-sorbet` (ingests existing `sig` blocks / RBI as type sources) |
| plain Ruby | none required — the core analyzer covers it |

The current production-plugin catalogue is the authority for which
plugins exist and how each is named / installed:
<https://github.com/rigortype/rigor/blob/master/plugins/README.md>.
The set drifts as new plugins land — consult that page rather than
treating the table above as exhaustive.

### `rigor-activesupport-core-ext` — the common Rails gap

ActiveSupport monkey-patches the core classes (`3.days`,
`5.minutes`, `"x".squish`, `Time.current`, …). Without the
`rigor-activesupport-core-ext` bundle, every such call reports
`call.undefined-method` — on a real Rails app this is the single
largest diagnostic cluster (a measured Mastodon run: ~365 of 489
diagnostics were exactly this). Phase 5's `rigor triage` flags it as
hint `activesupport-core-ext`.

`rigor-activesupport-core-ext` is a **plugin** (an RBS-bundle plugin
— it contributes signatures, not diagnostics). Activate it like any
other: list it under `plugins:`. No `signature_paths:` wiring is
needed — the plugin ships its own `sig/`. Include it for any
Rails-family project.

## Output of this module

- A framework-family list.
- A proposed, user-trimmed plugin set.
- The `paths:` / `exclude:` scope for Phase 4.
- Whether an RBS collection already exists.

Carry these into Phase 4 ([`02-configure.md`](02-configure.md)).
