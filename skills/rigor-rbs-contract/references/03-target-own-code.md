# 03 — Target: the project's own code

A gem's shipped `sig/`, an application's `sig/`, or rbs-inline annotations (`#:`, `# @rbs`) in either.
The project's owner is the authority on every contract this code makes, so this target is
**interactive**: Rigor and the documentation narrow the questions, and the owner answers the ones they
leave open.

## Setup

The project's Rigor configuration already analyses its source with its `sig/` on the signature path, so
the commands in [`01-finding-candidates.md`](01-finding-candidates.md) run as they are:

```sh
rigor check --no-baseline --format=json lib            # Signal 1
rigor sig-gen --diff --format=json lib                 # Signal 2
rigor check --no-baseline --format=json spec           # Signal 3, or test/, or the application's callers
```

If `rigor` is not configured yet, run `rigor-next-steps` first. Record the current `rigor check` result
(with the baseline, as the project normally runs it) before changing anything; the gate below compares
against it.

## Ask, in one batch

After triage, sort what is left into three groups:

1. **Settled by evidence** — a `def.return-type-mismatch`, a `sig-gen` proposal over `untyped`, a
   documented value. Apply these, with their citations.
2. **Settled as "leave it"** — a `void` over a value nobody documented, a wide nominal, a proposal that
   is an inference gap. Do not ask about these one by one; list them.
3. **Open contract questions** — everything that needs the owner. Ask them together, each with the
   evidence and the concrete options:

> `Client#push` is declared `-> String`. Its body returns `nil` when a middleware halts the job
> (`lib/client.rb:88`, `return nil unless item`), and `rigor check` cannot see that early return.
> Should callers be told to expect `nil`?
> (a) `-> String?` — callers must handle a halted job; (b) keep `-> String` and raise instead of
> returning `nil`; (c) `-> void` — callers should not use the value.

Never ask an open question as "what type is this?". The owner should choose a contract, not reverse-
engineer one.

## Write the answer where it can be cited

An answer that lives only in the conversation is lost to the next contributor and to anyone writing RBS
for this library elsewhere. Offer to record each answered contract as a doc comment in prose — "Returns
the job id, or nil when a middleware stops the job." — next to the method. The declaration then has a
documented source, which is what makes it checkable later.

If the project keeps types out of doc comments, prose describing behaviour is still fine; a bracketed
YARD type is not, and `rigor-type-oracle` covers why.

## The gate

1. `rigor check` on the project, run as the project normally runs it, gains no new diagnostic. A new one
   means a caller relied on the old contract: show it to the owner. It is either a bug the new contract
   exposed, or a sign the contract change is wrong.
2. If the project ships its RBS (a gem's `sig/`), it still loads: `rbs -I sig validate`, or the
   project's own RBS task.
3. If the project also runs Steep or another RBS consumer, run it. Rigor is not the only reader of these
   files.
4. Where you widened a return, a witness shows the case is real (see `01-finding-candidates.md`
   § "Signal 6") and a test or a use site now handles it; where you widened a parameter, a test now
   passes the newly accepted argument. The owner may accept a change without a witness — say so in the
   write-up — but a Rigor finding alone is never presented as proof.
5. If the project has a test suite, use it as the command for the declaration-mutation pass
   ([`05-declaration-mutants.md`](05-declaration-mutants.md)): it runs the suite under `rbs/test/setup`
   once per broken declaration. A killed mutant is a declaration the suite checks against real values,
   which no static signal does; a survivor is one it does not check, however green the suite is. Report
   the survivors to the owner.
6. For a gem with no RBS yet, the skeleton and new-method rules in `04-target-gem-rbs-collection.md`
   § "New declaration set" apply to its `sig/` as well; ship it with the gem rather than through the
   collection.

## When the wrong signature belongs to a dependency

If a diagnostic in the project traces to a dependency's community RBS, the fix belongs upstream:
follow [`04-target-gem-rbs-collection.md`](04-target-gem-rbs-collection.md) for that gem. Until the fix
is released, a local corrected copy can stand in:

- in `rbs_collection.yaml`, set that gem to `ignore: true`, then run `rbs collection install` again so
  `rbs_collection.lock.yaml` drops it (the old directory under `.gem_rbs_collection/` stays, but only
  gems listed in the lockfile load) — otherwise the collection copy still loads next to yours and the duplicate declarations fail to build, which reads as a quieter run, not a
  fixed one;
- copy its RBS into a project directory on `signature_paths`, apply the fix, and note the upstream pull
  request next to it;
- remove the copy and the `ignore:` once the fix is in a collection release you have installed.

Do not patch the installed collection under `.gem_rbs_collection/`; the next `rbs collection install`
overwrites it.
