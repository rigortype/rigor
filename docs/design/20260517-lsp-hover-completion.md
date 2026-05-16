# LSP v2 — type-aware hover + completion

**Status:** Draft. Follow-up to
[`20260517-language-server.md`](20260517-language-server.md)
(LSP v1, landed in v0.1.6) extending two surfaces with type-aware
behaviour: richer hover, and a first cut of `textDocument/completion`.

LSP v1's `textDocument/hover` ships a minimal markdown body
(`type:`, `erased:`, `node:`). It works, but it doesn't yet leverage
the analyzer's full type information — receiver type for method
calls, RBS comments, signatures, source-of-truth links to where a
constant was defined. Completion is entirely absent in v1 (queued
in the design doc § "Out of scope for v1"). Both gaps are the
natural next-step UX work an editor user feels.

This doc designs:

1. **Hover enhancement** — node-class-dispatched hover rendering
   that surfaces type-relevant info per shape.
2. **`textDocument/completion`** v1 — method completion after `.`
   and constant-path completion after `::`, both driven by
   inferred / declared types.

`textDocument/signatureHelp` is mentioned as a natural sibling but
queued for a separate slice (it's complementary to completion but
the surface is independent).

## Decisions

- **Hover stays an inline markdown body** (LSP `Hover.contents`
  with `kind: "markdown"`). No `range` field for v2 — the editor
  uses the cursor position as the anchor.
- **Per-node-class rendering** via a new `HoverRenderer` collaborator
  with dispatch on the Prism node class. Keeps the slice-5 default
  body for unknown shapes; specialises for `CallNode` /
  `ConstantReadNode` / `ConstantPathNode` /
  `LocalVariableReadNode` / `InstanceVariableReadNode` / literal
  carriers.
- **Completion scope v1**: method completion after `.` and
  constant-path completion after `::`. Bare-name completion (locals
  + methods on implicit self) and hash-key completion (HashShape
  carriers) are queued for v2 follow-ups.
- **Trigger characters**: `.` and `::` (LSP capability
  `completionProvider.triggerCharacters: [".", ":"]`; the second
  `:` of `::` is the trigger and we look one character back).
- **Method enumeration via `Reflection.instance_definition` /
  `singleton_definition`** — Rigor's existing RBS query surface.
  No new public API.
- **CompletionItem detail field is the RBS signature** rendered
  the same way `rigor sig-gen` does. One signature line, kebab-case
  refinements expanded.
- **No fuzzy matching server-side**. LSP clients (VSCode / Neovim /
  Emacs) filter `CompletionItem[]` against the user's typed prefix
  themselves. The server returns the full candidate set and lets
  the client filter; this is simpler, cheaper, and respects per-
  editor fuzzy-match preferences.

## Hover enhancement design

### Current shape (slice 5 floor)

```ruby
type:   <Type#describe>
erased: <Type#erase_to_rbs>
node:   Prism::IntegerNode
```

Useful as a debug surface, weak as a user-facing tooltip. The
information density is low and the cognitive map ("what does the
type *mean* for the thing under the cursor") is missing.

### Per-node rendering matrix

| Node class | Hover body shape |
|---|---|
| `Prism::CallNode` (`obj.foo(args)`) | Receiver type + method signature (params + return) + RBS comment (if present) + source-location link. |
| `Prism::ConstantReadNode` / `Prism::ConstantPathNode` | Resolved class/module FQN + singleton type + RBS comment on the class + source-location link. |
| `Prism::LocalVariableReadNode` / `LocalVariableWriteNode` | Variable name + inferred / narrowed type + line of the most recent binding. |
| `Prism::InstanceVariableReadNode` / `InstanceVariableWriteNode` (`@foo`) | Ivar type from scope's instance-context narrowing + enclosing class. |
| `Prism::SymbolNode` (`:foo`) | The literal value + carrier (`Constant<:foo>`). |
| `Prism::IntegerNode` / `FloatNode` / `StringNode` / `RegularExpressionNode` | Literal value + carrier + (for refined Strings) the refinement name. |
| `Prism::ArrayNode` / `HashNode` | Carrier shape (`Tuple<...>` / `HashShape<...>`) with element types laid out one per row. |
| _default_ | Slice-5 body (`type:` / `erased:` / `node:`). |

The renderer is a single class with case-on-node dispatch — each
branch is short (one to three lines of markdown construction).
Total new code: ~150 lines.

### Render details

**Method call (`obj.foo(args)`)**:

```ruby
# Receiver
String

# Method
def upcase: () -> String

# Defined in
core (ruby/rbs)
```

The first row is the **receiver type**'s describe form. The second
is the RBS signature, looked up via
`Reflection.instance_method_definition(class_name: receiver.describe,
method_name: node.name)` and rendered through the same erasure path
sig-gen uses (single-overload presentation for v1; multi-overload
support is a follow-up).

The third row attributes the source: when the RBS definition has a
`location.buffer.name`, show it; otherwise fall back to "core
(ruby/rbs)" / "bundled (gem-ships sig/)" / "project sig" based on
`Environment::Reflection`'s path classification.

**Constant**:

```ruby
# Constant
Foo::Bar

# Type
singleton(Foo::Bar)

# Defined in
lib/foo/bar.rb:3
```

The constant's FQN comes from `qualified_name_of(node)` (already in
`DocumentSymbolProvider`). The type is the `Type::Singleton` carrier
the type system attached. Source location via
`Reflection.instance_definition(class_name).declarations.first.location`.

