# Install Rigor — instructions for an AI agent

These instructions are written for an AI coding agent. Follow each
step in order. Run the shell commands exactly as shown. If a step
fails, stop and report the error before continuing.

The goal is to install Rigor and hand off to the project-init skill.
**Do not add Rigor to the project's `Gemfile`** — Rigor is a
standalone tool, not a library.

---

## Step 1 — Detect the environment

Run these four checks and note which tools are available:

```sh
which mise    # preferred — see Step 2A
which asdf    # fallback — see Step 2B
ruby --version 2>/dev/null | head -1   # is Ruby 4.0 already on PATH?
which docker  # last resort — see Step 2D
```

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
— run `mise install` to restore the exact same versions with no
`Gemfile` involvement.

Run in the project root:

```sh
mise use ruby@4.0
mise use gem:rigortype
```

`mise use` installs the tools and writes their versions to `mise.toml`
in one step. Commit `mise.toml` so the version is shared.

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
gem install rigortype
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
gem install rigortype
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

A version string like `rigor 0.1.x` confirms a successful install.
If the command is not found, revisit Step 2 for your case.

---

## Step 4 — Set up Rigor in this project

Now that `rigor` is on your PATH, run the project-init skill:

```sh
rigor skill print rigor-project-init
```

This prints the SKILL definition — a header with file paths followed
by the skill body. Follow the printed instructions from top to
bottom. The skill detects your project's stack, proposes plugins,
writes `.rigor.dist.yml`, and snapshots a baseline if needed.

If the skill command is not recognised, your Rigor version may be
older than 0.1.9. Run `rigor --version` and upgrade with
`mise use gem:rigortype` (or `gem update rigortype` for Case C/B).
