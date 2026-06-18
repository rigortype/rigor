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
