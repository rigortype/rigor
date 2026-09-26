# Global Variables

This document defines how Rigor types a read of a global variable:

- where the type comes from, in precedence order;
- where Ruby keeps each special variable, and what Rigor binds and forgets there;
- which evidence may change a type Rigor reads by idiom;
- which writes to a special variable Rigor reports.

The edges that bind a special variable and the code that forgets it are specified in [control-flow-analysis.md](control-flow-analysis.md); this document links to them rather than restating them. The modules that implement both are mapped in [`inference-engine.md` § Special variables](../internal-spec/inference-engine.md#special-variables).

`Dynamic[top]` is Rigor's internal notation for RBS `untyped` ([special-types.md](special-types.md)), and `bot` is the empty type.

Three terms recur here and in the documents that link to it ([`CONTEXT.md`](../../CONTEXT.md)):

- A **frame-local special** is a special variable Ruby keeps in the special-variable slot of the method, class, module or file body that runs the code: `$~`, the match globals derived from it, and `$_`.
- **Declaration-sourced** type information comes from a declaration rather than from the flow of the body being read. It is real type information, but not diagnostic fuel ([ADR-58](../adr/58-ivar-field-typing.md)).
- The **idiomatic expectation** of a global is the type the language's idioms lead a reader to expect it to hold where the runtime guarantees less ([ADR-117](../adr/117-standard-streams-typed-by-idiom.md) Decision point 2): `$stdout` holds an `IO`, although its setter only requires an object that responds to `write`.

## Where a global's type comes from

A read of a global variable takes its type from the first of these sources that holds at the read:

1. a flow binding, made by a write in the body being read or by a special variable's own binding point;
2. a narrowing of that binding by a guard;
3. the program-global seed the body started from;
4. the idiomatic expectation, which is decided for the streams but not implemented as of this writing;
5. `Dynamic[top]`.

A narrowing refines whichever of the other sources the read would have taken, and a write replaces all of them. The numbered and back-reference match globals are the exception to the last step (§ [Match references](#match-references)).

### A flow binding

A write to a global in the flow that reaches the read (`$g = v`, `$g ||= v`, `$g += v`) binds it to the type the write computes, as a local write does. A later write replaces the binding. Where two paths join, a global both paths bind reads the union of the two bindings, and a global only one path binds is unbound past the join.

A special variable also has binding points of its own, which the [slot table](#special-variable-slots) lists: a `=~` predicate binds the match globals on its edges, a reader condition binds `$_`, a `rescue` clause binds `$!` and `$@`, and a statement that certainly ran a subprocess binds `$?`.

A direct write inside a loop body or a `begin` body is not joined into the next pass or into a rescue clause ([#1464](https://github.com/rigortype/rigor/issues/1464)), and a write to `$~` leaves the other match globals narrowed from the earlier match ([#1472](https://github.com/rigortype/rigor/issues/1472)).

### A narrowing

A guard narrows a global read as it narrows a local read: truthiness, `nil?`, `!`, safe navigation, the class guards and `respond_to?` ([Guards on globals and constants](control-flow-analysis.md#guards-on-globals-and-constants), [#1429](https://github.com/rigortype/rigor/issues/1429)). It narrows whatever type the read would otherwise have: a flow binding, the seed, or the type an unbound read has. A guard does not narrow a match reference (`$1`, `$&`, …), which only a `=~` predicate binds ([#1477](https://github.com/rigortype/rigor/issues/1477)). Where the narrowing stops holding depends on the variable:

- **A process-wide global, and `$?`.** Ruby code the analysis cannot see may assign the global between the guard and a read. So wherever code may run that rebinds it, the read reverts to the union of the narrowed type and the binding the guard narrowed. The code that counts, and the gaps, are listed in the section linked above. `$stdout` and `$>` are one variable there: a write to either ends a guard's narrowing of the other.
- **A frame-local special, and `$!` and `$@`.** A called method cannot reach the first two, and a call that returns leaves the last two as they were, so a guard's narrowing of them is not reverted by that rule. Each is forgotten where its own rules in the [slot table](#special-variable-slots) forget it.

### The program-global seed

A method body the analysis enters, and the file's top level, start with each global the file writes bound to its seed ([#1362](https://github.com/rigortype/rigor/issues/1362)):

- The seed is the union of the values the file's plain writes (`$g = v`) assign, anywhere in the file, each typed without the locals of the body it sits in, so `$g = arg` contributes `Dynamic[top]`. A compound write (`$g ||= v`) and a multiple-assignment target do not contribute. Nor does a write in another file: the seed is per file.
- For a global whose RBS declaration is Ruby's own (in the `rbs` gem's `core/` or `stdlib/` tree), the seed is also joined with the non-`nil` members of the declared type ([#1433](https://github.com/rigortype/rigor/pull/1433)), so a write can only widen it. `$VERBOSE = true` seeds `bool`, `$stderr = StringIO.new` seeds `IO | StringIO`, and `$0 = "prog"` seeds `"prog" | String`. The declared members are **declaration-sourced**: a report that the file's writes alone would not earn MUST NOT rest on them ([ADR-58](../adr/58-ivar-field-typing.md), [ADR-117](../adr/117-standard-streams-typed-by-idiom.md) Decision point 2). The gates that enforce this are [`inference-engine.md` § Declaration-sourced provenance mark (ADR-58)](../internal-spec/inference-engine.md#declaration-sourced-provenance-mark-adr-58). A write or a narrowing in the flow makes the binding flow-live, and the gates then no longer apply to it.
- A global only a project or gem signature declares, or none does, is seeded with the union of the file's writes alone.
- `$_` and `$~` are not seeded ([#1359](https://github.com/rigortype/rigor/issues/1359)): each body has a slot of its own. `$!`, `$@` and `$?` are not either ([#1360](https://github.com/rigortype/rigor/issues/1360)): none holds a program-wide value.
- A global the file never writes has no seed.
- A class or module body, and a method body re-typed for a call site by the inter-procedural return inference, start with no global bound, so a global they do not write reads `Dynamic[top]` there ([#1473](https://github.com/rigortype/rigor/issues/1473)).

> **Decided, not implemented as of this writing ([#1437](https://github.com/rigortype/rigor/issues/1437)).** The declared `nil` is not joined (`$VERBOSE: bool?` joins `bool`), and the nil-bearing separators `$/`, `$,`, `$;`, `$\`, `$-0`, `$-F` and `$-i` are seeded with the file's writes alone, so `$, = "-"` seeds `"-"`. A declared `nil` would reach a nil-receiver or argument report through a value that mixes the global with something else (`sep = c ? $/ : ";"`), which the declaration-sourced mark does not follow. Joining them waits for a nil-only provenance record.

### The idiomatic expectation

> **Decided for the streams, not implemented as of this writing ([#1366](https://github.com/rigortype/rigor/issues/1366)).** [ADR-117](../adr/117-standard-streams-typed-by-idiom.md) WD1: an unbound `$stdin`, `$stdout` or `$stderr` reads as `IO`, and `$>` reads and joins as `$stdout` does. #1366 proposes the same fallback to the RBS declaration for every other special, and to a project `sig/` declaration for any global, with its corpus result as the go/no-go. `$_` is excluded: a declined or forgotten `$_` MUST keep reading `Dynamic[top]`, never its declared `String?` (WD6). Today no unbound global reads its declaration, and `$>` and `$stdout` keep separate seeds, as do the other names Ruby gives one global twice (`$-v` and `$VERBOSE`, `$-d` and `$DEBUG`, `$-0` and `$/`, `$-F` and `$;`, `$PROGRAM_NAME` and `$0`).

The expectation is the type Rigor reads, not a claim about the runtime class: application code may run with a `StringIO` behind `$stdout` and has no business knowing it. Rigor never warns that a value might deviate from the expectation. Only the evidence in § [The evidence boundary](#the-evidence-boundary) changes it.

The `English` aliases (`$LAST_MATCH_INFO`, `$ERROR_INFO`, `$CHILD_STATUS`, …) are ordinary globals as of this writing: none reads, narrows or binds as the special it aliases ([#1443](https://github.com/rigortype/rigor/issues/1443)).

### `Dynamic[top]`

Every other read is `Dynamic[top]`: an unbound special, and any global neither the flow nor the seed binds.

### Match references

`$1`, `$2`, … and the back-references `$&`, `` $` ``, `$'` and `$+` are not global-variable reads in Prism's tree, and they read a fixed `String?` wherever the scope does not bind them. `$~` is an ordinary global read, so it reads `Dynamic[top]` unbound.

## Special-variable slots

Ruby keeps a special variable in one of four kinds of place, and the place decides which code can change the value between a binding and a read. Rigor binds a special only where the code shows its value, and forgets the binding wherever code that may change it runs.

| Variables | Where Ruby keeps it | Bound by | Forgotten by | Other bodies | Unbound read |
| --- | --- | --- | --- | --- | --- |
| `$~` and the match globals `$&`, `` $` ``, `$'`, `$+`, `$1`, `$2`, … | The method frame: the special-variable slot of the method, class, module or file body that runs the match ([#1358](https://github.com/rigortype/rigor/issues/1358)). | The edges of a `=~` predicate ([Regexp match-predicate narrowing](control-flow-analysis.md#regexp-match-predicate-narrowing)), and a write to `$~`. | Code that may rebind the slot, per the same section. `$10` and later groups are not forgotten yet ([#1384](https://github.com/rigortype/rigor/issues/1384)). | See below. | `$~`: `Dynamic[top]`. The others: `String?`. |
| `$_` | The method frame, beside `$~` ([#1359](https://github.com/rigortype/rigor/issues/1359)). | The edges of a reader condition ([Last-line (`$_`) narrowing](control-flow-analysis.md#last-line-_-narrowing)), including an implicit-self `gets` ([#1415](https://github.com/rigortype/rigor/issues/1415)) but not yet an implicit-self `readline` ([#1458](https://github.com/rigortype/rigor/issues/1458)), and a write. | Code that may set the slot, per the same section. Two arms that bind it apart join with it unbound. | See below. An `ensure` clause reads a bound `$_` as `Dynamic[top]`. | `Dynamic[top]`, never its declared `String?` (ADR-117 WD6). |
| `$!`, `$@` | The nearest rescue frame of the running execution context, so a method a `rescue` clause calls reads the exception too ([#1360](https://github.com/rigortype/rigor/issues/1360)). | Entering a `rescue` clause or a rescue modifier's fallback ([Rescue and subprocess globals](control-flow-analysis.md#rescue-and-subprocess-globals)). A clause that guards `$!`, or its `=> e` local, by class binds neither ([#1447](https://github.com/rigortype/rigor/issues/1447)). | Restored past the `begin` or the modifier to what they were where it started. An `ensure` clause reads them unbound. | See below. A method body starts unbound. | `Dynamic[top]` |
| `$?` | The thread: a subprocess a called method runs sets its caller's `$?`, and a fiber shares its thread's ([#1360](https://github.com/rigortype/rigor/issues/1360)). | A statement that certainly ran a subprocess, in a file that holds no call that may reset it to `nil` (same section). | Entry to a rescue clause, a statement that may fall through a rescue, a retried body, a join with a path that did not set it. A guard's narrowing reverts as a process-wide global's does. | See below. A method body starts unbound. | `Dynamic[top]` |
| Every other global: the streams, the separators, `$VERBOSE`, `$0`, the program's own globals | The process. | A write in the flow, and the program-global seed at a body's entry. | A guard's narrowing reverts where code may rebind the global ([Guards on globals and constants](control-flow-analysis.md#guards-on-globals-and-constants)). | A block reads the flow's binding. | The seed, else `Dynamic[top]`. |

What a block, a closure or a new execution context reads:

- **A block** shares the frame of the body that creates it, so it reads that body's bindings of the frame-local specials. It forgets them on entry when its own body may rebind them, since a later iteration runs after an earlier one did, and when the creating body makes a closure that may. A block a `rescue` clause runs reads `$!` and `$@` as the clause does.
- **A closure's body**, a lambda literal or the block of `lambda`, `proc`, `Proc.new`, `Enumerator.new` or `Hash.new`, runs whenever it is called, usually after the clause it is written in has exited, and possibly on another thread. It starts with `$!`, `$@` and `$?` unbound. It still reads the frame-local specials where it is written, not where it is called, a gap ([#1371](https://github.com/rigortype/rigor/issues/1371)).
- **The root block of a new execution context**, the block of `Thread.new`, `Thread.start`, `Thread.fork`, `Fiber.new` or `Ractor.new` on the core constant, runs with a special-variable slot and an execution context of its own. It MUST start with the frame-local specials, `$!` and `$@` unbound, and `$?` too unless it is a fiber's ([#1361](https://github.com/rigortype/rigor/issues/1361)). A match or a reader it runs does not rebind the creating body's slot. It enters with every guard narrowing of a process-wide global reverted. `Enumerator.new`'s block is not a root block: it runs on an internal fiber whose root is not the block, so it shares the creating body's slot.
- **A `define_method` or `define_singleton_method` body** runs as a method body whenever the method is called, on the slot of the body that defined it. The narrowing where it is written neither proves nor refutes what it reads there, so a bound frame-local special, `$!`, `$@` or `$?` MUST read `Dynamic[top]` in it, and an unbound one stays unbound ([#1361](https://github.com/rigortype/rigor/issues/1361)).
- **An `ensure` clause** runs after the body, after a `rescue` clause, and after a `return`, `break` or `next` out of either. It reads a bound `$_` as `Dynamic[top]`, and `$!`, `$@` and `$?` unbound ([#1415](https://github.com/rigortype/rigor/issues/1415), [#1360](https://github.com/rigortype/rigor/issues/1360)).

`Process.last_status` is a method, not a global read. It reads `$?`'s binding where `$?` is bound, and the `Process::Status?` Rigor's core overlay declares for it where `$?` is unbound; a program that defines the method itself reads `Dynamic[top]`.

## The evidence boundary

The idiomatic expectation holds without configuration. Only what the analysed code and its configuration literally show changes it, never a file's name, its directory or a framework's convention ([ADR-117](../adr/117-standard-streams-typed-by-idiom.md) Decision point 3). No report and no certainty verdict (a dropped arm, an unreachable clause) MUST rest on the idiomatic type against such evidence.

**A class guard** is such evidence: `is_a?`, `kind_of?`, `instance_of?`, `C === $g`, `case $g when C` and `case $g in C` say that the global may hold a `C` ([#1429](https://github.com/rigortype/rigor/issues/1429)). The rules are in [Class guards](control-flow-analysis.md#class-guards) and [Guards on globals and constants](control-flow-analysis.md#guards-on-globals-and-constants). In summary:

- **The arm.** When the guard's class is disjoint from a `Nominal` member of the receiver's type (`$stdout` typed `IO`, guarded by `is_a?(StringIO)`), the arm reads the receiver as `bot`, so no call on it is checked: `$stdout.is_a?(StringIO) ? $stdout.string : nil` is quiet. A call on that `bot` receiver may run any code, so past it the guard's narrowing reverts.
- **No verdict.** A `when C` or `in C` clause whose subject holds such a member does not report `flow.unreachable-clause`. That rule reads a `case` on a local only, so it never reports a `case $stdout`; `io = $stdout; case io when StringIO` is the shape the decline covers.
- **`respond_to?`** narrows as [Class guards](control-flow-analysis.md#class-guards) states: its truthy edge drops the members known to lack the method, and reads the receiver as `Dynamic[top]` when no member may respond and one of them is a `Nominal` other than `NilClass`, `TrueClass` or `FalseClass`.
- **The value.** An `if`, `unless` or ternary keeps the arm's value, and so does a `case` run as a statement or as the value of a write. A `case` the analysis types as an expression, such as an argument or a collection element, drops the arm from its value. That drop is a verdict the rule above forbids.

> **Not implemented as of this writing ([#1465](https://github.com/rigortype/rigor/issues/1465)).** Keeping the arm of such a `case` wherever it is typed, without leaking the guarded class past the guard.

**Configuration** is the other source of evidence. A test helper that swaps a stream (`config.before { $stdout = StringIO.new }`) is a monkey patch in [ADR-17](../adr/17-monkey-patch-pre-evaluation.md)'s sense, and it is meant to reach the engine as a `pre_eval:` entry scoped to the paths it serves.

> **Decided, not implemented as of this writing ([#1426](https://github.com/rigortype/rigor/issues/1426), [#1427](https://github.com/rigortype/rigor/issues/1427)).** A `pre_eval:` entry scoped to paths, whose global writes re-type the global for that scope (#1426), and the `rigor-project-init` skill writing that entry from the project's own test wiring (#1427). Today a `pre_eval:` file's global writes reach no other file, and every entry applies project-wide.

A file under `spec/` or `test/`, a `test_paths:` root, and a file named `spec_helper.rb` or `test_helper.rb` are not evidence, and change no type.

The reader assumption behind `$_` applies the same boundary to readers: counter-evidence the analysed file shows declines the narrowing, and a replacement the file does not show is assumed away ([Last-line (`$_`) narrowing](control-flow-analysis.md#last-line-_-narrowing), ADR-117 WD4).

## The write side

Two rules check a write to a special variable. The envelope is the interpreter's setter, not the global's RBS declaration: where the two differ, the setter wins ([ADR-117](../adr/117-standard-streams-typed-by-idiom.md) Decision point 1 and WD2, [#1367](https://github.com/rigortype/rigor/issues/1367)). The catalogue row is the `global.*` family in [diagnostic-policy.md § Identifier taxonomy](diagnostic-policy.md#identifier-taxonomy), and each rule's full list of setters is in the manual ([`global.write-type-mismatch`](../manual/04-diagnostics.md#rule-global-write-type-mismatch), [`global.readonly-write`](../manual/04-diagnostics.md#rule-global-readonly-write)).

- **`global.readonly-write`** reports a write in a form that always writes (`$g = v`, `$g op= v`, a target of a multiple assignment) to a special Ruby defines read-only (`$!`, `$?`, `$$`, `$LOAD_PATH`, …), which raises `NameError` whatever the value.
- **`global.write-type-mismatch`** reports `$g = v` only when `v` is a literal node whose class the setter rejects: `$stdout = 1` reports, and `$stdout = buf` never does, whatever `buf`'s type. Among the declines the manual lists, the literal stays quiet when the program may define the method the setter asks for (`write`, `to_str`, `to_int`) or an escape hatch (`method_missing`, `respond_to_missing?`, `respond_to?`) in any file, in any spelling and on any receiver. That program-wide definition census declines rather than guessing which objects such a definition reaches.
- A special any file aliases (`alias $out $stdout`, either side) is exempt from both rules. A write to `$stdin`, whose setter accepts every value, is never checked.

Neither rule reads an inferred type, and neither changes how a later read is typed. The writes the rules leave unreported are [#1455](https://github.com/rigortype/rigor/issues/1455).
