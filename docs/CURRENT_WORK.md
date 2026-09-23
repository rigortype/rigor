<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Hard cap: 120 lines, enforced by spec/docs/agent_index_spec.rb. Compress, do not append.
- Verify a claim before carrying it forward, by the thing that decides rather than a proxy —
  including claims in THIS file. Three sessions running, its own pointers have been wrong.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones.
If this file disagrees with an ADR, the CHANGELOG, or an issue, this file is the one that is wrong.

## What the 2026-09-22/23 `-> untyped` audit sessions landed

All merged, CI green, adversarial review (Fable/Grok) Approved:

- [#1169](https://github.com/rigortype/rigor/pull/1169) — incidental-return APIs → `void`.
- [#1170](https://github.com/rigortype/rigor/pull/1170) — `untyped`/`void`/`top` theory note
  (`docs/notes/20260922-untyped-void-top-return-contracts.md`) + first classification of 77 sites.
- [#1171](https://github.com/rigortype/rigor/pull/1171) — `dump_type`/`assert_type` generic
  pass-through.
- [#1174](https://github.com/rigortype/rigor/pull/1174) → `a2387d66` — batch 1: 22 `-> untyped`
  returns named precisely; also added the `Rigor::SigGen` shell decl that un-quarantined
  `sig/rigor/sig_gen/skip_reason_catalog.rbs`.
- [#1176](https://github.com/rigortype/rigor/pull/1176) — `instance_definition` false positive.
- [#1178](https://github.com/rigortype/rigor/pull/1178) → `0765b45b` — #1173 ancestor fallback for
  RBS-known modules; also corrected `includes_of` to runtime MRO order (include is last-wins across
  statements), SCHEMA 26→27, `declared_before_object?` + resiting guards in
  `ExternalAncestorResolution`.
- [#1179](https://github.com/rigortype/rigor/pull/1179) → `e890b0dc` — #1175: compound ivar writes
  (`||=`/`&&=`/`op=`) now seed the class-ivar accumulator; ADR-58 WD5 implemented; CI self-check
  runs `--fail-on=warning` (the `unit_scan.rb:560` warning is gone; `make check` is green on master).
- [#1180](https://github.com/rigortype/rigor/pull/1180) → `b0dd3cc3` — batch 2: Manifest/Runner/
  Loader/Narrowing/etc. tightened; `produces` is `Array[Symbol]` (post-`to_sym`),
  `source_rbs_synthesizer` deliberately stays `untyped` (multi-shape WD6/WD12 outcome).
- [#1184](https://github.com/rigortype/rigor/pull/1184) → `41b652e3` — #1181 slice 1:
  `Baseline::{Bucket,DriftRow}` declared (first `Struct.new` sigs; member rows marked #1183).
- [#1185](https://github.com/rigortype/rigor/pull/1185) → `25300e01` — #1181 slice 2:
  `Plugin::AdditionalInitializer` + `Manifest`/`Registry#additional_initializers`.
- [#1186](https://github.com/rigortype/rigor/pull/1186) → `1b867b76` — #1181 slice 3:
  `Plugin::ProtocolContract` (+`ParamType` Data member, marked #1150) unblocking
  `Manifest`/`Base#protocol_contracts` and new `Registry#protocol_contracts`/`contracts_for_path`.
- [#1187](https://github.com/rigortype/rigor/pull/1187) → `4d06efee` — #1181 slice 4:
  `Analysis::ProjectScan` (Data.define) unblocking `Runner#prepare_project_scan` + the `prebuilt:`
  kwarg; 3 members stay `untyped` (SyntheticMethodIndex / ProjectPatchedMethods / TemplateUnits
  unsigned).
- [#1188](https://github.com/rigortype/rigor/pull/1188) → `99ea44e5` — #1181 slice 5:
  `Effects::*` bound side (`Label`/`MethodKey`/`TaintCause`/`Origin`/`LabelSet`/`Envelope`/
  `ConfigEnvelopes`/`EnvelopeIndex`), `Runner#effect_envelopes` +
  `RbsExtended.read_effect_envelope → Envelope?`.
- [#1189](https://github.com/rigortype/rigor/pull/1189) → `9b2d943e` — #1181 slice 6:
  `Effects::*` collection side (`Summary`, `EffectTable`+`Entry`, `FileCollection`+`Edge`,
  `PluginFacts`+`Row`/`Edge`) unblocking all four `Runner#effect_*` readers; review dropped
  `forced_file_effects` (private API is not declared in `sig/`) and scoped `#1154` markers to
  initialize-parameter readers only.
- [#1190](https://github.com/rigortype/rigor/pull/1190) → `c56c2ccf` — #1181 slice 7:
  `Effects::Registry`, `Plugin::{EffectAttribution,EffectEdge,EffectAncestry,EffectEntryPoints}`,
  `Registry::Contribution`; `Manifest`/`Base`/`Registry` `effect_*` readers +
  `PluginFacts#extend_registry`/`contributions:`/`entry_points` tightened. Grok+Opus review:
  `effect_owner` narrows via a local (no suppression needed); `effects?`/ancestry filed as #1200.

Earlier `queue-release` merges (`#1158`–`#1162`, `79fa99cf`/`9fd4b6d4`/`19c2af59`) are all landed;
no open PRs at handoff time.

## Waiting on the maintainer

Nothing new. Long-standing `ready-for-human` backlog is unchanged (`gh issue list --label ready-for-human`).

## What is worth picking up next

- **#1181** — Class B sig-coverage backlog (landed: Baseline #1184, AdditionalInitializer #1185,
  ProtocolContract #1186, ProjectScan #1187, Effects bound #1188, Effects collection #1189,
  vocabulary/Contribution #1190 — `Effects::*` and the plugin effect row classes are done).
  Remaining: `Plugin::Macro::*` (Manifest `block_as_methods` / `heredoc_templates` /
  `nested_class_templates` / `trait_registries`), `Inference::HktRegistry::*`
  (`#hkt_registrations` / `#hkt_definitions`), `Environment::Reflection` + the three `*_reporter`
  duck types, `RuleWalk::CollectorDriver`, `Cache::*` entry/descriptor types, and
  `Rigor::FlowContribution` (`RbsExtended.read_flow_contribution`). Process: `rigor sig-gen
  --print` provenance first per `docs/agents/type-authoring.md`; `#1154` markers only cover
  readers assigned from `initialize` parameters — `absorb`/`compute`-built readers pin unmarked;
  `#1150` for `Data`/`Struct` members; reviewers are Grok 4.6 + Opus (`run-role.sh reviewer`,
  `PRINT=1` + prompt).
- **#1177** — `OptimisticOrigin` lost across method boundary (needs-triage; a
  `rigor-wt/optimistic-origin-nil-predicate` directory exists on disk but is NOT a registered
  worktree — verify before reusing).
- **#1168** — ready-for-agent: straight-line multi-assign index targets.
- **sig-gen skip batch** — #1148–#1157 (element-type / Data-member / endless-def gaps); the honest
  fix per `type-authoring.md` is a sig-gen gap issue, several already filed.

## Where the worktrees are

All `rigor-wt/*` worktrees from this session were pruned after merge. The older
`/Users/megurine/repo/ruby/worktrees/rigor/pi-worktree-*` set belongs to the `queue-release` lane;
its PRs have landed, so the worktrees are prunable if idle (`git worktree remove` refuses on
`references/` submodule checkouts — `rm -rf` + `git worktree prune`).
