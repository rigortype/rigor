# faraday — opacity attribution (2026-09-01)

## Numbers

| metric | value |
| --- | --- |
| files | 33 (0 parse errors) |
| expressions | 5819 |
| precision | 49.53% (constant 1643, nominal 1003, shaped 157, refined 4, bot 75) |
| protection | 29.69% (318 protected / 753 unprotected) |
| cause_site_counts | inferred_return_untyped 301, none 310, unsupported_syntax 129, explicit_untyped 12, external_gem_without_rbs 1 |
| tractability | engine_gap 430, add_rbs 13 |

Opaque split (2937 opaque exprs): calls 1098 (precise-receiver 116, implicit-self 315, dynamic-receiver 667), local reads 991 (def_param 650, block_param 152, assigned_local 189), ivar reads 102, joins/mirrors (IfNode 132, LocalVariableWriteNode 114, EmbeddedStatementsNode 76, AndNode 42, OrNode 28) — the last group is metric artifact (G).

## Attribution split

- A param-sourced: 802 local reads (27.3% of opaque) + the dominant root of the `inferred_return_untyped` cause (module_function helpers returning params).
- C propagation: 667 dynamic-receiver call sites (`[]` 103, `each` 23, `[]=` 23, `to_s` 22 ...), rooted in A/B upstream.
- D engine gap: the Struct-factory class-body block (below) — accounts for the bulk of the 315 opaque implicit-self sends and several precise-receiver pairs.
- B missing RBS: near zero. `::JSON` verified resolving to `singleton(JSON)` (request/json.rb:32); external_gem_without_rbs = 1 site. Stdlib shims load (PR #300 behaviour holds).
- F unsupported_syntax (129, 17% of causes): NOT missing node handlers — of all opaque node classes only CallOrWriteNode (2 sites) lacks a PRISM_DISPATCH entry. The label is carried by closed-world-miss implicit-self calls (the Struct DSL members, `send`/`public_send`, Forwardable `def_delegators`) — i.e. it mostly collapses into case D1.

## Cases

1. **Struct.new(...) do-block class bodies — D, the headline.** `Request = Struct.new(:http_method, :path, :params, ...) do ... end` (lib/faraday/request.rb:27) and the whole Options layer (`ConnectionOptions = Options.new(...) do`, options/connection_options.rb:8; Options < Struct so Options.new is a subclass factory). Rigor does not treat the factory block as a class body: inside `def url` the engine types `self` as the lexically enclosing module — the probe records the receiver of `self.params` at request.rb:86 as `singleton(Faraday)` — so every Struct member accessor (`params`, `path=`, `body=`, `headers`, `options`) and sibling method dispatches Dynamic. Same root: `self.class` types bare `Class`, so `Class#options_for` (options/connection_options.rb:13 vs def self.options_for at options.rb:161) misses. Implicit-self opaque top (options 18, headers 13, body 9, params 8, env 8, members 8) is this. Fix direction: discovery/ScopeIndexer should recognise `CONST = Struct.new(...) do ... end` (and subclasses-of-Struct `.new`) as a class-body scope for CONST — self = instance inside defs, singleton at block level — and synthesize member accessors from the symbol arguments. Engine-wide, not a lens artifact: under `rigor check`, `MyS = Struct.new(:a); MyS.new(1).nosuch` stays silent while sibling controls fire (jbuilder-phase matrix).
2. **Param-sourced locals — A (closed).** 802 sites counted, not designed against.
3. **Dynamic-receiver propagation — C.** 667 sites; roots are A params and case-1 members.
4. **module_function helper returns — A, layered under the lens artifact.** `singleton(Faraday::Utils)#URI` (6, utils.rb:70 — body returns the `url` param or `default_uri_parser.call(url)`), `#unescape` (4), `#default_params_encoder` (4), `#deep_merge` (2). All are cross-file calls, so the coverage lens's cross-file-summary blindness (established in the jbuilder-phase check matrix; see net-ssh case 9) hits first; once the lens consults summaries, these particular returns stay Dynamic anyway — param-sourced bodies and `Proc#call` on an untyped memoized ivar — hence A.
5. **register_middleware — D (re-classified after the mail sweep).** `singleton(Faraday::Request)#register_middleware` (4) + Response (3): reached via `extend MiddlewareRegistry` (request.rb:28). The mail target's scratch control proved `extend M` methods are invisible to singleton dispatch entirely (implicit-self AND explicit receiver), so the dispatch itself fails here — the **kwargs return (middleware_registry.rb:26-30) is moot until that resolves; splat/kwrest summary drop (net-ssh case 1) would then take over.
6. **Mutex/Monitor#synchronize — C.** Generic block-return `[T] { () -> T } -> T`; block bodies produce Dynamic (e.g. middleware.rb:31 `@default_options = default_options.merge(options)`), so the generic binds Dynamic. Not a dispatch failure.
7. **Hash#[] on Headers KeyMap — C.** utils/headers.rb:53 — container-of-Dynamic (`@names`, KeyMap values flow through untyped ivars).
8. **Ivar reads — 102 sites**, cross-file class_ivars (closed, ADR-58 lane).
