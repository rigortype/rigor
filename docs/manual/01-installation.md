# Installing Rigor

Rigor is a tool, not a library. Like a linter or a compiler, it
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

> **Using an AI coding agent?** It can install Rigor and configure
> the project for you — hand it this prompt:
>
> ```
> Install Rigor in this project by following the instructions at
> https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
> ```
>
> The agent detects your environment (mise / asdf / plain Ruby),
> installs the right tools, and hands off to the
> `rigor-project-init` skill (see Path A of the
> [Rails quickstart](14-rails-quickstart.md)). The channels below
> are the manual route.

### Set up in your language

The prompt above is plain natural language — your agent follows the
same linked instructions regardless of the language you ask in, so
the whole setup conversation can happen in your mother tongue. Each
ready-made prompt below explicitly asks the agent to work through the
setup interactively with you in that language:

<details data-lang-details>
<summary>Set up in your language</summary>

<details lang="ja"><summary>[ja] 日本語</summary>

```
日本語で対話しながら、このプロジェクトに Rigor をインストールする作業を一緒に進めてください。次の手順に従ってください:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="zh-Hans"><summary>[zh-Hans] 简体中文</summary>

```
请用简体中文与我互动，在此项目中安装 Rigor。请按照以下地址的说明操作:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="zh-Hant"><summary>[zh-Hant] 繁體中文</summary>

```
請用繁體中文與我互動，在此專案中安裝 Rigor。請依照以下網址的說明操作:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="ko"><summary>[ko] 한국어</summary>

```
한국어로 대화하면서 이 프로젝트에 Rigor를 설치하는 작업을 함께 진행해 주세요. 다음 주소의 안내를 따라 주세요:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="pt-BR"><summary>[pt-BR] Português (Brasil)</summary>

```
Vamos trabalhar juntos de forma interativa, em português brasileiro, para instalar o Rigor neste projeto. Siga as instruções em:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="pt"><summary>[pt] Português</summary>

```
Vamos trabalhar juntos de forma interativa, em português de Portugal, para instalar o Rigor neste projeto. Segue as instruções em:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="es"><summary>[es] Español</summary>

```
Trabajemos juntos de forma interactiva, en español, para instalar Rigor en este proyecto. Sigue las instrucciones en:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="vi"><summary>[vi] Tiếng Việt</summary>

```
Hãy trao đổi với tôi bằng tiếng Việt và cùng nhau cài đặt Rigor vào dự án này. Làm theo hướng dẫn tại:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="fr"><summary>[fr] Français</summary>

```
Travaillons ensemble de manière interactive, en français, pour installer Rigor dans ce projet. Suivez les instructions à l'adresse :
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="de"><summary>[de] Deutsch</summary>

```
Lassen Sie uns interaktiv auf Deutsch zusammenarbeiten, um Rigor in diesem Projekt zu installieren. Folgen Sie den Anweisungen unter diesem Link:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="it"><summary>[it] Italiano</summary>

```
Lavoriamo insieme in modo interattivo, in italiano, per installare Rigor in questo progetto. Segui le istruzioni a questo link:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="th"><summary>[th] ภาษาไทย</summary>

```
มาทำงานร่วมกันแบบโต้ตอบเป็นภาษาไทย เพื่อติดตั้ง Rigor ในโปรเจกต์นี้ โปรดทำตามคำแนะนำที่ลิงก์ต่อไปนี้:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="id"><summary>[id] Bahasa Indonesia</summary>

```
Mari bekerja sama secara interaktif dalam bahasa Indonesia untuk memasang Rigor pada proyek ini. Ikuti instruksi pada tautan berikut:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="pl"><summary>[pl] Polski</summary>

```
Pracujmy razem po polsku, w trybie interaktywnym, aby zainstalować Rigor w tym projekcie. Postępuj zgodnie z instrukcjami pod adresem:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="uk"><summary>[uk] Українська</summary>

```
Працюймо разом українською мовою в інтерактивному режимі, щоб встановити Rigor у цьому проєкті. Дотримуйтеся інструкцій за посиланням:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="ru"><summary>[ru] Русский</summary>

```
Давайте работать вместе в интерактивном режиме на русском языке, чтобы установить Rigor в этом проекте. Следуйте инструкциям по ссылке:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="ro"><summary>[ro] Română</summary>

```
Haideți să lucrăm împreună în mod interactiv, în limba română, pentru a instala Rigor în acest proiect. Urmați instrucțiunile de la adresa:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="tr"><summary>[tr] Türkçe</summary>

```
Türkçe iletişim kurarak bu projeye Rigor'u birlikte kuralım. Şu adresteki talimatları izleyin:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="ar" dir="rtl"><summary>[ar] العربية</summary>

```
لنعمل معًا بشكل تفاعلي وباللغة العربية لتثبيت Rigor في هذا المشروع. اتبع التعليمات الموجودة في:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

<details lang="fa" dir="rtl"><summary>[fa] فارسی</summary>

```
بیایید به‌صورت تعاملی و به زبان فارسی با هم کار کنیم تا Rigor را در این پروژه نصب کنیم. دستورالعمل‌های موجود در این آدرس را دنبال کنید:
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

