# Appendix — Protocols, interfaces, and structural typing

If you arrived from Python, "protocol" means one specific thing:
`typing.Protocol`, PEP 544's **structural typing** — a class
satisfies a protocol by *having the right methods*, no inheritance
required. It is "static duck typing," and it is one of the first
things a Python typist reaches for.

That instinct is right, but the *word* is a trap in Rigor. Rigor's
structural-typing feature is not called "protocol" — it is the RBS
**`interface`**. Meanwhile "protocol" *does* appear in Rigor, naming
a **different** feature: a framework's path-scoped *behavioural
contract* ([ADR-28](../adr/28-path-scoped-protocol-contracts.md)).
This appendix untangles the two so you reach for the right one.

> **In this appendix**
> [Two things called "protocol"](#two-things-called-protocol) ·
> [Structural typing: RBS interfaces](#structural-typing-rbs-interfaces) ·
> [Object shapes and capability roles](#object-shapes-and-capability-roles) ·
> [Protocol contracts (ADR-28)](#protocol-contracts-adr-28) ·
> [Interface vs protocol contract](#interface-vs-protocol-contract) ·
> [Which one do I want?](#which-one-do-i-want) ·
> [What's next](#whats-next)

## Two things called "protocol"

| You mean… | The Rigor word | What it is | Lives where |
| --- | --- | --- | --- |
| "static duck typing" — a class fits if it has the methods (Python `Protocol`) | **interface** | A structural *type* in the type lattice. | RBS `interface _Foo`, read from `sig/` |
| "every action under `app/actions/` must define `#handle`" — a framework convention enforced by tooling | **protocol contract** | A *behavioural contract* bound to classes by file path, declared by a plugin. | A plugin's `protocol_contracts:` manifest field (ADR-28) |

The two are genuinely different axes — not two flavours of one
thing — and the rest of this page is mostly about keeping them
apart. The one-line discriminator:

- An **interface** is a *type* you name in a signature. The check
  happens *where the interface is mentioned* (`def f: (_Closable)
  -> void` checks `f`'s argument).
- A **protocol contract** is *never mentioned by the conforming
  class or any signature*. A plugin says "the classes under this
  directory carry this contract," and the engine provisions and
  checks them implicitly.

## Structural typing: RBS interfaces

This is the direct analogue of Python's `Protocol`. RBS has had
structural `interface _Foo` since its first release; Rigor reads
them from `sig/` and checks conformance structurally.

```python
# Python (PEP 544)
class SupportsClose(Protocol):
    def close(self) -> None: ...
```

```rbs
# RBS — the same idea
interface _SupportsClose
  def close: () -> void
end
```

A class that defines `close` with a compatible signature satisfies
the interface **with no `include`, no superclass, and no runtime
marker** — the match is structural. From the normative spec
([`structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md)):

> An RBS interface type … is a *named structural contract*. A
> nominal type or object shape is assignable to an interface when
> Rigor can prove that it provides all required members with
> compatible types.

Where does Rigor apply structural matching? Deliberately at the
**boundaries**, not class-to-class by default:

- assigning or passing a value where an RBS interface is expected;
- checking whether an inferred object shape satisfies an interface;
- a direct method send against a known shape;
- plugin-provided dynamic reflection adding members to a shape.

Ordinary `Foo`/`Bar` class compatibility stays **nominal** — Ruby's
own `is_a?` / `kind_of?` depend on the class hierarchy, and RBS uses
class names as declarations about Ruby constants, so Rigor does
*not* go fully TypeScript-style-structural for classes. Structural
typing is a tool you opt into by naming an interface, exactly as in
Python you opt in by annotating against a `Protocol`. (The
[mypy / Pyright appendix](appendix-mypy.md#protocols--rbs-interfaces)
covers the same mapping from the Python side.)

## Object shapes and capability roles

RBS interfaces are the *named* structural types. Rigor also infers
**anonymous** structural types — *object shapes* — from what a value
demonstrably responds to, and ships a curated catalogue of
**capability roles** for the common IO-like contracts:

- `_Reader`, `_Writer` — the read/write halves of a stream;
- `_RewindableStream`, `_ClosableStream` — `rewind` / `close`
  capabilities;
- `_Callable` — responds to `call`.

These keep `IO` and `StringIO` as separate *nominal* types while
letting each satisfy the smaller structural *roles* a method
actually needs — the structural-typing payoff (write against the
capability, not the concrete class) without giving up nominal
identity where Ruby's runtime relies on it.

If you came looking for "Rigor's Protocol," **this section is it**:
RBS interfaces + object shapes + capability roles are Rigor's
structural-typing surface. None of it is spelled "protocol."

## Protocol contracts (ADR-28)

Now the other axis. A Rack-shaped web framework expects a
controller action to take a request and return a response; a job
framework expects `#perform`; a serializer expects `#call`. The
convention is real, but it lives in the framework's prose — *no
class declaration records it*, and nothing checks it, so a
violation is a runtime surprise.

An RBS interface cannot express this. RBS (like Python) has **no
"every class under this directory implements interface I" form** —
an interface only bites where a signature names it, and these
controllers name nothing. That gap is what ADR-28's **protocol
contracts** fill.

A plugin that knows the framework declares a contract in its
manifest (`param_types` is an array of positional
`{ index:, type_name: }` provisions):

```ruby
# inside a framework plugin's manifest — an illustrative serializer contract
protocol_contracts: [
  Rigor::Plugin::ProtocolContract.new(
    path_glob:        "app/serializers/**/*.rb", # which files
    method_name:      :call,                      # the method every class must define
    param_types:      [{ index: 0, type_name: "ActiveRecord::Base" }],
    return_type_name: "String",
    severity:         :error
  )
]
```

The engine then does **provide-and-check**:

- **Provide** (engine-side). When binding a `def call(record)` in a
  matching file, the contract's `param_types` *replace* the usual
  `Dynamic[Top]` the un-annotated parameter would get. The body is
  then analysed as if `record` carried its real type — so a misuse
  inside the body (`record.no_such_column`) surfaces as an ordinary
  `call.undefined-method`, and the inferred return type is precise.
- **Check** (plugin-side). The plugin confirms every class in a
  matching file defines the method (else `missing-protocol-method`)
  and that its inferred return type conforms to `return_type_name`
  (else `protocol-return-mismatch`).

The provision half is the load-bearing one: without it, `request`
is `Dynamic[Top]`, which answers every method, so any return built
from it is also `Dynamic[Top]` and the return check is vacuous.

Two things to note as an *application* developer (not a plugin
author):

- You **never write** `protocol_contracts:` — the framework's
  plugin does. You write a plain `def handle(request)`, and it gets
  checked for free.
- The `missing-protocol-method` / `protocol-return-mismatch`
  diagnostics are **plugin diagnostics**, emitted under the
  plugin's `plugin.<id>.` provenance — not core Rigor rules. The
  worked references are [`examples/rigor-web/`](../../examples/rigor-web/)
  (the minimal tutorial) and [`plugins/rigor-hanami/`](../../plugins/rigor-hanami/)
  (production Hanami 2 actions).

## Interface vs protocol contract

| | RBS `interface` (structural type) | ADR-28 protocol contract |
| --- | --- | --- |
| **What it is** | A type in the lattice | A tooling-enforced convention; *not* a type |
| **Python analogue** | `typing.Protocol` | (none — closer to Smalltalk/Swift "protocol") |
| **How a class opts in** | Structurally — just have the methods | Implicitly — be defined under the path glob |
| **Where it's referenced** | Named in a signature (`(_Closable) -> void`) | Named *nowhere*; bound by file path |
| **Where the check fires** | At the use site that names the interface | At the contracted `def` (provide) + per class (check) |
| **Who declares it** | Whoever writes the `.rbs` | A framework plugin's manifest |
| **Provides parameter types?** | No (it's a type, used where named) | **Yes** — into an un-annotated `def` |
| **Diagnostics** | Core type errors at the use site | `missing-protocol-method`, `protocol-return-mismatch` (plugin) |

The naming overlap is historical: "protocol" in the
Smalltalk / Objective-C / Swift tradition means exactly "a named
set of methods a conforming type must implement," which is what a
protocol contract is. Python's `typing.Protocol` borrowed the word
for the *structural-type* idea, and Ruby/RBS settled on `interface`
for that — so in Rigor, "protocol" never means the structural type.

## Which one do I want?

- You want to **write a method that accepts anything with a
  `#close`** → that is a structural type. Declare an RBS
  **`interface _Closable`** and annotate against it (or rely on
  inferred object shapes for the anonymous case). See
  [Chapter 7 — RBS and RBS::Extended](07-rbs-and-extended.md).
- You want to **enforce that every class in a directory implements
  a framework method with given parameter/return types** → that is
  a **protocol contract**, and it is a *plugin-authoring* feature.
  See [ADR-28](../adr/28-path-scoped-protocol-contracts.md) and the
  [`examples/`](../../examples/README.md) walkthroughs.
- You are an **application developer** using such a framework → you
  do neither explicitly. Write idiomatic Ruby; the framework's
  plugin supplies the contract, and Rigor checks your actions
  against it. When you see `missing-protocol-method`, you forgot
  the method the framework requires; when you see
  `protocol-return-mismatch`, your action returns the wrong shape.

## What's next

- [Chapter 7 — RBS and RBS::Extended](07-rbs-and-extended.md) — how
  to write the `.rbs` an interface lives in.
- [Chapter 9 — Plugins](09-plugins.md) and the
  [examples/ landing page](../../examples/README.md) — where
  protocol contracts are authored.
- [`docs/type-specification/structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md)
  — the normative spec for interfaces, object shapes, and
  capability roles.
- [ADR-28](../adr/28-path-scoped-protocol-contracts.md) — the
  protocol-contract design decision and its rejected alternatives
  (including *why* an RBS interface bound by directory was not the
  route).
- Coming from another checker? The
  [mypy / Pyright appendix](appendix-mypy.md#protocols--rbs-interfaces)
  maps `Protocol` ↔ RBS `interface` from the Python side, and the
  [type-theory appendix](appendix-type-theory.md) places nominal vs
  structural typing in the broader landscape.