**Local variable**:

```ruby
# Local
results

# Type
Array[Integer]

# Bound at
lib/example.rb:12
```

The narrowed type at the cursor is what `Scope#type_of` already
returns. Bound-at is the most recent assignment in scope; the scope
indexer already tracks this for `LocalVariableWriteNode`.

**Refinement narrowing**:

When a value's narrowed type is a refinement (`Refined[non-empty-string]`,
`Difference[Integer, -1..-1]`), the hover surfaces the canonical
refinement name plus the underlying type:

```ruby
# Type
String (non-empty-string)
```

This is high-value UX because the narrowing is the analyzer's
distinctive output — users want to know "why is this narrowed."

## Completion design

### LSP request shape

```
textDocument/completion request
params: {
  textDocument: { uri },
  position: { line, character },
  context: {
    triggerKind: 1 | 2 | 3,    # Invoked | TriggerCharacter | TriggerForIncompleteCompletions
    triggerCharacter?: "." | ":"
  }
}
returns: CompletionItem[] | CompletionList | null
```

The server returns either a flat array (no incomplete-list
behaviour) or null (no completions available — distinct from
empty-array, which means "we tried and got nothing").

### CompletionItem shape

```ruby
{
  label: "upcase",                    # what the user sees
  kind: 2,                            # CompletionItemKind::Method
  detail: "() -> String",             # signature on the right side
  documentation: { kind: "markdown",
                   value: "..." },    # popup body
  insertText: "upcase",               # what the editor inserts
  filterText: "upcase",               # what the client fuzzy-matches against
  sortText: "0_upcase"                # sort priority (server-side rank)
}
```

`sortText` gives the server a rank lever. v1 ranks by:

1. **Owning class proximity** — methods on the receiver's exact
   class rank higher than inherited ancestors.
2. **Visibility** — public > protected > private.
3. **Lexicographic** — for ties within rank groups.

Empirically this matches what editor users expect (`String#upcase`
beats `Object#hash` when typing on a String receiver).

### Method completion (`obj.|`)

Pipeline:

1. **Parse the buffer.** Prism with error recovery emits a partial
   AST. The cursor sits at or just after a `CallNode` whose
   `name` is empty or a partial identifier.
2. **Locate the receiver.** Walk the AST for the node at the
   cursor; the receiver is the call node's `receiver`.
3. **Infer the receiver's type.** Same `Scope#type_of` path the
   hover provider already uses.
4. **Enumerate methods** via `Reflection.instance_definition(class_name)`
   for nominal types or each member of a Union / Intersection
   (intersection: union of members' methods; union: intersection
   of members' methods, semantically — but for completion UX
   we want the union of "anything that *might* be valid").
5. **Filter by visibility.** Drop private methods when the
   receiver isn't `self`.
6. **Convert each method to a CompletionItem.**

Receiver-type → enumeration matrix:

| Receiver carrier | Enumeration source |
|---|---|
| `Nominal[C]` | `Reflection.instance_definition(C).methods` |
| `Singleton[C]` | `Reflection.singleton_definition(C).methods` |
| `Constant<v>` | enumerate as `Nominal[class_of(v)]` |
| `Tuple<...>` / `HashShape<...>` | their nominal ancestor (`Array` / `Hash`) |
| `Refined[...]` | enumerate the underlying nominal |
| `Union[A, B, ...]` | intersection of each member's methods (the only methods guaranteed to dispatch on every union case) |
| `Dynamic[T]` | enumerate `T`'s methods if non-Top; otherwise none (no useful completion for `Dynamic[Top]`). |

