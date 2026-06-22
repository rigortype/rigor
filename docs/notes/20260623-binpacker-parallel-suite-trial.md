# binpacker parallel suite — CI trial results (2026-06-23)

## Context

PR #26 integrated [binpacker](https://rubygems.org/gems/binpacker) as a
candidate replacement for `parallel_tests` in the rigor spec suite.
The trial runs both runners side-by-side in CI: `test` (parallel_tests,
`required`) and `test-binpacker` (binpacker, non-required).  This note
records the first two full CI runs on master after merge.

Reference runs: `27972316861` (pre-merge) and `27973217998` (post-merge).

---

## Results summary

| Runner | Examples | Failures | Makespan (CI, 4 workers) |
|---|---|---|---|
| parallel_tests (`make test-parallel`) | 7019 | 0 | 5:17 |
| binpacker (`make test-binpacker`) | 7019 | 0 | 14:10 |

Correctness: identical — both runners produce 7019 examples, 0 failures.

---

## Performance gap: root cause

binpacker's workers ran **sequentially**, not in parallel.
Individual worker durations (from CI log):

```
W0: 3:50  (1648 examples, 2 pending)
W1: 3:29  (1576 examples)
W2: 3:20  (1728 examples)
W3: 3:22  (2067 examples)
```

If truly parallel the makespan should be max(3:50, 3:29, 3:20, 3:22) ≈ **3:51**.
Actual was **14:10** — sum of all worker durations — i.e. pure serial.

### Why

`Orchestrator#run` calls `worker.finish` in a sequential loop:

```ruby
workers.each do |worker|
  worker.finish          # ← sends "done", then blocks reading stdout
  all_timings.concat(worker.timings)
  …
end
```

`Worker#finish` sends the `{"type":"done"}` signal and closes stdin,
then blocks reading the worker's stdout until EOF.  Workers only start
running RSpec *after* they receive "done" on stdin.  Because `finish`
is called one worker at a time, each worker receives its "done" only
when the *previous* worker has already finished — collapsing 4-way
parallelism into a serial chain.

### Fix needed in binpacker

Split "signal done to all workers" from "collect all results":

```ruby
# 1. Signal all workers to start
workers.each { |w| w.signal_done }   # send {"type":"done"} + close stdin

# 2. Collect results (workers now run in parallel)
workers.each do |worker|
  worker.collect_results
  …
end
```

Or equivalently: move the `{"type":"done"}` send out of `finish` and
into `send_tests` (as the final message after the file list), so
workers start RSpec as soon as the file list is complete without waiting
for the orchestrator to loop back to them.

---

## Incidental findings during integration

### UTF-8 encoding (fixed in 0.0.3)

Running under the Nix Flake (US-ASCII default locale) exposed two
encoding bugs in binpacker ≤ 0.0.2:

- `Worker#start` opened pipes without `encoding: "UTF-8"` → pipe I/O
  raised `Encoding::InvalidByteSequenceError` on RSpec output containing
  non-ASCII characters (e.g. `→` in test descriptions).
- `Timing#load_raw` / `#append_all` read/wrote the timings file in the
  default external encoding.
- `binpacker-worker`: `File.read(outfile.path)` read the RSpec JSON
  output in the default encoding.

All three fixed in binpacker 0.0.3.  The rigor gemspec lower bound was
raised to `>= 0.0.3`.

### `--out $stderr.fileno.to_s` artefact (fixed in 0.0.3)

`binpacker-worker` passed `$stderr.fileno.to_s` (= `"2"`) as the
`--out` argument to RSpec's progress formatter.  On macOS this creates a
file named `"2"` in the working directory instead of writing to fd 2.
Fixed in 0.0.3 by using `"/dev/stderr"` instead.

### Gemfile.lock platform (one-time fix)

`bundle lock --add-platform x86_64-linux` was required so that bundler's
deployment mode on the Linux CI runner does not reject the lockfile
generated on an arm64-darwin host.

### Rigor analysis-cache restore-keys scoped to Gemfile.lock

Adding binpacker to the lockfile changed the `gem-without-rbs` diagnostic
count (31 → 32 gems).  The warm self-check restored an old cache (via
the bare `rigor-cache-${{ runner.os }}-` restore-key prefix) that
pre-dated the lockfile change, causing the warm/cold diagnostic diff gate
to fail.

Fix: the restore-key now includes the Gemfile.lock hash as a mandatory
segment (`rigor-cache-${{ runner.os }}-${{ hashFiles('Gemfile.lock') }}-`)
so a lockfile change forces both warm and cold to run cold, producing
identical output.

---

## Next steps

1. **Fix the sequential-worker bug in binpacker** (signal all workers
   before collecting any results).  After the fix the expected CI
   makespan is ~4 min, comparable to or faster than parallel_tests.
2. Once the fix ships and CI confirms the speedup, promote
   `test-binpacker` to the `required` fan-in and retire `test` /
   `make test-parallel`.
