# tdiary-core — opacity attribution (2026-09-01)

## Numbers

| metric | value |
| --- | --- |
| files | 69 (0 parse errors) |
| expressions | 19942 |
| precision | 54.75% official (constant 6471, nominal 3680, shaped 536, refined 38, bot 193). Caveat: the probe read 55.17% on identical expression totals — an 85-expression drift vs the official lens (worker/order effects); all counts below are probe-side. |
| protection | 34.73% (1437 / 2701) |
| cause_site_counts | inferred_return_untyped 1874, none 616, unsupported_syntax 165, external_gem_without_rbs 23, explicit_untyped 23 |
| tractability | engine_gap 2039, add_rbs 46 |

Opaque split (9024): calls 3741 (precise-receiver 295, implicit-self 758, dynamic-receiver 2688), local reads 1654 (def_param 732, block_param 391, assigned_local 531), **ivars 1302 — the highest ivar share of the five targets (14.4% of opaque)**, joins/mirrors (EmbeddedStatements 530, If 265, Write 225, And 106, Or 92) = G, ForwardingSuperNode 68.

## Cases

1. **Plugin-architecture DSL — E, the headline (~350+ implicit-self sites), owner: a rigor-tdiary plugin.** tdiary evaluates plugin files (lib/tdiary/plugin/00default.rb etc.) inside a `TDiary::Plugin` instance (instance_eval); as standalone files their top-level calls have no binding: `h` 182 (ERB::Util#h — plugin.rb:9 `include ERB::Util`), `add_conf_proc` 25, `conf` 25, `cgi` 21, `navi_item` 20, `use` 13, `tdiary` 12, `date` 11, `bot?` 9. Fix owner: a tdiary plugin that binds plugin-file scope to `TDiary::Plugin` (same shape as Rails view binding).
2. **Ivar-rooted — A/ADR-58 lane (1302 reads).** @conf/@cgi/@date/@diaries assigned from params, IO and plugin loading; classic app-gem state. Count, do not design (ADR-58 WD2/WD3 pending).
3. **Struct factory — D engine-wide (18 sites, third target showing it).** `Market = Struct.new(:host, :region)` (lib/aws/pa_api.rb:7); `Market.new(...)` × 14 and `#host` × 4 answer Dynamic in the SAME file, matching the check-matrix silence for `MyS = Struct.new(:a); MyS.new(1).nosuch`.
4. **Optional-receiver dispatch — D engine-wide with a policy caveat (~30+ pair sites).** `String?#empty?` 6 (comment.rb:17), `String?#split` 5, `Hash[Dynamic,Dynamic]?#[]` 7 (configuration.rb:27), `?#[]=` 5, `Array[Dynamic]?#each` 5. Check matrix: `s = flag ? "x" : nil; s.length` answers Dynamic in BOTH the lens and `rigor check` (nosuch probe silent; non-nil control fires "for 1"). The diagnostic quietness on the nil arm is ADR-5-consistent, but the RESULT could still be the non-nil arm's type instead of Dynamic — a precision lever that needs an explicit policy call.
5. **Cross-file lens artifact — G-metric (~25 pair sites).** `TDiary.root` 10 / `logger` 5 / `server_root` 5 (defined in a `class << self` block, tdiary.rb:110-131): the check matrix proved `class << self` defs resolve under check both same- and cross-file ("for \"s\""), so these are the coverage lens's cross-file-summary blindness. After a lens fix, `root`/`server_root` surface precise Strings; `logger` stays Dynamic via `@@logger` (classvar lane).
6. **Stdlib/gem RBS holes — B (~40 sites).** `WEBrick::HTTPServer#mount` 5 (server.rb:41), `PStore#transaction/#[]` 6 (cache/file.rb:40-42), `Bundler.with_clean_env` 3 (cli.rb:23), `FileUtils.mkdir_p` 3; external_gem_without_rbs 23, add_rbs 46.
7. **Container/propagation — C.** Hash[Dynamic,Dynamic] and `{}` shape reads (~50 pair sites: io/default.rb:39, base.rb:46,106); `File.open` block-generic 6; 2688 dynamic-receiver calls (`[]` 614, `params` 146 — CGI params, `strftime` 63) rooted in ivars/CGI/A.
8. **F unsupported_syntax 165 (6.1%).** No node-handler gaps (repo-wide only CallOrWriteNode is unhandled); the label covers unresolved constants (ConstantPath 74 — vendored aws/rack trees and plugin-file constants) plus reflection in the plugin loader (`eval` 11 implicit-self sites — genuine dynamic).
9. **ForwardingSuperNode 68** — super into cross-file parents; expected to collapse mostly into the case-5 lens artifact.
10. **G joins/mirrors:** ~1220 sites.