Union / Intersection enumeration is a design point worth recording.
The naive "union of methods" gives lots of false positives
(`Integer#upcase` shown when receiver is `Integer | String`).
The "intersection of methods" gives the safe set. v1 ships the
intersection; UX feedback will tell us whether to relax.

### Constant-path completion (`Foo::|`)

Pipeline:

1. Parse + locate the `ConstantPathNode` at the cursor.
2. Resolve the parent constant via the lexical-nesting chain
   (mirrors `Reflection.constant_type_for`).
3. Enumerate child constants:
   - Inner classes / modules from
     `Reflection.instance_definition(parent_fqn).declarations`.
   - Nested `Type::Singleton` registrations in
     `Environment::Reflection#known_classes`.
4. Convert each to a CompletionItem with `kind: 7` (Class) /
   `kind: 9` (Module) / `kind: 21` (Constant).

### Trigger characters

LSP capabilities:

```ruby
completionProvider: {
  triggerCharacters: [".", ":"],
  resolveProvider: false   # CompletionItem fields are filled at request time
}
```

Why not `resolveProvider: true`? `completionItem/resolve` lets the
server defer the `detail` + `documentation` fields until the user
highlights a specific item, saving bandwidth on large completion
sets. For Rigor's typical completion set (< 50 methods on most
receivers), the bandwidth saving is negligible and the round-trip
adds latency. v1 sends everything upfront; resolve becomes
relevant if a particularly-large enumeration ships
(`BasicObject` descendants, etc.).

When the trigger character is `:`, we MUST look at the character
immediately before — only `::` (constant path) is a meaningful
trigger; bare `:` is symbol-literal-start and v1 doesn't
auto-complete symbols.

### Parse recovery

Mid-edit buffers are ill-formed by definition. Prism's error
recovery produces a "best-effort" AST that's still walkable. The
completion pipeline tolerates parse errors and uses partial info.

Failure modes:

- Prism returns a usable AST but the call site's receiver type
  is `Dynamic[Top]` (inference couldn't narrow) → return empty
  completion list (the LSP-correct "we tried and got nothing").
- Prism fails to produce even a partial AST → fall back to
  **lexical context detection**: read the 200 characters
  preceding the cursor, match `/(\S+)\.(\w*)$/` for method
  completion, `/(::?[A-Z]\w*)+(::)?(\w*)$/` for constant path.
  If neither matches, return nil.
- Receiver is a literal `nil` → return only `NilClass`'s
  public methods (`nil?`, `inspect`, `to_s`).

### Filtering: server-side or client-side?

LSP clients (VSCode, Neovim's `nvim-cmp`, Emacs's `lsp-mode`)
all do fuzzy filtering on `CompletionItem[].label` against the
user's typed prefix. The server can also pre-filter by exact
prefix match, but doing so:

- Forces an `isIncomplete: true` flag so the client refetches
  after each keystroke.
- Disagrees with the editor's idiom of fuzzy / substring match.
- Doesn't save much: the server already enumerated everything;
  filtering N labels is cheap.

**Decision**: v1 returns the full candidate set for the receiver,
unfiltered. The client filters per its UX. The server applies
the visibility filter (private methods on non-`self` receivers)
because that's a correctness boundary, not a UX preference.

## Implementation slicing

Each slice ships its own commit + specs. Eight slices total —
four for hover, four for completion. Hover slices land first
because they're smaller and exercise the same underlying
`Scope#type_of` pipeline completion will lean on.

### Hover slices

1. **`HoverRenderer` collaborator + case-on-node dispatch
   scaffold.** Default body matches slice-5 output bit-for-bit;
   one specialisation lands (`Prism::CallNode` → receiver +
   signature). Spec covers the default + the call branch.
2. **Constant rendering** (`ConstantReadNode` / `ConstantPathNode`).
   FQN + singleton type + source location.
3. **Local + instance variable rendering**
   (`LocalVariableReadNode` / `InstanceVariableReadNode`). Type
   + bound-at line.
4. **Literal rendering polish** (`IntegerNode` / `StringNode` /
   `ArrayNode` / `HashNode` / `SymbolNode`). Literal value +
   carrier with refinement-name surfacing.

### Completion slices

5. **`textDocument/completion` registered + method completion
   for `obj.|`** with receiver type known. New `CompletionProvider`
   collaborator + new dispatch row in `Server`. Capability
   advertised. Spec covers a buffer at `"x = 'hi'; x.|"` returning
   `String`'s methods.
6. **Constant-path completion** for `Foo::|`. Enumeration via
   `Environment::Reflection#known_classes` filtered to children
   of the parent FQN.
7. **Union / Intersection / Refined receiver handling.**
   Intersection-of-methods for Union; underlying-nominal for
   Refined; ancestor-nominal for shape carriers.
8. **Parse recovery + lexical fallback** for buffers Prism
   can't recover from. Cursor-context regex matches `obj.` /
   `Foo::` shapes when AST is missing or incomplete.

## Performance targets

| Operation | Target wall clock | Path |
|---|---|---|
| Hover (slice 1-4) | < 100ms p95 | Scope#type_of + renderer dispatch. Same hot path as LSP v1's slice-5 hover plus ~10ms for the richer markdown build. |
| Completion `obj.\|` | < 150ms p95 | Parse buffer + locate + Scope#type_of + method enumeration. Method enumeration is bounded by class hierarchy depth; typical Ruby classes have <200 methods inherited. |
| Completion `Foo::\|` | < 50ms p95 | Constant resolution + known-classes prefix scan. Bounded by the count of known classes (~1,400 in DEFAULT_LIBRARIES + project sig). |

These assume the warm-cache, post-ProjectContext-warmup state
(LSP v1 slice 7 territory). Cold-start hover is bounded by the
underlying `Environment.for_project` cost (~3s) and not slice-
local.

## Out of scope for v2

- **`textDocument/signatureHelp`** — natural complement to
  completion (parameter-list hint inside the argument list).
  Queued because the surface is independent: hover + completion
  cover the cursor-stop and trigger-character cases; signatureHelp
  covers the within-argument-list case which is its own UX +
  parse-recovery problem.
- **Snippet expansion** — e.g. `def foo` → multi-line `def foo`
  body template. LSP supports it via `CompletionItem.insertTextFormat
  = 2` (Snippet); UX-driven, queued.
- **Hash-key completion** for `HashShape` carriers. Conceptually
  the most type-driven completion Rigor could ship — but parse
  recovery for `hash[:|]` is its own slice.
- **Bare-name completion** (locals + methods on implicit self).
  Surfaces every method on Object + every constant in scope; the
  noise-to-signal ratio is poor without good ranking heuristics.
- **Symbol completion** — `:|` triggering autocomplete of known
  symbols. Useful when symbols come from a known set (Hash keys
  / ActiveRecord scopes / etc.); needs plugin involvement.
- **Multi-overload signature presentation** — when an RBS method
  has multiple overloads, hover currently shows the first only.
  Multi-overload display is a markdown-table sub-problem.
- **Completion ranking via usage telemetry** — "the user picks
  `to_s` most often." No telemetry pipeline today; queued.

## Open questions

- **Union receiver completion**: intersection-of-methods is
  conservative but may surprise users ("why is `Integer#zero?`
  not in the list when receiver is `Integer | Float`?"
  Because `Float` has `zero?` too — actually it does; this
  example works). Pick the conservative default and revise
  if UX feedback says otherwise.
- **`completionItem/resolve` round-trip** — defer or eager?
  v1 eager (full payload on first request). Re-evaluate if
  `Object`-descended completion sets become noticeable.
- **Method definition source location for hover** — RBS
  declarations have `location` referencing the .rbs file. For
  user-facing hover, "defined in `lib/foo.rb:12`" is more
  useful than "defined in `sig/foo.rbs:5`". Resolving .rb
  source from .rbs declaration needs a project-side mapping
  table; not in the slice plan but worth noting for follow-up.
- **Plugin-side completion contributions** — a plugin
  (e.g. `rigor-rails-routes`) could contribute method names
  the analyzer wouldn't otherwise know (`signed_id`, helper
  methods). Plugin API extension needed; queued behind
  concrete plugin demand.
- **`textDocument/hover` `range` field** — return the source
  range of the hovered node so the editor highlights the exact
  expression instead of the single-character cursor position.
  Trivial extension; could land in slice 1 if cheap.

## Slicing rationale

Slices 1-4 (hover) ship before slices 5-8 (completion) because:

- Hover slices are smaller and exercise the same `Scope#type_of`
  + node-locator pipeline completion will lean on.
- The richer markdown rendering work (method signature, source
  location, refinement-name surfacing) is reusable between
  hover and completion's `CompletionItem.documentation`.
- A misstep in hover doesn't break the LSP session; a misstep
  in completion (parse recovery, AST walking on broken
  syntax) could.

Slice 5 lands completion's MVP (method completion only); 6-8
extend to constant paths, union / shape receivers, and parse
recovery. Each is independently revertable.
