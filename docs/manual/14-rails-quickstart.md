# Rigor for Rails — step-by-step setup with mise

This walkthrough takes a Rails project from zero to a first
`rigor check` run. It uses [`mise`](https://mise.jdx.dev/) to
install Rigor alongside Ruby 4.0, keeping the analyser out of
your project's `Gemfile`.

There are two ways through this setup:

| | Approach | Best for |
| --- | --- | --- |
| **A** | [The `rigor-project-init` skill](#path-a--the-rigor-project-init-skill-recommended) | Most projects — the skill detects your stack, proposes plugins, and writes the config for you. |
| **B** | [Manual step-by-step](#path-b--manual-step-by-step) | When you want explicit control over each decision. |

Both produce the same result. **If you are unsure, follow Path A.**

---

## Before you start

You need:

- **`mise` installed** — if not, follow
  [mise's getting-started guide](https://mise.jdx.dev/getting-started.html).
  If you prefer `asdf` or a plain `gem install`, see
  [Installing Rigor](01-installation.md).
- **`mise` wired into your shell** — add
  `eval "$(mise activate zsh)"` (or the equivalent for your
  shell) to your shell rc so that `rigor` reaches your `PATH`.
  See [Installing Rigor § Putting rigor on your PATH](01-installation.md#putting-rigor-on-your-path)
  for detail.
- **An existing Rails project** at a known path.

---

## Step 1 — Install Ruby 4.0 and Rigor (common to both paths)

> **Using an AI agent?** Point it at the machine-readable install
> guide instead:
>
> ```
> Install Rigor in this project by following the instructions at
> https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
> ```
>
> The agent will detect your environment (mise / asdf / plain Ruby),
> install the right tools, and hand off to `rigor-project-init`
> automatically.

**Set up in your language** — the prompt is plain natural
language, so you can write it (and run the whole setup
conversation) in your mother tongue. Ready-made prompts in 16
languages are in
[Installing Rigor § Set up in your language](01-installation.md#set-up-in-your-language).

Open a terminal **in your project root** and run:

```sh
mise use ruby@4.0
mise use gem:rigortype
```

`mise use` records the chosen versions in a `mise.toml` in the
current directory and installs them in one step. Verify:

```sh
rigor --version
```

All plugins ship **bundled inside `rigortype`** — no additional
gems to install. Plugins are inactive by default; you enable the
ones you need in `.rigor.dist.yml`. That is the only step that
differs between projects.

---

## Path A — the rigor-project-init skill (recommended)

The `rigor-project-init` skill automates the rest of the setup.
It works inside any AI coding agent that can read a file and run
a shell command — there is no Claude-specific machinery involved.

### What the skill does

It runs eight phases in order:

1. **Detect** — reads your `Gemfile` / `Gemfile.lock` to
   identify the framework family (Rails, dry-rb, Sinatra, …)
   and which gems are present.
2. **Choose an adoption mode** — proposes either *acknowledge*
   (snapshot today's diagnostics into a baseline; catch
   regressions going forward) or *strict* (drive the project to
   zero and keep it there). It recommends acknowledge for
   codebases with more than ~100 initial diagnostics.
3. **Select plugins** — proposes the plugin set matching your
   detected stack; you confirm or trim the list.
4. **Write `.rigor.dist.yml`** — the committed shared config,
   with `severity_profile:` tied to the chosen mode.
5. **Sig uplift** — runs `rigor sig-gen --write` to generate a
   baseline `sig/` from Rigor's own inference.
6. **Triage** — runs `rigor triage --format json` to diagnose
   the diagnostic stream by cluster.
7. **Baseline** *(acknowledge mode only)* — generates
   `.rigor-baseline.yml` and wires `baseline:` in the config.
8. **Surface real bugs** — highlights the clusters most likely
   to be genuine bugs; offers escalation paths for
   application-specific metaprogramming and gaps in Rigor's
   built-in coverage.

### How to invoke it

Say one of the following to your AI coding agent:

> "Set up Rigor in this project."
> "Configure Rigor for this Rails app."
> "Add type checking."

The agent should respond by running:

```sh
rigor skill rigor-project-init
```

That prints the SKILL definition to stdout — a short header
(with the absolute paths of the SKILL file and its `references/`
directory) followed by the SKILL body. The agent then follows
those instructions, reading the `references/NN-*.md` files in
turn from the directory the header points at.

If the agent does not pick the command up on its own, ask
explicitly: **"Run `rigor skill rigor-project-init` and
follow the instructions it prints."**

The same flow works against any bundled skill:

- `rigor skill --list` — list every bundled skill with its path.
- `rigor skill <name>` — print the SKILL body.
- `rigor skill --path <name>` — print just the absolute SKILL.md
  path (handy if your agent prefers to read the file directly).

The skill lives inside the installed `rigortype` gem at
the path printed by `rigor skill --path rigor-project-init`. The
source-of-truth copy is
[`skills/rigor-project-init/SKILL.md`](../../skills/rigor-project-init/SKILL.md).

---

## Path B — manual step-by-step

### Step 2 — Choose an adoption mode

| Mode | When | What happens |
| --- | --- | --- |
| **Acknowledge** | Existing codebase with many diagnostics | Record today's diagnostics in a baseline; surface only new ones on each PR. |
| **Strict** | New or small project | Zero outstanding diagnostics; no baseline. |

If your first `rigor check` reports more than ~100 diagnostics,
acknowledge mode is the natural starting point. You can tighten
it later. In `.rigor.dist.yml` (Step 3) the mode maps to a
`severity_profile:` — acknowledge → `lenient`, strict → `strict`
(omit the key for the default `balanced`).

### Step 3 — Write .rigor.dist.yml

The convention is to commit `.rigor.dist.yml` as the shared
project config and leave `.rigor.yml` for per-developer local
overrides (gitignored). When both files exist, `.rigor.yml`
takes precedence.

Create `.rigor.dist.yml` at your project root:

```yaml
# .rigor.dist.yml — Rigor configuration (committed; shared).

target_ruby: "3.3"   # the Ruby version your Rails app targets

paths:
  - app
  - lib

exclude:
  - vendor
  - tmp

plugins:
  # Rails core
  - rigor-activerecord
  - rigor-actionpack
  - rigor-rails-routes
  - rigor-rails-i18n
  - rigor-actionmailer
  - rigor-activejob
  # Optional — the ActiveSupport core_ext RBS is now auto-applied when
  # activesupport is in your Gemfile.lock (ADR-72); add this plugin only
  # for the fuller, opt-in surface (it stands in for the auto overlay).
  - rigor-activesupport-core-ext
  # Testing — keep the ones that match your project
  - rigor-rspec
  - rigor-factorybot

severity_profile: lenient   # "strict" for strict mode; omit for "balanced"

# baseline: .rigor-baseline.yml   # uncomment after Step 6 (acknowledge mode only)
```

Adjust `target_ruby:` to match your project's Ruby version (the
value in your `Gemfile` or `.ruby-version`) and trim the
`plugins:` list to what you actually use.

> **ActiveSupport core_ext is covered automatically.** When
> `activesupport` is in your `Gemfile.lock` but ships no RBS,
> Rigor auto-loads a bundled core-ext RBS overlay
> ([ADR-72](../adr/72-gemfile-lock-gated-rbs-overlays.md)), so
> extension calls (`3.days`, `"x".squish`, `Time.current`, …)
> resolve without any plugin or config — on a real Rails app this
> is reliably the single largest false-positive cluster (a
> Mastodon measurement found ~365 of 489 `call.undefined-method`
> diagnostics were exactly this source). The
> `rigor-activesupport-core-ext` plugin above is now optional: add
> it for the fuller, opt-in surface, and the auto overlay stands
> down for it. A plain-Ruby project without `activesupport` still
> gets the genuine diagnostic.

Other plugins to consider depending on your stack:

| Plugin | When |
| --- | --- |
| `rigor-activestorage` | `has_one_attached` / `has_many_attached` |
| `rigor-actioncable` | ActionCable channels |
| `rigor-devise` | Devise authentication |
| `rigor-pundit` | Pundit policies |
| `rigor-sidekiq` | Sidekiq workers |
| `rigor-rspec-rails` | RSpec HTTP status matchers |
| `rigor-shoulda-matchers` | shoulda-matchers |
| `rigor-minitest` | Minitest / Test::Unit |

See [`plugins/README.md`](../../plugins/README.md) for the full
catalogue.

Add the cache directory to `.gitignore`:

```
.rigor/
```

### Step 4 — First run

```sh
rigor check
```

A large initial count is normal for a project that has never
been type-checked.

### Step 5 — Understand the output

`rigor triage` summarises the diagnostic stream instead of
listing every occurrence:

```sh
rigor triage
```

It groups results by rule ID, shows per-file hotspots, and
prints a brief "why" hint for common clusters — for example,
flagging that a large block of `call.undefined-method` errors
likely comes from a missing ActiveSupport core_ext bundle, or
that a gem ships no RBS and `rbs collection install` would help.

Use the triage output to decide where to start: genuine bugs
first, then large clusters to record in a baseline.

> **Rails route diagnostics.** `rigor-rails-routes` checks route
> helpers statically. Most standard Rails patterns are supported,
> but a few produce false-positive `unknown-helper` diagnostics in
> v0.1.x:
>
> - Routes defined only inside `concern :name do ... end` blocks.
>   The concern body is skipped at definition time (to avoid
>   wrong-arity false positives); helpers injected via
>   `concerns: :name` appear as unknown.
> - Routes generated by `devise_for :users` and other engine
>   macros — the parser does not execute Ruby code.
>
> If you see a cluster of `unknown-helper` on routes you know exist,
> acknowledge mode is the right approach — record them in a baseline
> and let the remaining diagnostics surface real issues.

### Step 6 — Generate a baseline (acknowledge mode)

*Skip this step if you chose strict mode.*

```sh
rigor baseline generate
```

This writes `.rigor-baseline.yml` at the project root. Activate
it by uncommenting the `baseline:` line in `.rigor.dist.yml`:

```yaml
baseline: .rigor-baseline.yml
```

With a baseline active, `rigor check` exits clean on the current
codebase and surfaces only diagnostics that appear *after* the
baseline was captured. See [Baselines](06-baseline.md) for the
full baseline workflow.

### Step 7 — Commit

```sh
git add mise.toml .rigor.dist.yml .gitignore
git add .rigor-baseline.yml   # if generated in Step 6
git commit -m "Add Rigor type checker"
```

`mise.toml` pins Ruby 4.0 and Rigor's version for every
contributor — `mise install` on another machine restores the
exact same tools without any project `Gemfile` changes.

---

## What's next

- **CI** — add a standalone Rigor job so pull requests are
  gated automatically: [Running Rigor in CI](11-ci.md).
- **Editor** — inline diagnostics as you type:
  [Editor integration](09-editor-integration.md).
- **Reducing the baseline** — work through the backlog rule by
  rule using the `rigor-baseline-reduce` skill:
  [Baselines](06-baseline.md).
- **Plugins** — each plugin's documentation describes its config
  options in detail: [Using plugins](07-plugins.md) and
  [`plugins/`](../../plugins/README.md).
