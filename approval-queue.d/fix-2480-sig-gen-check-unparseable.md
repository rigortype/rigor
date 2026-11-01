# sig-gen --write and --check exit 1 when an existing sig/ target does not parse

- **PR:** [#2587](https://github.com/rigortype/rigor/pull/2587)
- **Issue:** [#2480](https://github.com/rigortype/rigor/issues/2480)
- **Class:** open-choice
- **Precedent:** [#231](https://github.com/rigortype/rigor/pull/231)
- **Decided:** 2026-11-01

## Background

#2480 reports that `sig-gen --check` printed "sig/ is up to date" and exited 0 while an existing target
`.rbs` in `sig/` did not parse. The writer returned `:noop` for such a target, while a target that is not valid
UTF-8 was already refused with exit 1. The issue asks for the unparseable case to be refused as well, and says
`--check` should then fail and name the file.

The issue did not say what exit status the refusal should carry. A `rigor check` run already reports an
unparseable `.rbs` as the `rbs.coverage.quarantined-signature` warning. The choice was between a warning and a refusal with exit 1.

## Options and trade-offs

- **Refuse with exit 1, as for invalid encoding (taken).** `--check` fails and `--write` exits 1 without touching
  the file. The cost: a bundled-rbs bump that makes a previously parsing file stop parsing turns `--write` and
  `--check` red with no change in the user's project. The benefit: `--check` no longer passes over a `sig/`
  that no consumer can read, which is what #2480 reports.
- **Warn only, as `rigor check` does.** Keeps `--check` green on an unparseable file. The cost is the bug in
  #2480 unchanged: the CI gate passes over a `sig/` that does not load. Rejected because the gate exists to
  catch exactly that.
- **Refuse, but exit 0 on `--check` and 1 only on `--write`.** Avoids the red-CI risk on a bump. It splits the
  two commands' contract and leaves `--check` silent on the defect. Rejected for the same reason as warn-only.

## Decision

Take the first option: refuse with exit 1 under `--write` and `--check`, naming the file, and leave the file
untouched. The precedent is the invalid-UTF-8 refusal in #231, which also refuses and exits 1 on an existing
target sig-gen cannot read faithfully. The fit is close on the exit status and on the refusal, but not on the
trade-off: an encoding fault does not come and go with a bundled-rbs release, and a parse fault can. The
maintainer should weigh that difference. `docs/type-specification/diagnostic-policy.md` keeps
`rbs.coverage.quarantined-signature` a warning, so a bundled-rbs bump cannot turn a check red by itself; this
exit code has no such protection.

## To undo

Reverting restores the `:noop` for an unparseable target and the exit 0 under `--check`. Nothing else depends on
the new action yet: `skipped_unparseable` is new in this PR, and its JSON key shape matches
`skipped_invalid_encoding`. Revisit if users report that a bundled-rbs bump turned `--check` red without a change
in their project. The likely response is to keep the refusal and make the check diagnostic a warning, not to
revert the refusal.
