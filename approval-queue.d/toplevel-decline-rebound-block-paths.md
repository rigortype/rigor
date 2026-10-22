# Decline in any proc value or Method-object block Rigor cannot follow to a known callee

- **PR:** [#2265](https://github.com/rigortype/rigor/pull/2265)
- **Issue:** [#2186](https://github.com/rigortype/rigor/issues/2186)
- **Class:** open-choice
- **Precedent:** [#2183](https://github.com/rigortype/rigor/pull/2183)
- **Decided:** 2026-10-21

## Background

#2186 lists a block passed through a variable (`blk = proc { … }; Ext.me(&blk)`), through `Ext.method(:me).call { … }`, and callees that reach their block local through a string eval or a non-receiverless `binding`. It does not say what the rule should do with a proc value it cannot follow, a `call` on something other than a literal `method(:name)`, or a computed `send` in a callee body.

## Options and trade-offs

- **Proc values.** Following only `local = proc { … }` read as `&local` or as the receiver of `call` / `[]` / `yield` and the like keeps the rule reporting on plain lambdas, and a literal called in place (`proc { … }.call`) keeps reporting too. Every other proc value (stored in an ivar or constant, passed as an ordinary argument, or in a method, or top-level code, that calls `binding` / `eval` / `local_variable_get` or a computed `send`) may reach `instance_exec` anywhere; the rule declines there (taken). A `def` bounds that scope; a class body is read as part of the code around it, which only declines more. Reporting there instead would keep more reports and some false positives.
- **Method objects.** A block to `call` / `bind_call` goes to the name a literal `method(:x)` / `instance_method(:x)` gives, through `bind`, `unbind`, `to_proc` and `curry`. On a receiver typed `Method`, `UnboundMethod` or `Proc` it declines; on any other receiver `call` is read by name like any callee (`class Svc; def self.call = yield; end; Svc.call { … }` keeps reporting) (taken, after the #2265 review).
- **Core receiver-eval methods.** A proc local handed to `instance_exec` / `instance_eval` / `class_eval` / `class_exec` / `module_eval` / `module_exec` runs under the receiver whatever the receiver is, so those names decline as callees (taken). `Class.new(&c)` keeps reporting: Ruby raises there.
- **Callee bodies.** `binding`, `eval` and `local_variable_get` count on any receiver and through `send`; a string `instance_eval` / `class_eval` / `module_eval` counts; a `send` with a computed name counts, since it may be `send(:binding)` (taken). Counting the computed `send` makes more callee names decline.

## Decision

Each choice follows the brief's conservative rule: when Rigor cannot prove the block runs under `main`, it declines, which only loses a report. The issue's `def self.d(&b) = Kernel.eval("module_eval(&b)")` in fact runs the block under `Kernel`, where Ruby raises NameError for `helper`; the rule declines there too, since the block does not run under `main`, and the spec witnesses `Kernel.eval("Ext.module_eval(&b)")` instead. The herb corpus moved by no row.

## To undo

`RebindingBlockCallees::Sites#value_targets` answers `[UNKNOWN]` for an unfollowable proc value; answer `[]` to keep reporting there. `#method_object_name` answers nil for an unknown `.call` receiver, which declines. `#reaches_locals?` holds the callee-body reading.
