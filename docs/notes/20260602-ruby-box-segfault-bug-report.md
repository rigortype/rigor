# Bug report draft — `Ruby::Box` SIGSEGV in `prepare_callable_method_entry`

Draft for [bugs.ruby-lang.org](https://bugs.ruby-lang.org) following
[How To Report](https://github.com/ruby/ruby/wiki/How-To-Report).
Surfaced while prototyping ADR-39 slice 5 (running Rigor's analyzer under
`RUBY_BOX=1` for plugin target-library isolation).

---

**Category:** core
**Target version:** master / 4.0
**`ruby -v`:** `ruby 4.0.5 (2026-05-20 revision 64336ffd0e) +PRISM [arm64-darwin25]`

## Summary

Running a large program with the experimental `Ruby::Box` enabled
(`RUBY_BOX=1`) crashes with a `SIGSEGV` (null-pointer dereference at
`0x0`) inside the VM's method-lookup path
(`rb_vm_search_method_slowpath` → `callable_method_entry_or_negative` →
`prepare_callable_method_entry`). The identical program run **without**
`RUBY_BOX=1` completes normally. So enabling `Ruby::Box` changes
method-entry resolution in a way that can dereference NULL on a
sufficiently complex workload.

## Reproduction process

A self-contained pure-Ruby reproducer is not yet isolated (see "Notes");
the smallest reliable reproduction is a single-file run of the `rigor`
static analyzer (which only *parses and statically analyses* the input —
it never executes it):

1. `ruby 4.0.5`, arm64-darwin (macOS).
2. Statically analyse one sufficiently complex Ruby file (here Redmine's
   `app/models/issue.rb`, ~2,140 lines) with the box enabled:
   ```
   RUBY_BOX=1 bundle exec rigor check app/models/issue.rb   # SIGSEGV
   bundle exec rigor check app/models/issue.rb              # exit 0
   ```
   No `Ruby::Box.new` sub-boxes are created — only the process-wide
   `RUBY_BOX=1` flag is set; the crash is in ordinary (main-box) method
   dispatch as the analyzer runs.

## Result of the reproduction process

`SIGSEGV`. Crash report (excerpt):

```
... [BUG] Segmentation fault at 0x0000000000000000
ruby 4.0.5 (2026-05-20 revision 64336ffd0e) +PRISM [arm64-darwin25]

-- C level backtrace information -------------------------------------------
libruby-4.0.5.dylib(rb_vm_bugreport+0xbc8)
libruby-4.0.5.dylib(rb_bug_for_fatal_signal)
libruby-4.0.5.dylib(sigsegv)
libsystem_platform.dylib(_sigtramp+0x38)
libruby-4.0.5.dylib(prepare_callable_method_entry)          <-- crash
libruby-4.0.5.dylib(prepare_callable_method_entry)
libruby-4.0.5.dylib(callable_method_entry_or_negative)
libruby-4.0.5.dylib(rb_vm_search_method_slowpath)
libruby-4.0.5.dylib(vm_exec_core)
libruby-4.0.5.dylib(rb_vm_exec)
... (deep rb_yield / rb_ary_each / vm_exec_core recursion below)
```

The Ruby-level control frames show a deep recursive `each`-driven
evaluation; the fault occurs while resolving a method during that
recursion. Exit status 139 (`SIGSEGV`).

## Expected result

The program should either complete (as it does without `RUBY_BOX=1`) or
raise a normal Ruby-level exception. The VM must not dereference NULL in
`prepare_callable_method_entry`; enabling `Ruby::Box` should not turn a
working program into a segfault.

## Notes / minimization status

What was established by bisection:

- **`RUBY_BOX=1` is the trigger.** Every command above exits 0 without it.
- **Independent of `Ruby::Box.new` sub-boxes** — reproduces with only the
  process-wide flag set; no user boxes are created.
- **Bisected to a single input file.** Crash on the whole Redmine `app/`
  → narrowed to `app/models/` (86 files) → binary-searched to the single
  file `app/models/issue.rb`. That one ~2,140-line file alone segfaults
  under `RUBY_BOX=1`; the analyzer's own source (`rigor check lib`,
  248 files) does **not** crash under `RUBY_BOX=1`. So the trigger is the
  *combination* of `RUBY_BOX=1` + analysing one sufficiently complex
  file, not file count.
- It is **not** the "degraded / no-RBS-env" path: analysing 248 files
  with a deliberately malformed `sig/` (so the RBS env build fails) under
  `RUBY_BOX=1` does not crash.

What did **not** reproduce it (pure-Ruby attempts under `RUBY_BOX=1`):

- Plain deep recursion (`def f = f; f` → normal `SystemStackError`).
- Megamorphic dispatch across 300 module-including classes + recursion.
- A 131k-node tree walked recursively via nested `each` blocks with
  megamorphic per-node dispatch.
- A 40-deep `super` mixin chain × 120 subclasses + `GC.stress`.
- `require "rbs"` / `Ruby::Box.new` + `box.require` (load fine).

So the fault needs a method-resolution pattern specific to the analyzer's
hot path that a simple synthetic does not capture; a self-contained
minimal reproducer is still open. The full macOS crash report
(`~/Library/Logs/DiagnosticReports`) can be attached. Pointers welcome on
what `prepare_callable_method_entry` dereferences as NULL under
`RUBY_BOX` — the C backtrace puts the fault in
`rb_vm_search_method_slowpath` → `callable_method_entry_or_negative` →
`prepare_callable_method_entry`.
