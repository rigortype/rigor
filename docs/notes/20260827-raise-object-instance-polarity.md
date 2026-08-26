# `call.raise-non-exception` — why an `Object`-typed instance stays silent (#420)

Status: adjudication, no behaviour change. Taken on master `35ac976b`.

[#420](https://github.com/rigortype/rigor/issues/420) asked whether the rule's singleton / instance
asymmetry is a real bound or a vestigial exclusion:

```ruby
raise Object       # => call.raise-non-exception
raise Object.new   # => silent
```

Both raise `TypeError` at run time, so the silence looks like a missed diagnostic. It is not. The
answer, and the evidence for it, is below; the pin in
`spec/rigor/analysis/check_rules/raise_non_exception_spec.rb` now carries the short form so the next
differential run finds it rather than re-filing this.

## The rule never sees the expression, it sees the carrier

`raise Object.new` really is a `TypeError`. But `raise_instance_operand_verdict` is handed a type, not
a syntax node, and that type is shared with values that are **not** exact:

| expression | carrier |
| --- | --- |
| `Object.new` | `Object` |
| a method declared `# @rbs () -> Object` | `Object` |
| `[Object.new, ArgumentError.new].first` | `Object` |

Measured with `dump_type` under a real `rigor check` run, not under `type-of` (which resolves a
different environment — see `feedback_rigor_probe_pitfalls`).

Every Ruby object is an `Object`, so a value carrying `Object` may be an `Exception` at run time.
There is no reading of this carrier under which `Object.new` fires and a declared `Object` stays
silent, because they are the same carrier.

## What convergence actually does

Two independent guards produce the silence, and each is sufficient on its own — removing one changes
nothing, which is worth knowing before concluding that either is vestigial:

1. `RAISE_UNEXACT_INSTANCE_CLASSES` lists `Object` / `BasicObject`, bailing before the ordering; and
2. the `:superclass` ordering falls through to `:unknown`.

With **both** removed, the rule fires on this, which is correct code that raises an `ArgumentError`:

```ruby
class Factory
  # @rbs () -> Object
  def build = ArgumentError.new("boom")
end

def go = raise Factory.new.build   # fires under convergence; silent today
```

AGENTS.md puts false-positive cost above the worst-case static reading, which settles it.

## The corpus could not decide this, and says so

The FP gate a widening normally needs was run anyway, over redmine, mastodon, mail and kramdown,
cold, against the fully converged rule:

| project | baseline firings | converged | new |
| --- | --- | --- | --- |
| redmine | 0 | 0 | 0 |
| mastodon | 2 | 2 | 0 |
| mail | 0 | 0 | 0 |
| kramdown | 0 | 0 | 0 |

**Zero new firings is an absence here, not a clearance.** The rule barely fires on this corpus at all,
and none of the four projects contains a `raise <Object-typed value>` site — so the run cannot
distinguish "the convergence is safe" from "the corpus has no instance of the shape". The deciding
evidence is the carrier measurement and the constructed case above, both of which are mechanisms
rather than absences.

## What stays as it is

The singleton path is not the same question and is unchanged: `raise Object` names one exact class
object, `Object.exception` does not exist, and no subtype can intervene between the constant and the
value. `raise Class` and `raise Comparable` fire for the same reason.

## Two fixture traps this cost

Both produced a confident wrong answer before the control caught them, and both are the same family:

- A first FP fixture used an untyped parameter (`def go(f) = raise f.build`), so the operand typed
  `Dynamic` and the example would have passed whatever the rule did.
- `[Object.new, ArgumentError.new].first` types as `Object`, but at run time it **is** an `Object`, so
  raising it is a genuine `TypeError` — it illustrates the carrier collapse, not a false positive, and
  pinning it as one would have been wrong.

Neither reached the spec file. The unit harness also cannot express an rbs-inline declared return —
the fixture types `Dynamic` there — which is why the demonstration above is a project fixture run
through the CLI and the spec carries the reasoning rather than a re-enactment.
