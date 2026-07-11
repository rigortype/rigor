# L1 fidelity review — area C (plugins), 2026-07-11

Reviewer: L1 fidelity lens (plugins). Scope: `docs/manual/07-plugins.md`,
`docs/manual/plugins/*.md`, `docs/handbook/09-plugins.md`. Method: verify each
user-facing plugin claim against the plugin **source** (not just CHANGELOG).
Focus on the four capabilities that changed in `[Unreleased]`
(rigor-activerecord `structure.sql`, rigor-actionpack `require`/`permit`
typing + permit-key typo-gate, rigor-rails-routes Grape namespace, AS core-ext
additions), plus a config-key/default sweep.

## Findings

| Location (file:line + quote) | Problem | Severity | Proposed fix |
| --- | --- | --- | --- |
| `docs/manual/plugins/rigor-activerecord.md:81-82` — "**`db/schema.rb` only.** `db/structure.sql` (raw SQL dumps) is not supported in this iteration." | **FALSE.** PR #60 added `db/structure.sql` support: when `db/schema.rb` is absent the producer falls back to `StructureSqlParser.parse(io_boundary.read_file(@structure_sql_file))` (`activerecord.rb:88-90`). This Limitation now contradicts the shipped plugin. | High | Delete the limitation, or replace with the real residual limit: structure.sql is parsed line-by-line as **PostgreSQL** DDL (no SQL-parser dep); unmappable column types (custom enum, `tsvector`) degrade to `Object`, and non-`public`-schema partition tables are skipped. |
| `docs/manual/plugins/rigor-activerecord.md:40-47` (Configuration block) — lists `schema_file`, `model_search_paths`, `model_base_classes` only. | **Missing config key.** The plugin's `config_schema` (`activerecord.rb:60-66`) now declares `structure_sql_file` (default `"db/structure.sql"`), the fallback schema source. Undocumented. | Medium | Add `structure_sql_file: "db/structure.sql"  # default; PG DDL fallback when schema_file is absent` to the config block and the "Tweak them when" list. |
| `docs/manual/plugins/rigor-activerecord.md:33` — table row "\`db/schema.rb\` not readable → :warning `load-error`". | **Drifted.** The `load-error` now fires only when **neither** `schema_file` **nor** `structure_sql_file` is readable — the `Errno::ENOENT` message reads `schema file \`...\` (or \`...\`) not found` (`activerecord.rb:534-535`). The row overstates when the warning fires. | Low | Reword to "no schema source (`db/schema.rb` or `db/structure.sql`) readable". |
| `docs/manual/plugins/rigor-actionpack.md:42` — `unknown-permit-key` "Fires when: a literal `permit(:key)` isn't a column on the model (with a did-you-mean)". | **Drifted (behaviour narrowed).** PR #60 turned this into a **typo-gate**: it now fires only when the key is within edit distance ≤ 2 of a real column (`PERMIT_KEY_TYPO_MAX_DISTANCE = 2`, `analyzer.rb:64`), so a legitimate virtual attribute (`password`, `remember_me`, an `attr_accessor`) that is nothing like any column no longer fires. The doc still implies it fires on *any* non-column. | Medium | Reword "Fires when" to "a literal `permit(:key)` is a near-miss (edit distance ≤ 2) of a real column but not one — a likely typo; virtual attributes unlike any column are not flagged". |
| `docs/manual/07-plugins.md:30` — activerecord config example `schema: db/schema.rb`. | **Wrong config key.** The real key is `schema_file` (`activerecord.rb:61`); `schema` is not a recognised key. Pre-existing, but this is the overview chapter's one concrete plugin-config example. | Medium | Change to `schema_file: db/schema.rb`. |
| `docs/manual/plugins/rigor-activerecord.md:35-36` — "Did-you-mean suggestions use Levenshtein distance ≤ 3 against the resolved table's column names." | **Inaccurate mechanism (pre-existing).** `Plugin::Base.suggest` (`base.rb:657-661`) delegates to `DidYouMean::SpellChecker`, whose acceptance is a Jaro-Winkler ≥ 0.77 / scaled-Levenshtein blend, not a fixed Levenshtein ≤ 3. Out of this session's change set but surfaced during verification. | Low | Reword to "Did-you-mean suggestions use `DidYouMean` fuzzy matching against the resolved table's column names" (drop the exact `≤ 3`). |

## Intentional simplifications (verified NOT defects)

- **rigor-activesupport-core-ext.md:36-52** — the "What it covers" list does not
  enumerate the PR #61 additions (`String#upcase_first`/`#remove`/`#titlecase`/
  `#dasherize`, `Object#in?`, `Date`/`Time#advance`/`#all_day`, `Date#to_time(form)`,
  `ERB::Util.html_escape_once`). The doc explicitly frames the list as "Roughly the
  top ~40 selectors plus their close neighbours" and "Top ~40 selectors, not
  exhaustive" (line 77-78), so it makes no false completeness claim. No change needed.
- **rigor-actionpack.md** — the new `require`/`permit`/`permit!` → `ActionController::Parameters`
  return typing (`actionpack.rb:198-200`) is coverage-additive inference, not a
  diagnostic. The doc's "What it checks" section is a diagnostics table; omitting an
  inference detail is not a fidelity gap and prose depth is not a virtue here.
- **rigor-rails-routes.md:53-78** — the Grape section is **accurate and current**:
  `grape_api_paths` default `["lib/api", "app/api"]` matches `rails_routes.rb:79`; the
  claim that only `_path` helpers are covered (`_url` still fires) matches the plugin's
  contract. No change needed.
- **rigor-rails-routes.md:34-51** ("Recognised routing DSL") already covers
  `member`/`collection`/`scope` generically, so the PR #60 name-composition fixes
  (multi-segment string actions, bare-symbol actions in a named scope) introduce no
  false claim to correct.

## Verdict

The changed plugin capabilities are largely undocumented-but-not-misdescribed, with
one hard contradiction: **rigor-activerecord's Limitations still declares
`db/structure.sql` unsupported (High)** — the exact opposite of what shipped in PR #60,
and the most user-visible falsehood in area C. Two medium items follow from the same PR
(the missing `structure_sql_file` config key, and the `unknown-permit-key` table cell
that no longer matches the typo-gate behaviour), plus a wrong config key
(`schema` vs `schema_file`) in the overview chapter's one activerecord example. The
Grape and AS core-ext docs are clean. Two pre-existing low-severity mechanism
inaccuracies (the `load-error` firing condition and the "Levenshtein ≤ 3" phrasing) round
out the list. No fabricated capabilities and no stale plugin names were found.
