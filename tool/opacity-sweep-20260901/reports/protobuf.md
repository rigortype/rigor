# protobuf (ruby/lib, FFI runtime) — opacity attribution (2026-09-01)

Config note: this target's `.rigor.dist.yml` uses `paths: [ruby/lib]` (google/protobuf monorepo layout), unlike the other five (`lib`). 24 files — the FFI-based pure-Ruby runtime (`google/protobuf/ffi/*`), not the C-extension runtime.

## Numbers

| metric | value |
| --- | --- |
| files | 24 (0 parse errors) |
| exprs | 10071 — largest of the family |
| precision | 59.53% (opaque 4076) |
| protection | 49.74% |
| cause_site_counts | unsupported_syntax 388 (44.6%), inferred_return_untyped 272, none 209, explicit_untyped 2 |
| tractability | engine_gap 660, add_rbs 2 |

Tiers: constant 2708, nominal 2817, shaped 236, bot 234, dynamic_top 4076.

## Attribution split (opaque = 4076)

- Calls 1747 (dynamic_top 749, implicit_self 471, precise 527)
- Local reads 1193 (def_param 565, assigned_local 510, block_param 118)
- Ivars 98 reads (+37 `@x ||=` memoizations, +35 writes); Constants 181; If/Or/Embedded mirrors ~251.

## Classified cases

1. **Runtime message-class construction** — **F**, the signature protobuf construct and the bulk of unsupported_syntax 388. `build_message_class` wraps the ENTIRE message class in `Class.new(Google::Protobuf::const_get(:AbstractMessage)) do … end` (/Users/megurine/repo/ruby/rigor-survey/protobuf/ruby/lib/google/protobuf/ffi/message.rb:39) — with `class << self`, `alias original_method_missing method_missing`, and ~15 `define_method("#{field_name}…")` interpolated-name accessors (message.rb:452-503). Every def and implicit-self send inside (`descriptor` 30, `arena` 26, `allocate` 15, `name` 32 …) has no statically known class, and the receiver surfaces as `singleton(#<Class>)#descriptor` (13 sites). Companion construct: `Struct.class_eval do` / `ListValue.class_eval do` reopenings of these generated classes (well_known_types.rb:143/175), whose `self.fields`/`self.values` sends type against the enclosing module — the odd `Google::Protobuf#fields`/`#values` pairs (11 sites). Genuinely generated-at-runtime code; the static story would be an E-grade plugin consuming descriptors, not engine work.
2. **`attach_function` FFI DSL** — implicit-self `attach_function` 125 + `typedef` 15 declarations, and the ~120 call sites they generate: `singleton(Google::Protobuf::FFI)#create_arena` 22, `#get_field_by_number` 14, `#get_mini_table` 11, `#get_type` 9, `#get_message_value` 9, `#map_set` 5 … — **E** (ffi-gem plugin territory, per `rigor-ffi-plugin-author`); **B (own native)** beneath — the upb C library is the actual implementation. The `class FFI` is reopened in 7 files (ffi.rb:10 `extend ::FFI::Library`).
3. **FFI struct/union surface** — `FFI::MessageValue#[]` 38, `#[]=` 19, `by_value` 15, `MiniTable#by_ref` 7, `Status#by_ref` 5, plus `null?` 44, `read`/`read_string_length` 44, `::FFI::MemoryPointer.new`/`::FFI::Pointer::NULL` — **E** (same ffi plugin), ~180 sites.
4. **`send` with literal symbols** — 63 dynamic-receiver `send` + `Google::Protobuf::Map#send` 9 + `RepeatedField#send` 7 + `singleton(Map)#send` 5 — **D**. Mechanism: the codebase's idiom for crossing private-method boundaries is `receiver.send(:literal_name, args)` — e.g. `@descriptor_pool.send(:get_file_descriptor, …)` (ffi/descriptor.rb:63), `value.send(:key_type)` (ffi/field_descriptor.rb:277). The symbol is a literal at virtually every site, so dispatch is statically resolvable; the engine answers Dynamic for every `send`. Fix direction: fold `send`/`__send__`/`public_send` with a literal first argument into ordinary dispatch (visibility-ignoring), leaving non-literal sends Dynamic.
5. **`Method?#call`** — 6 sites (ffi/map.rb:170) — **D**-lite: `Method` objects fetched via `method(:name)` then `.call` through an optional; both `method` lookup with a literal name and `#call` through `T?` decline today.
6. **memoized ivar returns** — `@options ||= begin … end` pattern (37 `InstanceVariableOrWriteNode` + 98 ivar reads) — mixture: the ox-proven ivar-return **D** where the memoized value is well-typed, **A** where writes are param-sourced.
7. **def/block params** — 683 sites — **A** (CLOSED).
8. **cascade** — 749 dynamic-receiver calls + 510 assigned locals — **C**, seeded by cases 1-3; also carries the rbnacl-proven cross-file inferred-return boundary (e.g. `convert_upb_to_ruby`, 22 implicit-self sites, defined in `Internal::Convert` and included into classes in other files).

## Native-boundary note

protobuf's Ruby FFI runtime is the family's maximal case: THREE stacked dynamic layers — the ffi gem's DSL (E), the upb C library behind it (B), and runtime class generation on top (F). Receiver identity still mostly survives (nominal 2817), so the loss is concentrated in method returns, exactly like the rest of the family.
