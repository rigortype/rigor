# Installing Rigor

Rigor is a tool, not a library — like a linter or a compiler, it
analyses your project but is not part of its runtime. **Do not add
it to your application's `Gemfile`.** A `Gemfile` entry would tie
your whole project to Rigor's Ruby version and pull Rigor's
dependencies into your application's dependency resolution. Install
Rigor on its own and point it at your project.

Rigor runs on Ruby 4.0. That is independent of the Ruby your own
code targets: the `target_ruby:` config key tells Rigor which Ruby
*your* project runs, and the two need not match. Rigor reads your
project — its source, its `Gemfile.lock`, its gems' `.rbs` files —
as data; it never loads your project's gems into its own process,
so nothing is lost by installing it separately.

## Recommended — a runtime version manager

[`mise`](https://mise.jdx.dev/) is a runtime / tool version manager
(think `rbenv` + `nvm` plus a package runner in one). It installs
Ruby 4.0 and Rigor together and pins them per project, with no
`Gemfile` involvement.

### New to mise?

After [installing mise itself](https://mise.jdx.dev/getting-started.html),
two commands set Rigor up:

```sh
mise use ruby@4.0
mise use gem:rigortype
```

A few things worth knowing if you have not used mise before:

- **`mise use` is project-level.** It writes a `mise.toml` in the
  *current directory* recording the chosen versions, and installs
  the tools as part of the same command — there is no separate
  install step. (mise also reads the asdf-style `.tool-versions`.)
- **Commit the config to share versions.** Check the generated
  `mise.toml` into Git so every contributor — and every CI run —
  resolves the same Ruby 4.0 and the same Rigor version.
- **For a machine-wide install, add `-g`.** `mise use -g
  gem:rigortype` writes mise's global config
  (`~/.config/mise/config.toml`) instead of a project `mise.toml`,
  making `rigor` available in every directory.

The gem is `rigortype`; the executable it installs (and the only
command you run) is `rigor`.

### Putting `rigor` on your PATH

Installing the tool is not enough on its own — `rigor` reaches your
`PATH` only once mise is wired into your environment, and this holds
for both project-level and global installs. mise's
[shims guide](https://mise.jdx.dev/dev-tools/shims.html) explains
the two mechanisms:

- **`mise activate`** — add `eval "$(mise activate zsh)"` to your
  shell rc (`~/.zshrc`; bash and fish equivalents are in
  [mise's docs](https://mise.jdx.dev/getting-started.html)).
  `cd`-ing into the project then puts `rigor` on `PATH`. Best for
  interactive shells.
- **shims** — fixed executables under `~/.local/share/mise/shims`.
  Add that directory to `PATH`:

  ```sh
  export PATH="$HOME/.local/share/mise/shims:$PATH"
  ```

  or run `mise activate <shell> --shims`. Shims work where the `cd`
  hook never fires — editors launching `rigor lsp`, scripts, some
  CI. mise creates the `rigor` shim automatically on install.

Until mise is wired in either way, you can still run Rigor
explicitly with `mise exec gem:rigortype -- rigor`. See
[Editor integration](09-editor-integration.md) for the editor
side.

## asdf

`asdf` follows the same model. Install a Ruby 4.0.x with the
[`asdf-ruby`](https://github.com/asdf-vm/asdf-ruby) plugin, select
it for the project, then install the gem into that Ruby:

```sh
asdf install ruby latest:4.0
asdf local ruby latest:4.0
gem install rigortype
```

`asdf` has no general-purpose gem backend, so the gem itself is
installed with `gem install` rather than an `asdf` command. `mise`
(above) is the more integrated option because its `gem:` backend
pins the gem the same way it pins Ruby.

## Simple alternative — gem install

If you already have a Ruby 4.0 on your `PATH`:

```sh
gem install rigortype
```

The gem is named `rigortype` — `rigor` was already taken on
RubyGems — and the executable it installs is `rigor`. This is the
quickest path, but it records nothing per project: a version
manager keeps the Rigor version pinned next to the project, so
local runs and CI cannot drift apart.

## Nix

If you use Nix, Rigor's flake exposes the executable as a package,
with Ruby 4.0 in its closure — nothing else need be on the host:

```sh
# Run without installing:
nix run github:rigortype/rigor#rigor -- check

# Or install it into your profile:
nix profile install github:rigortype/rigor
```

## Developing inside a container

If you develop inside a dev container, install Rigor on the **host
OS** rather than inside the container — running the analyser across
the container's filesystem and process boundary adds overhead. On
Windows, where a host-side Ruby 4.0 is harder to provide, installing
Rigor inside the container is the better choice.

## Continuous integration

Wiring Rigor into CI has its own chapter — see
[Running Rigor in CI](11-ci.md).
