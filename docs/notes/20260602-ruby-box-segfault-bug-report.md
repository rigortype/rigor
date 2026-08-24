# Bug report — `Ruby::Box` SIGSEGV: isolated proc loses its box (root cause found)

Draft for [bugs.ruby-lang.org](https://bugs.ruby-lang.org) following
[How To Report](https://github.com/ruby/ruby/wiki/How-To-Report).
Surfaced while prototyping ADR-39 slice 5 (running Rigor's analyzer under
`RUBY_BOX=1` for plugin target-library isolation).

**2026-08-24 update — root cause identified, minimal reproducer found, patch
written and verified.** The original draft (kept below as history) could not
isolate a self-contained reproducer; the missing ingredient was
`Ractor.make_shareable` on a proc defined at a class/module body. Everything
in this section supersedes the "Notes / minimization status" of the original.

---

**Category:** core
**Target version:** master (reproduced at `042e2bfd39`, 2026-08-24; originally hit on 4.0.5)
**`ruby -v`:** `ruby 4.1.0dev (2026-08-24T10:31:23Z master 042e2bfd39) +PRISM [arm64-darwin25]`

## Summary

Under `RUBY_BOX=1`, **any method call inside a proc that was isolated by
`Ractor.make_shareable` and defined at a class or module body** crashes the VM
with a `SIGSEGV` at address 0x0 in the method-lookup path. The same program
runs fine without `RUBY_BOX=1`, and a proc defined inside a method (not at a
class body) is unaffected.

## Reproduction

```
RUBY_BOX=1 ruby -e 'module M; L = Ractor.make_shareable(->(*a){ Rational(*a) }); end; p M::L.call(3, 4)'
# => -e:1: [BUG] Segmentation fault at 0x0000000000000000
ruby -e 'module M; L = Ractor.make_shareable(->(*a){ Rational(*a) }); end; p M::L.call(3, 4)'
# => (3/4)
```

The body is irrelevant — `a.to_s`, `1.zero?`, `String.name` all crash the
same way; the crash needs only (a) `RUBY_BOX=1`, (b) a proc whose lexically
enclosing local env is a TOP/CLASS frame, (c) `Ractor.make_shareable` (or
`Proc#isolate`) applied to it, and (d) any method dispatch inside the call.

## Root cause

For a `VM_FRAME_MAGIC_TOP` / `VM_FRAME_MAGIC_CLASS` frame, the env's SPECVAL
slot (`ep[VM_ENV_DATA_INDEX_SPECVAL]`) stores **the box pointer**, not a block
handler — that is what `VM_ENV_BOX()` reads and what `rb_current_box()`
returns through `current_box_on_cfp()` for code running under such a frame.

`env_copy()` (vm.c), used by `Ractor.make_shareable` → `proc_isolate_env()`,
rebuilds a local env with:

```c
    else {
        ep[VM_ENV_DATA_INDEX_SPECVAL] = VM_BLOCK_HANDLER_NONE;
    }
```

so the copied env keeps its frame type (MAGIC_CLASS, copied inside FLAGS) but
**loses its box**. At call time, the first method lookup inside the isolated
proc walks `lep` to that env, takes the TOP/CLASS branch of
`current_box_on_cfp()`, and gets `VM_ENV_BOX(lep) == NULL`; the classext
lookup then dereferences `box->box_object` — offset 0 of `rb_box_t` — which
is the observed `SIGSEGV at 0x0000000000000000` under
`rb_vm_search_method_slowpath` → `search_method0` (inlined as
`prepare_callable_method_entry` in the 4.0.5 release-build backtrace of the
original report).

## Fix (verified)

Preserve the SPECVAL slot when the source env belongs to a TOP/CLASS frame:

```c
    else if (VM_ENV_BOXED_P(src_ep)) {
        // A TOP/CLASS local env stores its box, not a block handler, in the
        // SPECVAL slot (VM_ENV_BOX). Preserve it: method lookup inside the
        // isolated proc reads the box back via rb_current_box(), and a
        // cleared slot dereferences a NULL box.
        ep[VM_ENV_DATA_INDEX_SPECVAL] = src_ep[VM_ENV_DATA_INDEX_SPECVAL];
    }
```

Patch + regression test (`test_method_call_in_isolated_proc_from_class_frame`
in `test/ruby/test_box.rb`) live on the local CRuby checkout
`~/local/src/ruby`, branch `fix/box`, commit `17c202960e` (on top of master
`042e2bfd39`). Red/green verified: the test fails (segfault in the separated
process) without the vm.c change and passes with it;
`test_box.rb` + `test_proc.rb` + `test_ractor.rb` all green (288 tests, 0
failures) with the fix.

With the fix, the original real-world workload — `rigor check` over the whole
Redmine `app` under `RUBY_BOX=1` — runs to completion, and the `ruby_box`
plugin-isolation strategy produces diagnostics identical to the `none` /
`process` strategies (PR #469).

## Why Rigor hit it

Rigor makes module-scope lambdas Ractor-shareable as a standard pattern for
its worker pools (e.g. `KernelDispatch::NUMERIC_CONSTRUCTORS`,
`Ractor.make_shareable(->(*args) { Rational(*args) })`). Analysing any file
whose inference reaches such a fold (Redmine's `app/models/issue.rb` triggers
the `Rational` constructor fold) calls an isolated proc → first in-proc method
dispatch → crash. That is why the original bisection converged on one input
file and why plain synthetic recursion/dispatch stress never reproduced it.

## Secondary upstream finding — `Ruby::Box#require` does not consult the box's RubyGems

Not a crash, but worth reporting alongside: `Ruby::Box#require` calls
`rb_require_string()` directly, which resolves only against the raw
`$LOAD_PATH`. The box's own RubyGems (each box loads RubyGems independently,
per `doc/language/box.md`) never runs, so a gem-installed library is
unreachable through `Box#require` while `box.eval("require 'the_gem'")`
succeeds (gem activation via the in-box `Kernel#require`). Asymmetry:

```ruby
b = Ruby::Box.new
b.eval("require 'active_support/inflector'")  # => true; gem activates
Ruby::Box.new.require("active_support/inflector") # => LoadError
```

Rigor works around it by falling back to the in-box require (PR #469); the
question for upstream is whether `Box#require` should behave like the box's
`Kernel#require`.

---

## Original draft (2026-06-02, superseded — kept for the submission's history)

**`ruby -v`:** `ruby 4.0.5 (2026-05-20 revision 64336ffd0e) +PRISM [arm64-darwin25]`

Running a large program with the experimental `Ruby::Box` enabled
(`RUBY_BOX=1`) crashes with a `SIGSEGV` (null-pointer dereference at
`0x0`) inside the VM's method-lookup path
(`rb_vm_search_method_slowpath` → `callable_method_entry_or_negative` →
`prepare_callable_method_entry`). The identical program run **without**
`RUBY_BOX=1` completes normally.

The smallest reliable reproduction then known was a single-file run of the
`rigor` static analyzer over Redmine's `app/models/issue.rb` (~2,140 lines):

```
RUBY_BOX=1 bundle exec rigor check app/models/issue.rb   # SIGSEGV
bundle exec rigor check app/models/issue.rb              # exit 0
```

Established by bisection at the time: `RUBY_BOX=1` is the trigger; no user
sub-boxes involved; bisected to that single file; not the degraded
no-RBS-env path. Pure-Ruby attempts that did **not** reproduce it: deep
recursion, megamorphic dispatch across 300 classes, a 131k-node recursive
`each` walk, a 40-deep `super` mixin chain × 120 subclasses + `GC.stress`,
plain `Ruby::Box.new` + `box.require`. (All of these lacked the actual
ingredient, `Ractor.make_shareable` on a class-body proc.)
