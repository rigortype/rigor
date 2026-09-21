# v0.4.0 pre-clear batch: what the four lanes actually hit

Status: process note from the 2026-09-21 `/queue-release` batch; no design commitments. Taken against worktrees based on `237e76dd`, Ruby 4.0.5. The four Draft PRs had not landed when this was written.

The implementers wrote the four sections below after the lanes finished. Shared process facts sit here so the next batch does not re-learn them from CI timeouts.

| Issue | Draft PR | Head SHA | Review (Grok-max) |
| --- | --- | --- | --- |
| [#1011](https://github.com/rigortype/rigor/issues/1011) | [#1158](https://github.com/rigortype/rigor/pull/1158) | `c922003c3c2a111cad4401c3330a63c824ce04c7` | Approved. CI red was shard-1 artifact upload 403, not a test failure. |
| [#1130](https://github.com/rigortype/rigor/issues/1130) | [#1159](https://github.com/rigortype/rigor/pull/1159) | `4dc1b7badb53892b5a0e2a3047a09bbd04a57b25` | Approved. CI green. |
| [#1071](https://github.com/rigortype/rigor/issues/1071) | [#1160](https://github.com/rigortype/rigor/pull/1160) | `4ffd97017a5e1d666d291e50501b8de81aa033c9` | Approved. P2: `plugin.md` / `effect-summaries.md` still say one html edge per unit. |
| [#1089](https://github.com/rigortype/rigor/issues/1089) | [#1161](https://github.com/rigortype/rigor/pull/1161) | `f8dc257e25a733a9e2263b86f308cf407e143da6` | Approved. |

## Shared traps (all four lanes)

- `deepseek/deepseek-flash` is not in this session's model registry. The first fan-out died in one second. Pin `opencode-go/deepseek-v4-flash` (or the current Flash id from `subagent({ action: "models" })`) on `rigor-lane`.
- A 30-minute child timeout is enough for the code and not enough for mastodon+redmine `check` twice. #1071 and #1089 both died in the corpus arm. Resume without re-measuring; put counts in the PR body.
- `gh issue create` / `gh pr create` with backticks in a shell heredoc runs command substitution. Write the body to a file and pass `--body-file`.
- A managed worktree has no vendored bundle. Point an untracked `.bundle/config` `BUNDLE_PATH` at the main checkout's `vendor/bundle`, or `bundle install` in the worktree, before the first Ruby process.
- Push a change-named branch (`sig-gen-gap-markers-1011`), not the `pi-subagents/` worktree name. Create the local branch before the first push.
- Write the changelog fragment after the PR number exists. The fragment gate wants the PR link.

## #1011 — what we actually did

The ruling on #1011 was not in any repo file. It was a comment on the issue itself, posted 2026-09-19 by the maintainer, and I only found it after the LaneInput's "known causes" did not match the live tree. I read it with `gh issue view 1011 --comments`. It kept the gate rule, declared the markers wrong, and enumerated eight engine causes with their rows.

The worktree had 25 marker rows across 8 `sig/` files citing 12 issue numbers, 8 of them closed feature issues. Before touching anything I ran the actual classifier (`SigProvenanceAuditor.audit` with `runtime: true`) to learn what each row is rather than trusting its comment. Only two rows are `tighter_return`: `plugin/base.rbs` `dynamic_return_type` citing #1007 and `rigor.rbs` `return_summaries` citing #1008, both genuinely open gap issues. The other 21 marked rows are `unrenderable`, `declared_divergent`, or `synthetic_source`, which changed how I reasoned about the change: the hard rule pins only the two, and the residue ratchet is what the unrenderable rows hit.

I filed 10 new gap issues, one per real engine cause: #1148 endless-def reader, #1149 `||` fallback, #1150 `Data.define` members, #1151 frozen-Set attr_reader, #1152 `Set#include?` over a tuple key, #1153 `Array[untyped] | []` early return, #1154 attr_reader from an initialize parameter, #1155 memoized `||=` reader, #1156 seed literal pinning a later record, #1157 block-taking name resolver. I kept #160, #1007, #1008 where they already tracked the gap. Then I repointed all 23 gap markers, converted the two hook-contract widenings in `plugin/base.rbs` to a new `# authored:` marker, committed `spec/rigor/sig_gen/gap_issues.yml`, loaded it in `provenance_spec.rb` with `YAML.safe_load_file`, and added a corpus example that fails on any marker citing an unlisted number, plus an authored-marker fixture. The auditor gained `Declaration.authored_reason` and a `Row#marked?` that counts either marker, so the residue pins in `SIG_PROVENANCE_RESIDUE` did not move.

I committed on a new local branch named `sig-gen-gap-markers-1011`, pushed with an explicit refspec, opened Draft PR #1158 with `Fixes #1011` on its own line, and wrote the changelog fragment only after the PR number existed. Targeted checks: provenance spec 28 green, rbs validity plus alias rendering 24 green, docs-check 480 green, RuboCop on the two changed Ruby files clean, `git diff --check` clean.

### Wrong turns

My first mistake was treating the LaneInput's known-causes list as exhaustive. Five marker rows sit outside the ruling's row list, and "repoint every marker" forced decisions on them. I extended instead of escalating: `scope.rbs:24` merged into #1154, `base.rbs:51` became authored, `type.rbs` `yes/no/maybe` became #1155, `io_boundary.rbs` became #1156, `reflection.rbs` became #1157. That is the intended reading, but each was a judgment call a reviewer should confirm.

My second mistake was shell quoting. Creating #1149 with backticks in a `gh issue create` title let command substitution eat the backtick span, and the title lost its example phrase. I repaired it with `gh issue edit`, then wrote every later body to a file and passed `--body-file`.

A third detour was the environment. The worktree has no vendored bundle, and my first classifier run loaded a host `rbs` gem compiled against a different Ruby and died with a dyld LoadError. The flake only sets `BUNDLE_PATH`; the bundle lives in the main repo. I wrote an untracked `.bundle/config` with an absolute `BUNDLE_PATH` into the main repo's `vendor/bundle`, and everything ran.

Fourth, several edits failed on exact-text anchors because I misremembered indentation or kept a wrong leading word in the old text. The reliable fix was pulling the exact lines with a Python `repr` before retrying.

The fragile one worth flagging: converting the two hook rows to authored markers would have moved the `plugin/base.rbs` pin by two if the auditor did not count authored rows as marked. I made `Row#marked?` true for either marker before running the ratchet example, and it stayed green.

### What the next lane should not rediscover

Set up the bundle before running anything. `make setup` is not present in this worktree. Copy the pattern: `.bundle/config` with `BUNDLE_PATH` pointing at the main repo's `vendor/bundle`, kept untracked.

The allow-list yml is the reviewed artefact. A marker may cite only numbers in it. When any of #1148 through #1157 closes, remove the number from the list and the gate fails until the marker moves. Never cite #1011 itself; it tracks the convention, not an engine gap.

Do not move `SIG_PROVENANCE_RESIDUE` when adding or converting markers. Both marker forms subtract from the counts, and a moved pin masks a real engine fix, which the gate message treats separately.

Only two rows are `tighter_return`. The example that actually catches a stale cite is the new allow-list corpus example, not the tighter-return one. Run `provenance_spec.rb` after any sig marker edit; the ~15 second generator pass at file load is the real cost.

For issue filing, never put backticks in a `gh issue create` title passed through bash. Use `--body-file` and single-quoted titles.

The harness worktree branch was `pi-subagents/i1011-...`. The PR branch name had to be created locally before the push, or the PR would have carried a tool-prefixed name.

Residual risk: `docs/handbook/11-sig-gen.md` still names only the gap marker. Updating it for `# authored:` is a small follow-up that this lane's touch list excluded.

## #1130 — what we actually did

The bug was a one-word difference between two paths. `dispatch_one`'s return path typings of `Bases::Self` went through `SelfSubstitute.for` (issue #1092, PR #1096), so `ints.tap {}` returned `Array[Integer]`. `extract_block_param_types` built `self_type = Type::Combinator.nominal_of(class_name)` with no type arguments, so `Object#tap`'s `(self)` block parameter arrived as a raw `Array`. `ints.tap { |a| }` bound `a` to `Array`, and `[1, 2].tap { |a, b| }` fell onto the issue #1128 `Dynamic[top]` floor.

I threaded `receiver`, `receiver_args` and `method_name` from `probe_block_param_types_one` into `extract_block_param_types`, called `SelfSubstitute.for` as a keep-versus-degrade verdict only, and on a non-nil verdict set the block `self_type` to `nominal_of(class_name, type_args: receiver_args)`, preserving value-pinned constants. A nil verdict (an element-changing mutator) kept the raw nominal. `dispatch_one` and the return path were byte-untouched.

That split was not mine. The acceptance required `[1, 2].tap { |a, b| }` to bind `1 | 2` per slot with the ADR-101 optimistic mark, and plain `SelfSubstitute` reuse cannot produce it (see below). I escalated with the concrete fork and the supervisor chose Candidate B: one verdict, return-only widening. `docs/internal-spec/inference-engine.md` now records exactly that.

Evidence came from probes in `tmp/`. `probe1130.rb` ran the engine through scope evaluation with an `on_enter` watcher on local reads: after the change, `ints.tap { |a| }` binds `Array[Integer]`, `[1, 2].tap { |a, b| }` binds `1 | 2` in both slots with `scope.optimistic_local` reporting `implicitly_returns_nil`, and `[1, 2].tap {}` still returns `Array[Integer]`. `probe_binder.rb` confirmed the binder maps an `Array[T]` yield to T per slot. Specs: six new `.block_param_types` examples in `rbs_dispatch_spec.rb`, plus `block_param_self_substitute_spec.rb`, which drives `assert_type` through the real runner. The mutator-decline case needs a fixture sig because no RBS core method is both a mutator and a self-yielder: `SubBox[A]` with `pure` and `rewrite!`, and `SubBoxMaker.pack` to obtain a typed `SubBox[Integer]` value. The lib and plugins self-checks, run with the engine file stashed for the before arm, came back byte-identical.

### Wrong turns

SelfSubstitute deep-widens. `projected_self` applies `deep_widen` to every type argument, and `deep_widen` routes value-pinned constants through `widen_value_pinned`, so `Constant[1] | Constant[2]` becomes `Integer`. `SelfSubstitute.for` on the tuple `[1, 2]` returns `Array[Integer]`. Feeding that product to the block translator binds `Integer` per slot, which fails the acceptance's literal `1 | 2`. The block path must consume the verdict, not the widened product.

The 1 | 2 versus explicit 1, 2 trap. I assumed the acceptance's parenthetical "matching explicit `a, b = [1, 2]`" meant the engine binds `1 | 2` in that position too. Measured, it does not. A literal tuple destructures element-wise: `a, b = [1, 2]` binds `Constant[1]` and `Constant[2]`. The `1 | 2` reading belongs to the block auto-splat of an `Array[T]` yield, which binds T, the element union, per slot. The two answers share the element family but are different mechanisms.

Smaller ones. The single-parameter form `[1, 2].tap { |pair| }` holds the whole `Array[1 | 2]` and carries no optimistic mark; only splat positions are marked, so do not over-assert. `map!`'s block parameter is `Elem`, resolved through `type_vars`, so it binds `1 | 2` today even on a mutator; a decline is observable only on a self-yielding parameter, hence the fixture sig. `Dir.mktmpdir` in a memoized environment leaks under the spec residue gate; `SpecTmpdir.suite_lifetime` is the fix. RuboCop forced the assignment into a modifier if and a `ParameterLists` disable on the widened keyword list. For a `Dynamic[Array[Integer]]` receiver the verdict is non-nil and the wrapper flattens to a plain `Array[Integer]` block self; acceptance does not cover it, I flagged it as a residual risk.

### What the next lane should not rediscover

The verdict and the widening are separable. Reuse `SelfSubstitute.for` for keep-versus-degrade; build the block self from `receiver_args` directly. Never route the return path's widened substitute into the block translator.

"Matching explicit destructure" in acceptance language means the element family, not the exact constants the explicit multi-assign binds. Measure before trusting the prose: the `on_enter` probe and a stash-toggled self-check diff are the fast evidence loops.

The worktree needs its own `vendor/bundle` (`bundle install`) before anything runs; the absent `references/` submodule shows as two pre-existing docs-check pendings, not failures. Create the PR before the changelog fragment, because the fragment gate requires the PR link. And a nil verdict still does not answer what a `Dynamic` receiver's block self should be; nobody owns that question yet.

## #1071 — what we actually did

The lane implemented PR #1160. Inside a `respond_to` dispatcher, each format arm now edges the action to the arm's conventional template `<action>.<fmt>` in addition to the targets of any explicit render inside the arm, unless the arm responds unconditionally at the top level of its own block. The old unit rule answered one html edge per unit, so an action that spelled `format.js` never reached its `.js.erb` template.

Mechanically it lives in `unit_scan.rb`. `record_format_arm` recognises `format.<fmt>` calls whose receiver is the dispatcher block's first required parameter, and it depends on a block stack that now pushes every `BlockNode` the walk descends into, so the innermost enclosing block can be identified as the transparent `respond_to` block. An arm with a block gets an identity entry in `@arms_by_block`; `enter_arm_block` pushes `[arm, @conditional]` after the arm block's own conditional increment, so its body's top level sits at exactly that recorded depth. A plugin `responds:` row firing at that depth marks the arm answered; a deeper response, inside a nested `if` or block, does not, mirroring the unit-level `@responded` rule. An empty block or one that only assigns is therefore untouched: `format.js {}` and `format.js { @users = [] }` still fall through to `default_render` and keep the conventional template, which was exactly the point the first draft of the ruling got overturned on. `format.any` and `format.all` get no conventional edge at all, because they serve every request format and no single template can be their convention.

`callee_rule.rb` widened `rails_implicit_render` to take a `format:` argument with `html` as the default, so `apply_unit_callee_row` applies the unit callee row once per arm with that arm's format. The html unit edge stands down only where a dispatcher was seen at the unit's top level; a dispatcher nested under a branch keeps the plain implicit edge, because the fall-through path still runs.

Spec work: `actionpack_template_edge_spec.rb` flipped the old `dispatched` over-approximation (`format.html { render :show }` now names only `show.html`) and gained `js_arm`, `js_arm_with_block`, `js_arm_answered`, `any_plus_js_arms` and `any_all_arms`. Corpus copies of redmine and mastodon produced byte-identical `check` JSON before and after; the effects table moved labels only (redmine 2 actions gained, 23 changed, 0 lost all; mastodon 0), and the gained labels traced to `.js.erb` template units carrying `mutate.local`.

### Wrong turns

The corpus burned the most time. The harness runs `check` plus `effects` for two projects, twice per arm, and each run is minutes; I compounded it by trying to adjudicate redmine's 23 changed rows one by one. The parent redirected: do not re-run the corpus, record the counts as residual risk. The timeout ate the session budget, not the code.

A bare Ruby probe outside the spec helper produced load-error diagnostics and empty edges because the plugin requirer registered nothing. Only the real RSpec harness was trustworthy. Do not debug plugin behaviour through a script that skips the harness.

The first `any_plus_js_arms` fixture asserted against an empty edge list because the `.js.erb` file was missing from the fixture and the propagator drops an edge that resolves to no unit. That is not a scan bug; the spec must ship the template the edge claims.

RuboCop flagged `apply_unit_callee` under `Naming/PredicateMethod` because it returned `true`/`false`, and both `attribute_plugin` and `apply_unit_callees` exceeded the complexity caps. I extracted `mark_arm_responded` and `apply_unit_callee_row`, and made `apply_unit_callee` return the callee instead of a boolean.

I also broke the file while editing: an edit meant to insert the `FormatArm` struct over the `private` keyword silently removed the `def add` header. `ruby -c` caught it before anything ran, but the patch churn cost a cycle.

### What the next lane should not rediscover

The arm responded bit is the unit responded bit re-scoped: record the depth at arm entry, compare for equality when a `responds:` row fires, and remember the arm block's own conditional increment is what puts its top level at that depth.

Keep `FormatArm` a mutable `Struct`, not `Data`, because the walk mutates `responded`.

The edges list inside the scan differs from what the integration spec's `entry.edges` returns; the latter is the post-propagator resolved list, so assert against templates that actually exist in the fixture.

Respect the block stack: every `BlockNode` must push and pop, not only the transparent ones, or `record_format_arm` cannot see the `respond_to` block as the innermost enclosure. Keep the `@conditional` increment before `enter_arm_block` and the decrement after the pop.

Finally, treat a corpus gate as the expensive step it is. The byte-identity of the `check` JSON between arms is the cheap signal; the effects label counts are a labels-only footnote, not an action-by-action auditing task, and the numbers from this lane are in PR #1160 already.

## #1089 — what we actually did

The fix landed in one file: `plugins/rigor-activerecord/lib/rigor/plugin/activerecord.rb`. The bug was entirely inside `column_return_type`, the written-receiver path. It mapped `column.ruby_type` to a Rigor type and never consulted `entry.enums`, so `post.status` on `enum status: { active: 0, archived: 1 }` (a `t.integer` column) typed `Integer`, while Rails returns the key `"active"`. I added a branch: when `entry.enum?(column_name)`, return `enum_key_type`, which builds the union of the key String constants (`Constant["active"] | Constant["archived"]`), falling back to `Nominal[String]` for an empty key list. The empty-key guard matters because `parse_enum_call` accepts `enum :status, []` as a parseable declaration. `ModelIndex` only records an enum when every key is a static Symbol literal, so the union is complete by construction and is exact rather than the wider `String`.

The implicit-self reader stays untouched. `implicit_self_instance_member_type` keeps answering `Dynamic[top]` because the precise variant was measured at 57 false positives on mastodon in #963. My new spec pins both spellings side by side: written receiver narrows, bare read inside a model `def` stays `untyped`.

I also bumped the manifest from 0.11.0 to 0.12.0. No producer payload changed shape, but the 0.11.0 comment sets the precedent that the version is the cache key a project sees for behavior claims, and this changes which written-receiver calls the plugin claims.

The spec work lives in `spec/integration/plugins/activerecord_plugin_spec.rb` under a new nested describe with a fixture carrying both an integer-backed (`status`) and a string-backed (`visibility`) enum. Five examples: union narrowing for both backends, `upcase` silent, `status + 1` dumps `String` not `Integer`, `status?` stays `bool`, implicit-self stays `Dynamic[top]`.

### Wrong turns

The `+ 1` acceptance arm could not be met. `post.status + 1` produced no diagnostic no matter what String-family type I contributed. Probing showed this is engine-wide: `s = "a"; s + 1`, `"active" + 1`, and `post.title + 1` are all silent, and only `+ nil` fires. `call.argument-type-mismatch` is deliberately nil-only for coerce-safety, documented in `spec/rigor/analysis/check_rules/nil_argument_mismatch_spec.rb`. I escalated to the supervisor, who chose option (a): stay plugin-side, no engine change, and verify the arm at the type level via `Rigor.dump_type(post.status + 1) == String`. I should have probed this in the first hour instead of after the acceptance test failed.

I misplaced the RSpec block twice. My insertion anchors matched the closing `end` of a nested describe first inside `ActiveRecord::Relation typing`, then inside `declarations inside a with_options block`, and my first relocation dropped the `end` that closed the real parent, leaving an unclosed `RSpec.describe` that surfaced as a syntax error at the last line of the file. The helpers `column_contribution` and `bool_union` live in `describe "instance column accessors"`, which I should have confirmed before splicing. A Python re-indent script fixed the block, but use the describe registry before editing, not eyeballed `end` matching.

The first `gh pr create` mangled the body: backticks inside the heredoc were command-substituted by the shell wrapper, stripping inline spans like `column?` and executing stray fragments. I rewrote the body from a file with `gh pr edit --body-file`. Write PR bodies to a file first.

The corpus arm burned the budget. The mastodon full check on the survey checkout is heavy. I ran only mastodon before/after (byte-identical, 2548 rows, 0 gone, 0 new) and never reached redmine.

### What the next lane should not rediscover

Probe the engine before writing an acceptance test that expects a diagnostic. Non-nil mismatch on `+` cannot fire in this build, by design.

For corpus measurement, follow `docs/agents/measurement.md`: toggle the changed file in the working tree with `git stash push -- <file>` and run every target on each arm from its own cwd, with `--no-cache --no-baseline`, using this worktree's `exe/rigor` and `Gemfile`. Do not use a second worktree checkout as a baseline arm. Time one arm before committing to two targets, and treat the corpus dumps as scratch, never commit material.

`entry.enums` carries symbol-name strings and the reader returns String keys, so map through `key.to_s` before `constant_of`. A reported enum that declines to record (non-literal values) falls back to ordinary storage typing, which is correct.

Check the `RSpec.describe` nesting and the helper method locations before placing a new `describe`. Verify `ruby -c` after any block relocation. Write the PR body to a temp file and pass it with `--body-file`, instead of a heredoc containing backticks.

Finally, the manifest comment on `version:` is where the cache-key reasoning for a behavior claim lives. If a change alters which calls a plugin answers, bump it and say why in that comment, exactly as the 0.11.0 entry does.
