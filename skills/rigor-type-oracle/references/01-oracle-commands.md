# 01 — The oracle commands, exactly

Every command form here was taken from `rigor <cmd> --help` on the
version this file ships with. If a flag below is missing from your
`--help`, trust `--help`.

All five commands are **read-only**: they analyse and print. None of them
writes to your source tree. (`rigor sig-gen --write` does, and is the one
form this skill never reaches for on its own — see § "Writing, not just
reading".)

## `rigor type-of` — the type of one expression

```sh
rigor type-of FILE:LINE[:COL] [FILE:LINE[:COL] ...]
```

| Option | Effect |
| --- | --- |
| `--format=text\|json` | `text` (default) or a JSON object per position. |
| `--trace` | Also record fail-soft fallbacks via the tracer. |
| `--config=PATH` | Explicit `.rigor.yml`. |
| `--tmp-file=PATH` / `--instead-of=PATH` | Editor mode: analyse an unsaved buffer as if it were the project path. Paired. |

**Position syntax.** `FILE:LINE:COL`, both **1-based**. The column may be
omitted (`FILE:LINE`). Several positions in one invocation — that is the
cheap way to ask about a whole method.

Text output:

```
lib/demo/budget_ledger.rb:19:7
node:    Prism::LocalVariableWriteNode
type:    Array[Dynamic[top]]
erased:  Array[untyped]
```

- `node` — the Prism node the position resolved to. Check it: if it is
  not the expression you meant, your column is off, and the `type` below
  it answers a different question.
- `type` — Rigor's internal type. **This is the answer.**
- `erased` — the same type spelled as RBS. **This is what you write into
  a `.rbs` file or an annotation.** `Dynamic[top]` erases to `untyped`.

JSON output is the same five fields:

```json
{ "file": "…", "line": 19, "column": 7,
  "node": "Prism::LocalVariableWriteNode",
  "type": "Array[Dynamic[top]]", "erased": "Array[untyped]" }
```

## `rigor annotate` — every line of a file at once

```sh
rigor annotate FILE
```

| Option | Effect |
| --- | --- |
| `--format=text\|json` | `text` (default), or JSON as a `{ line => type }` map. |
| `--[no-]color` | Force / disable ANSI colour (auto-detects a tty; honours `NO_COLOR`). |
| `--[no-]bat` | Force / disable highlighting through `bat`. |
| `--config=PATH` | Explicit `.rigor.yml`. |

Output is the source with each line's **last-expression type** appended
after `#=>`:

```ruby
    def initialize(currency, opening_balance: 0)   #=> Dynamic[top]
      @currency = currency                         #=> Dynamic[top]
      @entries = []                                #=> []
    end                                            #=> :initialize
```

Two reading rules that catch people out:

- `#=>` is the type of the line's **last expression**, not of the
  variable being assigned and not of the method being defined. A `def`
  line's `#=>` is the *return* type of the method; the `end` line's
  `#=>` is the symbol the `def` expression itself evaluates to
  (`:initialize`) — that is Ruby, not a Rigor quirk. Ignore it.
- One `#=>` per line. For a multi-expression line, or for a
  sub-expression in the middle, go back to `type-of` with a column.

Reach for `annotate` first when the task is "document this file" or "add
types to this class": one call types everything, and the lines that come
back `Dynamic[top]` are your gap list before you have written a word.

## `rigor sig-gen` — the signature of a method

```sh
rigor sig-gen [paths]
```

| Option | Effect |
| --- | --- |
| `--print` | RBS to stdout. **Default** — you may omit it. |
| `--diff` | Unified diff against the existing RBS. Read-only. |
| `--write` | Write to `sig/<path>.rbs`. The only mode that touches the filesystem. |
| `--overwrite` | Allow a tighter return to replace user-authored RBS. |
| `--include-private` | Emit private / protected instance methods too (default: public only). |
| `--params=untyped\|observed\|observed-strict` | Parameter policy. Default `untyped`. `observed-strict` is reserved and currently a usage error. |
| `--observe=PATH` | Directory / file to scan for call-site observations. Repeatable. Defaults to `spec/` when present. |
| `--new-files` / `--new-methods` / `--tighter-returns` | Emit only that classification. |
| `--format=text\|json` | Text RBS, or the structured candidate report. |
| `--config=PATH` | Explicit `.rigor.yml`. |

Text output is RBS you paste as-is:

```
class Demo::BudgetLedger
  # [new]
  def record: (untyped, ?memo: untyped, ?at: untyped) -> Demo::BudgetLedger
  # [new]
  def entries_matching: (untyped) -> (Array[untyped] | [])
end
```

**Read stderr.** A skip summary goes there, not to stdout:

```
rigor sig-gen: skipped 2 method(s) it could not type or would not overwrite
(sig.skipped.untyped-return: 2). Run with --format=json to see each one with
its skip_reason.
```

A method that is missing from the printed RBS was **skipped**, and a
skip is a finding. `--format=json` names each one:

```json
{ "class": "Demo::BudgetLedger", "method": "balance", "kind": "instance",
  "classification": "skipped", "skip_reason": "sig.skipped.untyped-return" }
```

Classifications: `new-file`, `new-method`, `tighter-return`, `equivalent`
(nothing to tighten; silently dropped), `skipped`. Skip reasons and what
each one means for you: [`03-gap-protocol.md`](03-gap-protocol.md).

### Deriving a parameter type from call sites

```sh
rigor sig-gen --print --params=observed --observe spec lib/demo/budget_ledger.rb
```

`observed` collects argument types from every call site under the
`--observe` paths, unions them per parameter position, and emits the
union. The recogniser understands RSpec shapes — `RSpec.describe Foo`,
bare `describe Foo`, `subject { … }` / `subject(:name) { … }`,
`let(:name)` / `let!(:name)`, and `described_class.new(...)` — so a
normal spec suite is already an observation corpus. No plugin needed.

The result is *evidence*, and it is narrow evidence:

```
def initialize: ("JPY", ?opening_balance: 100) -> void
def entries_matching: (Regexp) -> (Array[untyped] | [])
```

`(Regexp)` is a real derivation and adoptable. `("JPY")` and `100` are
literal types — the union of what today's callers happen to pass, frozen
as a contract. Widen those to the class before adopting
(`String`, `Integer`), per [ADR-5](https://github.com/rigortype/rigor/blob/master/docs/adr/5-robustness-principle.md):
lenient on parameters. The gate on any widening is that `rigor check`
gains no new diagnostic.

### Writing, not just reading

This skill's job ends at *knowing* the type. `--write` is an edit to the
project and belongs to whoever asked for it — propose `--diff` first, and
run `rigor check` after. `--write` only ever writes inside the configured
signature paths (`sig/` by default).

## `rigor trace` — why the type is what it is

```sh
rigor trace FILE
```

| Option | Effect |
| --- | --- |
| `--format=text\|json` | `text` is an interactive animation; **use `json`** for the raw event stream. |
| `--line=N` | Only replay events whose source range starts on line `N`. |
| `--verbose` | Include every expression enter/result frame. |
| `--delay=SECONDS` | Autoplay the text animation (default: step on key press). |
| `--config=PATH` | Explicit `.rigor.yml`. |

An agent wants `--format=json --line=N`: the text mode waits on
keystrokes. Each event carries `kind`, `depth`, a `location`, the node
`stack`, and a `data` payload — a `bind` event, for example, names the
local and the type it received:

```json
{ "kind": "bind", "depth": 2,
  "location": { "start_line": 20, "start_column": 25, "…": "…" },
  "stack": ["CallNode", "CallNode"],
  "data": { "name": "amount", "type": "Dynamic[top]" } }
```

Reach for it when `type-of` gave you `Dynamic[top]` and you need to name
*where* the precision was lost before reporting the gap.

## `rigor explain` — what a diagnostic rule means

```sh
rigor explain [<rule>]
```

| Option | Effect |
| --- | --- |
| `--format=text\|json` | Default `text`. |

With no argument it lists every rule. With a rule id, a legacy alias, or
a family prefix (`call`, `flow`, `assert`, `dump`, `def`) it prints the
rule's firing conditions, the severity per profile, the evidence tier,
and how to suppress it.

**`explain` covers diagnostic rules only.** A `sig.skipped.*` id is a
sig-gen *skip reason*, not a diagnostic rule — `rigor explain
sig.skipped.untyped-return` answers `Unknown rule`. Skip reasons are
documented in [`03-gap-protocol.md`](03-gap-protocol.md).

## `rigor check` — the gate, not the oracle

```sh
rigor check [paths]
```

You need one flag family here: `--format=text|json|sarif|github|gitlab|checkstyle|junit|teamcity`,
plus `--explain` to surface fail-soft fallback events as `:info`
diagnostics. Everything else (`--baseline*`, `--workers`, `--incremental`,
the cache flags) belongs to other skills.

`check` never *sources* a type. Its role here is the verification half:
after any annotation lands, `rigor check PATHS` must gain **no new
diagnostic** versus before. Green is a non-contradiction proof, not a
correctness proof — say which lines it actually covers.

## The MCP tools

With the Rigor MCP server wired up (`rigor-mcp-setup`), the same oracle
is available as tool calls. Prefer them over shelling out; the results
are the CLI's, so read them exactly as above.

| Tool | Required arguments | Optional | Returns |
| --- | --- | --- | --- |
| `rigor_type_of` | `file` (string), `line` (integer, 1-based), `col` (integer, 1-based) | `config` | The inferred type at that location. |
| `rigor_annotate` | `file` (string) | `config` | The source with each line's last-expression type appended. |
| `rigor_sig_gen` | — (defaults to the configured paths) | `paths` (array of strings), `params` (`"untyped"` \| `"observed"`), `config` | The JSON candidate report — classifications, `rbs`, `inferred_return`, `skip_reason`. |
| `rigor_check` | `paths` (array of strings) | `config` | The JSON diagnostic report. |
| `rigor_explain` | — (omit `rule` to list every rule) | `rule` (string) | The rule catalogue entry, as JSON. |

Two shape differences from the CLI worth knowing:

- `rigor_sig_gen` returns the **JSON candidate report**, always — there
  is no `--print` text mode and no `--diff`. Read `rbs` per candidate.
- `rigor_sig_gen` exposes `params` but **not** `observe`; observation
  falls back to `spec/` when present. Point it elsewhere from the CLI.

`rigor_triage` and `rigor_coverage` are also served, and belong to
`rigor-baseline-reduce` / `rigor-protection-uplift` rather than here.