</details>

</details>

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
- **Commit the config to share versions — and pass `--pin` if you
  mean it.** Check the generated `mise.toml` into Git so every
  contributor, and every CI run, resolves the same versions. Note
  what the two commands above actually record, because they differ:
  `mise use ruby@4.0` preserves the precision you asked for and
  writes `ruby = "4.0"` (any 4.0.x), but `mise use gem:rigortype` has
  no requested version to preserve and writes `"gem:rigortype" =
  "latest"` — which resolves to whatever is newest *on each machine,
  whenever that machine first installs it*. A committed `latest` is
  not a shared version. To share one, pin it:

  ```sh
  mise use --pin gem:rigortype     # records e.g. "gem:rigortype" = "0.2.9"
  ```

  Then read [Keeping Rigor up to date](#keeping-rigor-up-to-date):
  a pin is a version that will not move until you move it.
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

### Keeping Rigor up to date

Rigor ships often. How you upgrade depends on what your config
records — and in one case, on knowing that mise will not tell you an
upgrade exists.

- **`"gem:rigortype" = "latest"`** — what a plain `mise use
  gem:rigortype` writes. `mise upgrade gem:rigortype` moves you to the
  newest release.
- **An exact pin** — `"gem:rigortype" = "0.2.9"`, from `--pin` or from
  `mise use gem:rigortype@0.2.9`. Here `mise upgrade` **will not move
  it, and `mise outdated` will not report it.** Both compare the
  installed version against the range the config asks for, and an
  exact pin is a range containing only itself, so a pinned Rigor
  reports itself up to date forever, however far behind it has fallen.
  Use `--bump`, which installs the newest release *and* rewrites the
  pin:

  ```sh
  mise upgrade --bump gem:rigortype
  ```

Neither is a bug to work around — a pin doing nothing is a pin working.
But it does mean a pinned setup has no passive signal that a new Rigor
exists: `--bump` is both how you look and how you move.

**After a Ruby change.** mise's `gem:` backend installs each tool
against the Ruby that was active at install time, and its
[gem backend docs](https://mise.jdx.dev/dev-tools/backends/gem.html)
note that "if the ruby version used by a gem package changes, (by mise
or system ruby), you may need to reinstall the gem". Rigor's pinned
`ruby@4.0` makes this rare — patch upgrades within 4.0.x are followed
automatically — but if you remove or replace that Ruby, reinstall:

```sh
mise install -f gem:rigortype     # or, for every gem-backend tool:
mise install -f "gem:*"
```

On a plain `gem install` (below), the equivalent is `gem update
rigortype`.

## asdf

`asdf` follows the same model. Install a Ruby 4.0.x with the
[`asdf-ruby`](https://github.com/asdf-vm/asdf-ruby) plugin, select
it for the project, then install the gem into that Ruby:

```sh
asdf plugin add ruby        # once, if the ruby plugin isn't added yet
asdf install ruby latest:4.0
asdf local ruby latest:4.0
gem install rigortype
```

`asdf` has no general-purpose gem backend, so the gem itself is
installed with `gem install` rather than an `asdf` command. `mise`
(above) is the more integrated option because its `gem:` backend
records the gem in the same config that records Ruby, and — as the
next section explains — keeps the two from interfering.

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

It also leaves Rigor sharing a Ruby with your work, which is the
deeper reason the version managers are listed first. The executable
RubyGems installs begins with `#!/usr/bin/env ruby`, so it runs under
whatever `ruby` is first on `PATH` *at the moment you invoke it* — and
because Rigor requires Ruby 4.0 while your projects pin their own,
running `rigor` inside a project on Ruby 3.x fails before it starts.
mise's `gem:` backend does not have this failure mode: it installs each
tool into its own private gem directory and points the executable at
the Ruby the tool was installed with, so a project's Ruby pin cannot
reach it. A `gem install` under a Ruby 4.0 you never switch away from
is perfectly fine; one that shares a Ruby with projects you switch
between is a footgun.

## If you want Bundler to manage the version

The rule at the top of this chapter is about your *application's*
`Gemfile` — the one Bundler resolves against your app's gems, and whose
entries `Bundler.require` loads at boot. It is not a rule against
Bundler. A `Gemfile` holding nothing but Rigor, resolved separately and
selected with `BUNDLE_GEMFILE`, keeps every property the prohibition
exists to protect: your application's dependency graph never meets
Rigor's, and your application's Ruby is never constrained by Rigor's.

That arrangement — a `Gemfile` under `.github/rigor/`, plus the
Dependabot config that keeps it current — is written up under
[Pinning Rigor's version](11-ci.md#pinning-rigors-version) in the CI
chapter. Nothing about it is CI-specific:

```sh
BUNDLE_GEMFILE=.github/rigor/Gemfile bundle exec rigor check
```

It is more moving parts than `mise use --pin gem:rigortype`, which
records the same version in one line and needs no `bundle exec`. Reach
for it when your team already runs everything through Bundler and wants
Rigor on the same footing — not as a first choice.

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
