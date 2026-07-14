# Reference 05 — JIT and run speed (YJIT / ZJIT)

Operational, not part of onboarding proper: how Rigor uses a Ruby JIT to
speed up analysis, how to tell whether it is active in your install, and the
trade-off (and break-even point) if you want to override the default. Read
this when a project is large enough that `rigor check` wall time matters —
Rails monorepos especially. On a small project you can ignore it entirely:
Rigor already does the right thing with no configuration.

## TL;DR

- **You usually do nothing.** Rigor enables YJIT automatically once a run has
  been going long enough to be worth it, and leaves it off for short runs
  where it would only add warm-up cost. This is on by default.
- **Break-even is ~5 seconds.** A JIT pays for its warm-up only on longer
  runs; below it, JIT-on is *slower*. Rigor's 5-second deadline is set at
  that crossover.
- **YJIT, not ZJIT.** Ruby 4.0 ships both JITs, but YJIT is faster for Rigor's
  workload — measurably so on every run large enough for a JIT to help. Rigor
  uses YJIT; there is no reason to force ZJIT.

## How Rigor uses a JIT

`rigor check` and `rigor coverage` arm a background timer at the start of a
run. If the run is still going after ~5 seconds, YJIT is switched on for the
remainder; a run that finishes first never pays any JIT cost. So:

- A quick check (a small project, or a warm cache hit) runs on the plain
  interpreter — no warm-up penalty.
- A long cold analysis of a large project gets YJIT for its dominant tail,
  where the speed-up more than repays the warm-up.

Diagnostics and their counts are identical whether or not the JIT engages —
a JIT changes wall time only, never results.

The long-running servers `rigor lsp` and `rigor mcp` turn YJIT on at start
instead, since they always run long.

## Is a JIT available in my install?

The deferred-YJIT feature only helps if the Ruby your `rigor` runs on was
built with YJIT support. Rigor is installed standalone (see
[Installing Rigor](../../../docs/manual/01-installation.md)), so this is a
property of *that* Ruby, which may differ from your project's Ruby.

Check the Ruby that runs `rigor`:

```sh
ruby --yjit -e 'require "rbconfig"; puts "YJIT: #{RbConfig::CONFIG["YJIT_SUPPORT"]}"; puts "ZJIT: #{RbConfig::CONFIG["ZJIT_SUPPORT"]}"'
# YJIT: yes   → the deferred-YJIT engages automatically on long runs
# YJIT: no    → the feature is a silent no-op; runs use the interpreter
```

- Most prebuilt CRuby 3.3+ (mise / rbenv / asdf, the recommended install
  channels) ship with YJIT built in.
- The Nix flake package of Rigor bundles a Ruby with **both** YJIT and ZJIT.
- A YJIT-less Ruby is not an error — Rigor just runs interpreted, correctly.

## Overriding the default

Three environment variables, documented in the
[CLI reference § Environment variables](../../../docs/manual/02-cli-reference.md#environment-variables):

| Want | Do |
| --- | --- |
| Force YJIT on for the **whole** run (including the first 5 s) | `RUBYOPT="--yjit" rigor check …` |
| Turn Rigor's JIT off entirely | `RIGOR_DISABLE_YJIT=1 rigor check …` |
| Change the deadline (advanced) | `RIGOR_YJIT_DEADLINE=<seconds> rigor check …` |

When would you override?

- **Force-on** helps only if *every* run you care about is long (a big
  monorepo in CI where even the fast path is > 5 s). On mixed workloads the
  default deadline is better — it protects your quick local re-checks.
- **Off** is the escape hatch if a JIT ever misbehaves on your platform, or to
  get a clean interpreter baseline when measuring.

## Why the ~5-second break-even (the trade-off)

A JIT compiles hot code to machine code, which costs time up front and repays
it over the rest of the run. On a short run the compilation never amortizes,
so JIT-on loses. Measured cold `rigor check`, by project size:

| run size | interpreter | YJIT | effect |
| --- | --- | --- | --- |
| ~1.6 s (small lib) | baseline | **+67 %** | JIT-on loses badly |
| ~4 s (medium lib) | baseline | ~break-even | a wash |
| ~8 s | baseline | **−13 %** | JIT-on wins |
| ~19 s (Rails monorepo) | baseline | **−20 %** | wins more |
| ~17 s (large Rails app) | baseline | **−28 %** | biggest win |

The deadline parks the enable point just past the loss zone: runs that finish
before ~5 s never pay warm-up; longer runs collect the win on their tail.

## YJIT vs ZJIT (Ruby 4.0)

Ruby 4.0 ships a second JIT, **ZJIT** (a newer method-based JIT;
[upstream docs](https://docs.ruby-lang.org/en/master/jit/zjit_md.html)). It
is real and correctness-safe on Rigor (identical diagnostics), but **slower
than YJIT for Rigor's workload** at Ruby 4.0. Measured cold, on the runs where
a JIT helps at all:

| target | YJIT vs interpreter | ZJIT vs interpreter | ZJIT vs YJIT |
| --- | --- | --- | --- |
| ~8 s | −13 % | −4 % | +10 % |
| ~19 s (monorepo) | −20 % | −13 % | +10 % |
| ~17 s (large app) | −28 % | −14 % | +21 % |

YJIT wins on every workload large enough to warrant a JIT; ZJIT's peak
speed-up is roughly half. ZJIT only edges YJIT on tiny runs — the zone where
you want no JIT at all. **Do not force ZJIT** (`RUBYOPT="--zjit"`) for Rigor;
the automatic YJIT is faster. Full measurement + methodology:
[`docs/notes/20260714-jit-evaluation-yjit-zjit-ruby40.md`](../../../docs/notes/20260714-jit-evaluation-yjit-zjit-ruby40.md).

This verdict is Ruby-4.0-specific; ZJIT is younger than YJIT and improving, so
it may close the gap in a later Ruby. Until then YJIT is the right default —
which is what Rigor already does.
