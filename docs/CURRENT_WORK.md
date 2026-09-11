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

## Where the cycle stands

**v0.3.8 is published**; `[Unreleased]` is empty and `changelog.d/` holds the whole cycle (2026-09-09's
~30 PRs plus 2026-09-10's two batches below). The next cut happens only when the user invokes
`/rigor-release-prep`.

## 2026-09-10 — the v0.3.9 milestone sweep, 15 parallel lanes

One session drove `gh issue list --milestone v0.3.9` with Sonnet/Opus lanes in worktrees, no local
full gate, remote CI as the gate, adversarial review before each merge. Landed (all merged, master
green at the last integration run):

- Engine FPs: #946 (#917 `.new` arity on an undeclared constructor), #945 (#909 `class << self`
  ivar facet), #955 (#633 own-method veto reaches inherited/pre-`Object`/singleton sources), #951
  (#645 union mutator widening), #964 (#643 element-read mutation), #965 (#617 block-return residues:
  compound-write tail, `String#<<`, find-family floor, cap floor), #961 (#722 compact-header leading
  segment; `IncrementalSnapshot::SCHEMA` 20).
- Caches: #954 (#629/#630 plugin `IoBoundary` reads + `list_directory` row), #958 (#639 class-existence
  edge; #640 was already fixed and is now gated), #966 (#960 editor-mode `--instead-of` spelling +
  buffer digest).
- CLI/plugins: #949 (#925 `target_gems:` + plugin-gap advisory, DIRECT deps only + `rails` umbrella),
  #968 (#936 item 3, the `Difference` mutator arm; #936 closed), #944 (#918 rigor-ffi `config_schema`), #947 (#920 `rigor init` rule list from `ALL_RULES`), #950
  (#921 `:factory_index` fact + probe commands run `#prepare`), #957 (#609 sig-gen `::`-anchored
  superclass, exit 70 on a fatal error, `sig/` IS auto-discovered), #952 (#530 lockfile-less gem
  provenance), #962 (#936 items 1/4/5/7), #967 (doctor catalogue off loaded classes — an
  order-dependent shard flake that reddened master once).
- Docs straight to master: #919, #940 (17 ADRs re-statused with code evidence), #941, #942, #943
  (partial-supersession marker in ADR-49, ten ADRs), #948 (#939 the header-vs-index status gate),
  #956 (#938 residues).
- Adjudicated without code: #533 closed (6/8 already fixed; item 5 split to #953).

## 2026-09-10, second batch — five `ready-for-agent` lanes, all landed

- #975 (#580): a mutation-widened `Nominal` re-joins later stores, gated in-band on a parameter that
  already carries a `Dynamic[top]` arm (no provenance slot exists on `Type::Nominal`; the gradual arm
  IS the mark). `a = []; a.push(1); a.push("s")` reads `Array[Dynamic[top] | Integer | String]`.
- #972 (#599): factory-method freshness — the gate accepts a chained receiver whose callee is cheaply
  resolvable and whose RETURN POSITION is a materialisation (not a self-alias scan; documented why).
- #971 (#911): `.rigor.yml` `plugins_isolation:` (`none` | `process`); ENV wins; `ruby_box` is a
  configuration error naming the variable.
- #974 (#534 item 7 only — items 1–4 were already landed; 5 and 6 stay open): the Rails plugins
  declare their exception hierarchies / namespaces leniently, every class in `open_receivers:`.
- #973 (#915): `class << self; include M; end` records as an extend; RBS-declared `extend` reaches
  narrowing through `Environment#singleton_extended_modules`; `IncrementalSnapshot::SCHEMA` 21.

## 2026-09-11 — the human-gated v0.3.9 items, adjudicated and landed

Adjudicated with the user (grilling round): #928, #796+#794, #959 stay on v0.3.9 and shipped; #697,
#424, #476 moved to v0.4.0; #378 closed as already settled (steins#468/#469, `mutate.instance`).
Each PR passed a Fable adversarial review before merge; two reviews sent a PR back first.

- #976 (#928): the five capability roles ship as bundled RBS (`data/capability_roles/`), project
  declarations win per declaration on a name clash, unresolved `conforms-to` interface is `:warning`.
- #977 (#959): `plugin_trust.read-refused` `:info`, one per plugin, when the `IoBoundary` refused a
  read; `getcwd` is symlink-resolved, so the hint is about the refused path's spelling, not the cwd.
- #978 (#796 + #794): the snapshot carries `definition-build-failed` and the HKT-scan outcome and
  replays them on a narrowed closure; SCHEMA 22; a `virtual:` buffer in the closure drops its entry.
  The durable false negative that drop leaves is #980 (v0.4.0, `ready-for-human`).
- #981 (#979): one names-only `GlobEntry` per signature root in the run descriptor (`mode: :names`,
  `Cache::Descriptor::SCHEMA_VERSION` 9), so a NEW `sig/*.rbs` invalidates the run cache while a
  `touch` or fresh checkout still hits. Two Fable rounds: the first stat-mode row was a High.
- #982: `Plugin::BundledCatalog` lets a class under `plugins/` win its id over an anonymous spec
  double; `spec_helper` resets the catalogue per example (the shard flake behind two red runs).

## Open threads

- #424 stays open on its WD16 target (`Propagator.propagate` at gitlab scale). The per-project half
  is measured and closed: `docs/notes/20260910-effect-collection-profile.md` — +11.3 % wall on
  plugin-less redmine, the second walk is ~36 % of the delta and the shareable descent ~12 %, so the
  ≤ 5 % bound is unreachable without changing what collection proves (a No-Go input for #409).
- Filed this session, `ready-for-human`: #959 (TrustPolicy refuses every plugin read under a symlinked
  project root, silently), #953 (literal-lambda call forms), #963 (#633 residue: block-self shapes,
  plugin-supplied methods).
- Still open on v0.3.9: only #424's WD16 half; #697 waits on #660 (v0.4.0).

## How to enter

1. Nothing is uncommitted and no PR of this session's is open. Re-derive file:line at current HEAD.
2. The lane contract that worked: worktree per lane, targeted specs + rubocop only, `git push` then
   END (no CI polling — 15 lanes with `gh run watch` loops exhausted the 5000/h GitHub API budget
   twice; poll once a minute per PR via `statusCheckRollup`). To add a commit to a lane's branch,
   reset to the remote tip and cherry-pick; a rebase-then-push is non-fast-forward and force is
   blocked.
3. Three things every engine lane tripped on: the `sig/` provenance residue pin
   (`spec/rigor/sig_gen/provenance_spec.rb`) moves whenever a hand-written line lands OR inference
   changes what sig-gen would emit — #965's `@x ||= new` reading moved three `.default` readers to
   `sig.skipped.untyped-return` until the unbound case kept the rvalue; a new precision fixture needs
   its golden (`UPDATE_SNAPSHOTS=<fixture>`); and a spec that enables a bundled plugin by gem name is
   order-dependent unless it registers the class itself (`Rigor::Plugin.unregister!` + no-op `require`).
4. `gh issue list --label ready-for-agent` is the backlog; the v0.4.0 milestone is the pre-1.0 break.
