# Install Rigor — instructions for an AI agent

These instructions are written for an AI coding agent. Follow each
step in order. Run the shell commands exactly as shown. If a step
fails, stop and report the error before continuing.

The goal is to install Rigor and hand off to `rigor skill describe`,
which reports the project's state and routes to the right next-step
skill (`rigor-project-init` for a project that has never run Rigor).
**Do not add Rigor to the project's `Gemfile`** — Rigor is a
standalone tool, not a library.

**Install the latest release, not whatever is already on the
machine.** A `rigor` already on PATH, or a version manager that
resolves to an older release, is not a reason to stop early: Rigor
changes quickly, and the skills this guide hands off to are written
for the current release. Step 1 records the latest version; every
later step compares against it.

---

## Step 1 — Detect the environment

Run these checks and note which tools are available:

```sh
which mise    # preferred — see Step 2A
which asdf    # fallback — see Step 2B
ruby --version 2>/dev/null | head -1   # is Ruby 4.0 already on PATH?
which docker  # last resort — see Step 2D
rigor --version 2>/dev/null            # an existing install, if any
```

Then look up the latest Rigor release on RubyGems and note it as
`LATEST`:

```sh
curl -s https://rubygems.org/api/v1/versions/rigortype/latest.json
# => {"version":"0.4.0"}
```

An existing `rigor` older than `LATEST` still goes through Step 2;
tell the user which version they have and which you are installing.
Then proceed to the **first** matching case below.

---

## Step 2 — Install Ruby 4.0 and Rigor

### Case A — mise is available (recommended)

**What is mise?**
[mise](https://mise.jdx.dev/) is a runtime and tool version manager
— think `rbenv` + `nvm` combined, plus a task runner. It installs
and pins language runtimes (Ruby, Node, Python, …) and tool gems
(like `rigortype`) per project, recording versions in a `mise.toml`
that can be committed alongside the code. Other contributors — and CI
— run `mise install` to restore those versions with no `Gemfile`
involvement.

Run in the project root:

```sh
mise use ruby@4.0
mise use --pin gem:rigortype@LATEST   # substitute the version from Step 1
```

`mise use` installs the tools and writes their versions to `mise.toml`
in one step. Commit `mise.toml` so the version is shared.

Name the version explicitly. A bare `mise use gem:rigortype` does not
reliably mean the newest release: mise's `minimum_release_age` setting
hides releases younger than a set age (it prints `newer gem:rigortype
release hidden by minimum_release_age` as a warning, not an error), so
you get an older Rigor that looks like a clean install. If mise
refuses the explicit version because of a release-age policy, that
policy is the user's supply-chain choice: report both versions and ask
before overriding it.

`--pin` records the exact Rigor version (`"gem:rigortype" = "0.4.0"`).
Without it mise writes `"gem:rigortype" = "latest"`, which every
machine re-resolves to whatever is newest when it first installs — so
a committed `latest` does not give the team one shared version. The
trade-off: a pin will not move on its own, and `mise outdated` cannot
report a pinned tool as behind. Upgrade with `mise upgrade --bump
gem:rigortype`.

Then verify:

```sh
rigor --version
```

If `rigor` is not found, mise may not be wired into your shell yet.
Run one of:

```sh
# Interactive shells (add to ~/.zshrc / ~/.bashrc permanently):
eval "$(mise activate zsh)"   # or bash / fish

# Or use the shims directory directly:
export PATH="$HOME/.local/share/mise/shims:$PATH"
```

Then re-run `rigor --version`. If it still fails, run
`mise exec gem:rigortype -- rigor --version` as a one-off check.

---

### Case B — asdf is available

`asdf` follows the same model as mise but has no gem backend, so the
gem is installed with `gem install` after setting the Ruby version.

```sh
asdf install ruby latest:4.0
asdf local ruby latest:4.0
gem install rigortype -v LATEST   # substitute the version from Step 1
```

Verify:

```sh
rigor --version
```

Note: unlike mise, `gem install` here does not pin the version in a
project config file. Consider switching to mise for per-project
pinning; see <https://mise.jdx.dev/getting-started.html>.

---

### Case C — Ruby 4.0 is already on PATH

If `ruby --version` reports `ruby 4.0.*`, install the gem directly:

```sh
gem install rigortype -v LATEST   # substitute the version from Step 1
```

Verify:

```sh
rigor --version
```

No version is pinned per project with this approach; a version manager
(Case A or B) is better for shared codebases.

---

### Case D — mise is not installed yet (no ruby, no asdf)

Install mise first by following the official getting-started guide:
<https://mise.jdx.dev/getting-started.html>

The one-line script from that page is:

```sh
curl https://mise.run | sh
```

After mise is installed and activated in your shell, come back and
follow **Case A**.

---

### Last resort — Docker

If none of the above is workable in your environment, you can run
Rigor inside a Docker container:

```sh
docker run --rm -v "$(pwd):/app" -w /app ghcr.io/rigortype/rigor:latest rigor check
```

This approach adds overhead from the container filesystem boundary
and does not integrate well with editor LSP. Use it only when a
host-side Ruby 4.0 is genuinely unavailable (for example, Windows
without WSL). For all other environments, prefer Case A–D above.

---

## Step 3 — Verify the installation

```sh
rigor --version
```

The reported version must equal `LATEST` from Step 1. If it is
older, another `rigor` earlier on PATH (a global mise tool, an older
gem) is shadowing the one you just installed: run `which -a rigor`,
and with mise check `mise ls gem:rigortype`. Do not continue on the
older version without telling the user. If the command is not found,
revisit Step 2 for your case.

---

## Step 4 — Ask Rigor what to do next

Now that `rigor` is on your PATH, let it pick the next step for this
project:

```sh
rigor skill describe
```

This reports the project's current state (config / baseline / `sig/` /
CI), recommends the next skill to run with a reason, and lists every
skill with its current description. Follow the `## Recommended next
step` it prints — for a project with no `.rigor.yml` yet that is
`rigor-project-init`:

```sh
rigor skill rigor-project-init
```

`rigor skill <name>` prints the SKILL definition — a header with
file paths followed by the skill body. Follow it from top to bottom.
The project-init skill detects your project's stack, proposes plugins,
writes `.rigor.dist.yml`, and snapshots a baseline if needed; once the
project is set up, re-run `rigor skill describe` for the step after
that.

If `rigor skill describe` is not recognised, your Rigor version predates
it. Run `rigor --version` and upgrade with `mise upgrade --bump
gem:rigortype` (or `gem update rigortype` for Case B/C); on an older
version, run `rigor skill rigor-project-init` directly.
