# Install-channel evaluation — mise, Bundler, Homebrew, and what the corpus had never checked

Date: 2026-07-17.

Status: **research note.** The design commitments it produced are
[ADR-95](../adr/95-homebrew-tap-deferral.md) (Homebrew deferral) and three shipped
changes — the packaging guardrails (#114), the installation-doc corrections (#115),
and `rigor doctor`'s Gemfile-install check (#116). Everything else here is evidence.

Prompted by a plain question: is `mise` actually the right recommendation, is putting
Rigor in a `Gemfile` really as bad as we say, should we offer a `brew tap`, and can
`mise use -g ruby@4.0 gem:rigortype` cross Ruby versions?

[ADR-27](../adr/27-tool-distribution-model.md) already owns the distribution model, so
most of this is a re-examination of decisions it made in 2026-05 — with the difference
that the mise claims were **measured** here rather than reasoned about.

---

## 1. The mixing question — measured, not inferred

**Verdict: `mise use -g ruby@4.0 gem:rigortype` cannot mix Ruby versions.** Three layers,
all confirmed by dissecting a real install on a maintainer machine:

| Layer | Evidence |
| --- | --- |
| Isolated GEM_HOME per tool | `~/.local/share/mise/installs/gem-rigortype/0.2.5/libexec/` holds Rigor's own `rbs 4.0.3` / `prism 1.9.0` — invisible to the project and to the global Ruby |
| Wrapper hardcodes it | `bin/rigor` is `GEM_HOME=".../libexec" exec .../libexec/bin/rigor` |
| Binstub pins the interpreter | the inner binstub prefers a bundled `ruby` symlink → `installs/ruby/4.0/bin/ruby` — a **minor-version** symlink, so 4.0.x patch bumps are followed automatically |

Direct test: in a directory whose `mise.toml` pins `ruby = "3.2"`, `ruby -v` reports
3.2.9 while `rigor --version` reports 0.2.5 and works.

**The inversion worth recording: plain `gem install` is the channel that mixes.** Its
binstub is `#!/usr/bin/env ruby`, floating to whatever Ruby is first on `PATH` at
invocation — so inside a Ruby 3.x project it fails `required_ruby_version` activation
(the CocoaPods [#10512](https://github.com/CocoaPods/CocoaPods/issues/10512) failure
class). ADR-27 ranked mise above `gem install` on ergonomics; the ranking is right for a
reason it never stated. Now in [`01-installation.md`](../manual/01-installation.md).

*(Confirmed again by accident while developing #116: invoking `ruby -Ilib` outside
`bundle exec` picked up a global `rbs 4.0.2` whose native extension was built against a
different Ruby — `linked to incompatible libruby`. The hazard is not theoretical.)*

## 2. Two live defects in our own mise documentation

Both found by reading what mise actually writes, not what we assumed.

**(a) The shared-version claim was false.** `mise use` preserves the precision you
*asked for*. `mise use ruby@4.0` records `ruby = "4.0"`; `mise use gem:rigortype` has no
requested version to preserve and records `"gem:rigortype" = "latest"` — which each
machine re-resolves to whatever is newest when *it* first installs. The chapter
nonetheless said committing `mise.toml` makes "every contributor — and every CI run —
resolve … the same Rigor version". Verified on a scratch project:

```console
$ mise use gem:colorize        # → "gem:colorize" = "latest"
$ mise use --pin gem:colorize  # → "gem:colorize" = "1.1.0"
```

**(b) A pinned tool can never be reported as behind.** `mise upgrade` and `mise outdated`
both compare the installed version against the *range the config asks for*, and an exact
pin is a range containing only itself:

```console
$ cat ~/.config/mise/config.toml   # "gem:rigortype" = "0.2.5", while 0.2.9 is current
$ mise up gem:rigortype            # → "All tools are up to date"
$ mise outdated                    # → "All tools are up to date"
$ mise up --bump --dry-run gem:rigortype
Would install gem:rigortype@0.2.9
```

That is a pin working, not a bug — but it means a pinned setup has **no passive signal
that a new Rigor exists**. The maintainer machine this was found on had been sitting on
0.2.5 across four releases. Both defects fixed in #115.

## 3. Is a Gemfile install really bad?

The answer is three different answers, and ADR-27 stated only the first.

1. **Ruby ≠ 4.0 (almost every analyzed project) — not "bad", impossible.** All 39
   published `rigortype` versions require `>= 4.0.0, < 4.1` (RubyGems API), so `bundle add`
   cannot resolve, and cannot silently land on an old permissive version. Fail-fast is
   healthy. What is missing is that Bundler's error names the conflict and never the fix,
   so the natural next move is a destructive workaround (rewrite `.ruby-version`, reach
   for `--ignore-dependencies`).
2. **Ruby = 4.0 — worse, because it succeeds.** `bundle add` works and nothing is wrong
   until the next boot, where `Bundler.require` (which requires a gem by its *gem* name,
   while our library entry is `rigor.rb`) dies on a bare `LoadError`. A delayed trap.
3. **An isolated `Gemfile` — already our own recommendation.**
   [`11-ci.md`](../manual/11-ci.md) recommends `.github/rigor/Gemfile` + `BUNDLE_GEMFILE`
   for pinning, Dependabot included.

So **the enemy is root-Gemfile contamination, not Bundler** — a distinction the corpus
held implicitly and documented nowhere, leaving a reader who wanted Bundler with a
prohibition and no supported alternative. There is no user for whom a root-Gemfile entry
is the right answer: the pinning it buys is available without the cost.

Worth noting the honest counter-weight: ADR-27's *dependency-conflict* argument is an
analogy to Steep / ruby-lsp and has never been measured for Rigor's own three deps. It
does not need to be — argument (1) is mechanical and sufficient. And the corpus's only
field-measured install defect is on the **standalone** side, not the Gemfile side
([ADR-90](../adr/90-target-library-resolution-from-project-bundle.md)'s activesupport
inflector, masked by the maintainer dev bundle).

## 4. Ecosystem norms

| Tool | Official recommendation | Note |
| --- | --- | --- |
| RuboCop | `gem install`; Gemfile allowed **with `require: false`** | must never load into the app |
| Steep / TypeProf | `gem install` (READMEs) | neither pushes Gemfile-first |
| Sorbet | Gemfile, explicitly | has a **runtime** component (`sorbet-runtime`) — the strongest must-bundle case |
| PHPStan | `composer require --dev` | works *because* the phar's deps are PHP-Scoper–prefixed; Ruby has no equivalent isolation |
| Psalm | `composer require --dev`, phar when deps conflict | conflict is the documented escape hatch |
| foreman | **"take care _not_ to install foreman in your project's `Gemfile`"** | the "not a library" precedent |
| fastlane | Gemfile + `bundle exec`, explicitly | the counter-precedent |

Rigor has **zero runtime components**, so the structural reason Sorbet must be bundled
does not apply, and the mechanism that lets PHPStan be bundled safely does not exist in
Ruby. `foreman` is the closest precedent.

## 5. Homebrew — never evaluated before this note

Findings (see [ADR-95](../adr/95-homebrew-tap-deferral.md) for the decision):

- **No Ruby static-analysis tool is in homebrew-core at all** — no `rubocop`, `steep`,
  `typeprof`, `sorbet`, `brakeman`. (`standard` in core is the *JavaScript* standardjs.)
  What is there is `fastlane`, `cocoapods`, `ruby-lsp` — all far larger.
- **Core notability** requires ≥30 forks / ≥30 watchers / ≥75 stars, **tripled for
  self-submission** (≥90/≥90/≥225). rigortype does not clear it today.
- **The formula pattern is well-trodden** (`ruby-lsp`: `depends_on "ruby"`,
  `GEM_HOME=libexec`, `bin.env_script_all_files`), and per-release bumps automate with
  `brew bump-formula-pr`. Authoring is not the cost.
- **The cost is brew's `ruby` churn against our `< 4.1` cap.** Homebrew's `ruby` tracks
  latest; a formula depending on it breaks whenever the two disagree, and Homebrew's own
  Cookbook requires `revision` bumps of dependents when a dependency moves
  incompatibly. This is the CocoaPods "installed with a different Ruby than the one
  invoking it" failure class, imported deliberately.
- The escape is **[ADR-27](../adr/27-tool-distribution-model.md) WD5's single binary**
  ([tebako](https://github.com/tamatebako/tebako) is the only maintained 2026 option —
  ruby-packer abandoned, traveling-ruby dormant), which removes `depends_on "ruby"` and
  the churn with it.

## 6. Loose ends

- **`gem exec rigortype check`** (RubyGems ≥ 3.4.8, 2023) runs without installing.
  Labelled experimental at introduction and never declared stable; plausible as a
  README "try it" line, not a channel.
- **No official Docker image precedent** for a Ruby analysis CLI (rubocop/steep images
  on Docker Hub are community-run). Ours is already a documented last resort.
- **Windows-native (non-WSL, non-container)** still has no first-class path.
- **A possible internal inconsistency, untouched:**
  `plugins/rigor-rails/lib/rigor-rails.rb:15` says a Gemfile entry for the plugin
  meta-gem is "harmless" ([ADR-12](../adr/12-dry-rb-packaging.md)'s Gemfile-convenience
  pattern), while plugins today ship *inside* `rigortype` (`spec.require_paths` includes
  `plugins/*/lib`). Whether "rigortype must not be in a Gemfile, but plugin gems may be"
  still holds is worth a look.
