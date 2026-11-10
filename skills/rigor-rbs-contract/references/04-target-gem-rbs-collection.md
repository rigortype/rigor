# 04 — Target: a gem_rbs_collection entry

RBS for a gem you do not own, in a checkout of
[`ruby/gem_rbs_collection`](https://github.com/ruby/gem_rbs_collection). The gem's documentation is the
authority, so this target can run without questions up to a finished branch and pull request
description. **Pushing the branch and opening the pull request are the user's call**: both are
outward-facing, even to a fork. Show them the local branch and the description, and push or open only
on their go-ahead, unless they already gave it for this change.

The collection's own guide is `docs/CONTRIBUTING.md` in the checkout; read it once. Two of its points
shape this workflow: focus on the API the README and documentation present, and write `_test/` code that
checks RBS against *application* code, not against the gem's implementation.

## Setup

Paths below use `gems/NAME/X.Y` for the entry and `$GEM_DIR` for the installed gem.

1. In the checkout: `bin/setup`.
2. Fetch the source of the version the entry describes. Unpacking reads it without building native
   extensions or running anything:

   ```sh
   COLLECTION=$PWD
   SRC=$(mktemp -d)
   (cd "$SRC" && gem fetch NAME -v '~> X.Y.0' && gem unpack NAME-*.gem)
   GEM_DIR=$(ls -d "$SRC"/NAME-*/ | head -n 1)
   ```

   If the gem is already installed, `ruby -e 'puts Gem::Specification.find_by_name("NAME", "~> X.Y.0").gem_dir'`
   gives the same directory.

3. Run the entry's tests once before changing anything, so you know they were green:

   ```sh
   bin/test gems/NAME/X.Y
   ```

   This also leaves an `rbs_collection.lock.yaml` in `_test/`, which puts the entry's dependency RBS in
   reach for the use-site check below.

## Signals 1 and 2 — the declarations against the gem's source

Work in a scratch directory outside the checkout, so nothing Rigor writes ends up in the diff, and copy
in only what is under review:

```sh
SCRATCH=$(mktemp -d)
mkdir -p "$SCRATCH/sig"
cp -R "$GEM_DIR/lib" "$SCRATCH/lib"
rsync -a --exclude _test --exclude .gem_rbs_collection "$COLLECTION/gems/NAME/X.Y/" "$SCRATCH/sig/"
printf 'paths: ["lib"]\nsignature_paths: ["sig"]\n' > "$SCRATCH/.rigor.yml"
cd "$SCRATCH"
rigor check --format=json lib
rigor sig-gen --diff --format=json lib
```

Excluding `_test/` matters: its `.rbs` files and any `.gem_rbs_collection/` left by an earlier
`bin/test` would load as duplicate declarations. A gem whose RBS depends on another gem's RBS will show
`rbs.coverage.*` warnings and undefined-method noise here; copy that dependency's entry into `sig/` too,
or read Signal 1 for the methods whose types do not touch the dependency.

## Signal 3 — the entry's `_test/` code

```sh
cd "$COLLECTION/gems/NAME/X.Y/_test"
printf 'paths: ["."]\nsignature_paths: ["."]\n' > .rigor.yml    # with rbs_collection.lock.yaml present
rigor check --no-cache --format=json
```

Without an `rbs_collection.lock.yaml`, use `signature_paths: [".."]` instead, and expect missing
dependency RBS. `--no-cache` keeps a `.rigor/` cache directory out of the entry. Keep `.rigor.yml` out of
the commit by listing it in `.git/info/exclude`, and check `git status` before committing: nothing under
`_test/` but your test files belongs in the diff.

## Signal 5 — the gem's documentation

Read the doc comments in `$GEM_DIR/lib`, the README, and the published API reference for the version.
Quote what you rely on in the write-up.

## Writing the change

- Edit `gems/NAME/X.Y/*.rbs`. Keep types inside the gem's namespace; no new top-level aliases or
  interfaces.
- A new standard-library or gem dependency in the RBS, or in the test, goes into `manifest.yaml`
  (marcel's test needed `tempfile`).
- Apply the same contract to every version directory whose code and documentation agree, and only to
  those.

## The gate

1. Add or extend a test under `_test/` that exercises the contract you changed, as application code
   would: `&.` or an `if` on a newly nilable return, calls to newly declared methods, the newly accepted
   argument shapes. A new file pair `test_N.rb` / `test_N.rbs` is fine when the existing test does not
   fit.
2. `bin/test gems/NAME/X.Y` passes for every version you touched. It runs `rbs validate`, `steep check`
   and the untyped-call check.
3. `rigor check` on `_test/` reports nothing new compared with before the change.

## The pull request

Branch from the collection's default branch and keep one gem, one concern per pull request. Title it
`NAME: <what the contract now says>` — for example `sidekiq: Client#push and client_push return
String?`. The body follows the shape reviewers have accepted:

```markdown
## Summary

What was wrong with the contract and why, with the quote that settles it.

Changed in `gems/NAME/X.Y`:

- `Klass#meth` now returns `String?`. <the evidence, one line>

Deliberately left unchanged:

- `Klass#other` stays `void`. Its implementation returns the same value, but NAME does not document a return value for it.

## How this was found

The signal that surfaced it — the Rigor command and the finding, or the documentation sweep.

## Verification

The test added, and the `bin/test gems/NAME/X.Y` result for each version.
```

Write each paragraph and list item on one line; GitHub renders a newline inside a paragraph as a line
break. "Deliberately left unchanged" is not optional when a `void`, `boolish` or wide declaration was
kept over a body that returns more: it is the evidence that the restraint was a decision.
