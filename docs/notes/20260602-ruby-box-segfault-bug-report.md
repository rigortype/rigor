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

Minimal isolation is still pending (see "Notes"); the reliable
reproduction today is a large real workload:

1. `ruby 4.0.5`, arm64-darwin (macOS).
2. Run a non-trivial static-analysis program (the `rigor` type analyzer)
   over a medium Rails app (Redmine `app/`, ~200 files) with the box
   enabled:
   ```
   RUBY_BOX=1 bundle exec rigor check app
   ```
   No `Ruby::Box.new` sub-boxes are created on this path — only the
   process-wide `RUBY_BOX=1` flag is set; the crash is in ordinary
   (main-box) method dispatch.

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

- **`RUBY_BOX=1` is the trigger.** The same command without it exits 0.
- The crash is independent of `Ruby::Box.new` sub-boxes — it reproduces
  with only the process-wide flag set (no user boxes created).
- A trivial program (`RUBY_BOX=1 ruby small_check.rb`) does **not** crash;
  the fault needs a large method-dispatch-heavy workload.
- Plain deep recursion does **not** crash under the box —
  `RUBY_BOX=1 ruby -e "def f = f; f"` raises `SystemStackError` normally.
- `RUBY_BOX=1 ... require "rbs"` (and a `Ruby::Box.new` + `box.require`)
  load fine; the fault is in method resolution under load, not at
  require time.
- A self-contained minimal reproducer has not yet been isolated; the
  full crash report (with the macOS DiagnosticReports file) can be
  attached. Pointers welcome on what state `prepare_callable_method_entry`
  finds NULL under `RUBY_BOX`.
