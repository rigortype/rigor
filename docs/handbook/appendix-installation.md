# Appendix — Installing Rigor

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

[`mise`](https://mise.jdx.dev/) installs both Ruby 4.0 and Rigor and
pins them per project, with no `Gemfile` involvement:

```sh
mise use ruby@4.0
mise use gem:rigortype
```

This writes a `mise.toml` — commit it so every contributor and CI
run uses the same versions. The gem is `rigortype`; the executable
it installs (and the only command you run) is `rigor`.

### Putting `rigor` on your PATH

`mise use` installs the tool, but `rigor` only lands on your `PATH`
once mise is **activated** in your shell. Activation is a one-time
step from mise's own setup — for example, in `~/.zshrc`:

```sh
eval "$(mise activate zsh)"
```

(bash and fish are covered in
[mise's docs](https://mise.jdx.dev/getting-started.html).) With mise
activated, `cd`-ing into the project puts `rigor` on `PATH`. Until
then you can still run it explicitly with
`mise exec gem:rigortype -- rigor`.

For `rigor` to be found **outside an interactive shell** — most
importantly so an editor can launch `rigor lsp` — enable mise
**shims**. Shims are fixed executables that work where the `cd`
activation hook never fires (editors, scripts, some CI). Either add
the shims directory to `PATH`:

```sh
export PATH="$HOME/.local/share/mise/shims:$PATH"
```

or configure your shell with `mise activate <shell> --shims`. mise
creates the `rigor` shim automatically on install. See
[`docs/lsp-integration.md`](../lsp-integration.md) for the editor
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

Wiring Rigor into CI has its own appendix — see
[Appendix — Running Rigor in CI](appendix-ci.md).
