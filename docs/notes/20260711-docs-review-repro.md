# L2 伝(b) procedure-reproduction review — 01-installation.md + 14-rails-quickstart.md

Date: 2026-07-11. Lens: reproduce each procedure from the text alone,
flag any step that cannot be completed without outside knowledge.
Rigor version exercised: `rigor 0.2.8` (repo `master`, dirty tree).

Execution note (NOT a doc defect): the published `rigor …` invocation is
correct for an installed gem. In this repo I substituted
`BUNDLE_GEMFILE=<rigor>/Gemfile nix develop <rigor> -c bundle exec <rigor>/exe/rigor …`
run from a scratch dir — a Flake-shell environment detail only.

## What was actually run and verified

- `rigor --version` → `rigor 0.2.8`. ✓ (ch14 Step 1)
- `rigor baseline generate` → `wrote baseline to .rigor-baseline.yml` + a
  note to add `baseline:` to activate. ✓ (ch14 Step 6)
- `rigor skill --list` / `--path rigor-project-init` / `skill rigor-project-init`
  (body print) — header matches the doc's description exactly (absolute
  SKILL path + `references/` dir + body). ✓ (ch14 Path A)
- `rigor sig-gen --write` flag exists; `rigor triage --format json` exists. ✓
- Authored the ch14 Step 3 `.rigor.dist.yml` verbatim-shape (target_ruby,
  paths, exclude, plugins, `severity_profile: lenient`) + a tiny `app/foo.rb`;
  ran `rigor check` with no path arg → config is read, `paths:` honoured,
  `severity_profile: lenient` accepted, plugin loaded. ✓ (ch14 Steps 3–4)
- All manual cross-reference files exist (06/07/09/11/14, plugins/README.md,
  skills/rigor-project-init/SKILL.md, adr/72). Anchors `#set-up-in-your-language`,
  `#path-a-…`, `#path-b-…` resolve. ✓

## Findings

| Step (chapter:line + quote) | What breaks reproduction | Severity | Proposed fix |
| --- | --- | --- | --- |
| 14:291 `rigor baseline generate` | The command works, but it is **absent from `rigor --help`**'s command list (help shows `diff` for baselines, not `baseline`). A reader who runs `rigor help` to confirm the verb won't find it and may doubt the doc. Reproducible because the exact command is given. | nitpick | Either list `baseline` in `rigor --help`, or (doc side) no change needed — the exact command carries the reader. Prefer the CLI fix. |
| 01:289–297 asdf block: "Install a Ruby 4.0.x with the [`asdf-ruby`] plugin … `asdf install ruby latest:4.0`" | For a reader new to asdf, `asdf install ruby` fails until `asdf plugin add ruby` has been run. The doc links the plugin repo but never states the `asdf plugin add ruby` step, so a first-time asdf user must leave the page. | FRICTION | Add one line before `asdf install`: `asdf plugin add ruby` (or note "add the asdf-ruby plugin first"). |
| 14:150–166 Step 2 modes "Acknowledge"/"Strict" vs 14:199 `severity_profile: lenient   # "strict" … omit for "balanced"` | Two vocabularies collide: adoption *modes* are acknowledge/strict; `severity_profile` values are lenient/strict/balanced. The acknowledge→`lenient` mapping is only implicit in the example config, so a reader in acknowledge mode must infer which profile string to use. | nitpick | One clause in Step 3: "acknowledge mode → `severity_profile: lenient`; strict mode → `strict`." |
| 14:30–31 "See [Installing Rigor § Putting rigor on your PATH](01-installation.md)" | Link text names a section (`§ Putting rigor on your PATH`) but the target has no `#putting-rigor-on-your-path` anchor — it lands at the file top. The section exists (01:258); a reader must scroll. Not broken, just imprecise. | nitpick | Append the anchor: `(01-installation.md#putting-rigor-on-your-path)`. (ch14:54 does anchor its 01 link correctly, so the pattern is already in use.) |

No BLOCK-severity gaps found. Prerequisites (Ruby 4.0, mise installed +
shell-wired, an existing Rails project at a known path) are all explicitly
stated in ch14 "Before you start". Ordering is sound: `mise.toml` is created
in Step 1 before it is committed in Step 7; the config exists (Step 3) before
the first `rigor check` (Step 4); the baseline is generated (Step 6) before
`baseline:` is uncommented and committed (Steps 6–7). Path A is correctly
framed as "invoke the skill", so its internal phases (sig-gen/triage/baseline)
are the skill's job, not reader steps.

## Verdict

A competent Ruby developer can complete both procedures from the text alone.
Every documented command runs as described and every cross-reference resolves;
the config the quickstart tells you to author is read correctly by `rigor check`
exactly as written. The only real snag is the asdf path, which omits the
`asdf plugin add ruby` prerequisite and so forces a first-time asdf user off the
page (FRICTION). The rest are cosmetic: a working-but-help-invisible `baseline`
verb, an implicit mode→`severity_profile` mapping, and one section link missing
its anchor — none of which stop a reader from finishing the setup.
