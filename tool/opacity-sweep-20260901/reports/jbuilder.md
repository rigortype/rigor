# jbuilder — opacity attribution (2026-09-01)

## Numbers

| metric | value |
| --- | --- |
| files | 12 processed, 2 parse errors (lib/generators/rails/templates/{controller,api_controller}.rb — ERB inside .rb, expected; `coverage --protection` exits 1 because of them while still writing full JSON) |
| expressions | 1481 |
| precision | 47.06% (constant 408, nominal 240, shaped 37, bot 12) |
| protection | 33.62% (78 / 154) |
| cause_site_counts | inferred_return_untyped 82, none 51, unsupported_syntax 20, external_gem_without_rbs 1 |
| tractability | engine_gap 102, add_rbs 1 |

Opaque split (784): local reads 273 (def_param 205, block_param 31, assigned_local 37), calls 252 (implicit-self 100, dynamic-receiver 131, precise-receiver 21), ivars 39, joins/mirrors (If 43, Write 26, Yield 12, Or 9, And 8) = G.

## Cases

1. **Param-sourced — A (~30% of opaque).** 236 param reads; plus the same-file `_`-helper family (`_format_keys` 8, `_array` 7, `_blank?` 6, `_scope` 4, `_set_value` 4, `_extract` 4 implicit-self sites) whose returns are param-derived — dispatch is same-file and fine, the value is A-rooted (lib/jbuilder.rb:277-366).
2. **Rails surface — E (~35 sites), owner: the rails plugin / ADR-72 overlay.** `Rails.cache` (jbuilder_template.rb:190), `Rails::Generators.configure!/hidden_namespaces` (railtie.rb:29-30), and the generator DSL inherited from `Rails::Generators::NamedBase` (`controller_file_path` 4, `singular_table_name`, `template`, `source`, `attributes`, `helper_method` — lib/generators/rails/jbuilder_generator.rb), plus `CollectionRenderer#render_collection_with_partial` (ActionView lane, jbuilder_template.rb:169). These want the Rails plugin's RBS/overlay, not core mechanisms.
3. **Coverage-lens artifact — cross-file user-method summaries (G-metric, ~10 pair sites).** `Jbuilder::NullError/MergeError/ArrayError.build` (errors.rb:7 defs; called from jbuilder.rb:309 etc.), `Jbuilder#attributes!/target!`, `JbuilderTemplate.template_lookup_options`. The check engine resolves these (scratch matrix: `CrossPlain.new.imeth(1)` and cross-file `def self.build` both produce `undefined method ... for 42/CrossPlain` diagnostics under `rigor check`), but the coverage/protection lens types cross-file user-method calls Dynamic. Metric infrastructure, not an engine dispatch gap.
4. **Splat DSL — D (engine-wide, small here).** `def set!(key, value = BLANK, *args, &block)` (jbuilder.rb:40) and friends fall under the rest-param summary drop verified in the check matrix (`SpCheck.spl(1).nosuch` silent while `pln` control fires).
5. **Proc#call — D (2 sites).** key_formatter.rb:20 — the format Proc's call answers Dynamic (same lane as net-ssh's Proc#[]).
6. **G joins/mirrors:** ~100 sites. Only CallOrWriteNode-class nodes lack handlers repo-wide; unsupported_syntax 20 is negligible here.
