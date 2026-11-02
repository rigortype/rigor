# sig-gen --write repairs a bare generic header in every sig/ file, and reports a held-back one without failing --check

- **PR:** [#2655](https://github.com/rigortype/rigor/pull/2655)
- **Issue:** [#2603](https://github.com/rigortype/rigor/issues/2603)
- **Class:** open-choice
- **Precedent:** [#2602](https://github.com/rigortype/rigor/pull/2602)
- **Decided:** 2026-11-03

## Background

#2602 made `rigor sig-gen --write` insert the type parameters into a `sig/` header that opens a generic
class bare (`class Array`, as releases before #2436 wrote it), but only in files a candidate of the run
routes to. A file whose source is gone, or no longer reopens the class, kept its bare header, and rbs
keeps rejecting the class (`GenericParameterMismatchError`), `Object` included. #2603 left open whether
`--write` should repair every such header under the sig root or only report it. #2605 asked for a
held-back header to be reported, without saying whether `--check` should fail on it.

## Options and trade-offs

- **Repair every bare generic header under the sig root.** Fixes the env build with no user action. It
  rewrites a file the run had no other reason to open, but only by inserting the loaded declaration's
  plain parameters after the class name, under the same guards as #2602: the class must be generic with
  plain parameters only, a header with its own parameters is left alone, an unparseable or non-UTF-8 file
  is not read, and the result must parse before it is written. A bare header of a generic class can only
  fail the build, so the insertion cannot make a building env fail.
- **Only report it** (in `--check`, or as a `rigor check` diagnostic). Leaves no file untouched that the
  run did not route to, but leaves the build broken until a human does exactly the edit sig-gen would do.
- **Fail `--check` on a held-back header**, or only report it. `--write` cannot change a held-back
  header (the body names `E`, which the parameter would capture), so a failing `--check` would stay red
  until a human anchors the name; it was already breaking the env build before the run.

## Decision

Repair every bare generic header under the sig root, following #2602's repair and its guards; a file no
candidate routes to gets the repair alone, as a skipped candidate's file already did. "Under the sig root"
includes vendored or generated `.rbs` kept there (`sig/vendor/`, `sig/rbs_rails/`): those files are rewritten
too. The rule per class (#2605): every `signature_paths:` entry is read, and the class is repaired only when
every bare opening of it is under the sig root and none of their bodies names a parameter as a relative
constant; then every such opening is repaired, otherwise none is and the class is reported under `left_bare`. Gem, library and plugin RBS
(the bundled core, stdlib, `rbs collection` and plugin-contributed signatures) are not scanned: only the
project's `signature_paths:` entries are. A held-back class is reported (`generic header left bare`, JSON `left_bare`) but does not
fail `--check`: the gate stays defined by what `--write` would change, as it is for a tighter return
`--write` declines.

## To undo

Restrict `Writer#repair_only_results` to the targets candidates route to (the #2602 behaviour), and/or make
`dispatch_check` fail when `Writer#left_bare` is non-empty. Nothing else depends on either choice.
