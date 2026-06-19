# Rigor Playground — in-browser (ruby.wasm) build

This directory builds the **fully in-browser** Rigor playground described by
[ADR-29](../../../docs/adr/29-browser-playground.md) Option A / WD8 / WD9: a
`ruby.wasm` module with the Rigor engine + `prism` + `rbs` compiled in, served
as a **static asset** (the [try.ruby-lang.org](https://try.ruby-lang.org/playground/)
model). No backend, no per-request server.

The Rack backend in the parent directory (Option B) remains the production
deployment until this build is verified green — see "Status" below.

## What's here

| File | Role |
| --- | --- |
| `Gemfile` | The exact gem set packed into the wasm: `rigortype` (which carries the `rigor-rbs-inline` plugin via `require_paths`) + `rbs-inline`, plus `ruby_wasm` (the `rbwasm` build tool). |
| `Rakefile` | `rake build` / `serve` / `smoke` / `clean`. |
| `vfs/boot.rb` | The in-VM adapter — the wasm analogue of the backend's `app.rb`. Exposes `check` / `annotate` / `annotate-lines` / `type-of` to JS, returning the same WD2 JSON. |
| `vfs/.rigor.yml` | Playground config (loads `rigor-rbs-inline`, `severity_profile: strict`), packed to `/playground` so CLI cwd-discovery finds it. |
| `index.html` | Static frontend. Boots the VM, reuses the CodeMirror UI + JSON contract, swaps `fetch()` for `vm.eval` (WD9). |

## Prerequisites

The wasm toolchain is **not in the project Flake** — it's a separate, heavy
download. You need:

- **Ruby 4.0** on `PATH` (the host ruby; matches the gemspec pin).
- **`bundle install`** in this directory (installs `ruby_wasm` + resolves the path gems).
- **Network access on the first build** — `rbwasm` fetches the wasi-sdk and
  binaryen (hundreds of MB) the first time, then caches them.
- Disk + CPU for a from-source Ruby build (10–40 min cold; `prism`/`rbs` C
  extensions are linked during this step).

## Build & run

```sh
cd plugins/rigor-playground/wasm
bundle install
rake build          # → rigor-playground.wasm
rake serve          # → http://localhost:8000  (open in a browser)
```

`rake smoke` runs the adapter under `wasmtime` (if installed) with no browser —
the WD6 condition ③ check that the engine survives the WASI sandbox:

```sh
rake smoke          # prints the /check JSON for `x = nil; x.upcase`
```

## Why a from-source build (the load-bearing detail)

Rigor's only C-extension runtime dependencies are **`prism`** (CRuby's parser —
already inside the interpreter wasm) and **`rbs`** (a self-contained parser
extension, no external libs à la nokogiri). `rbwasm build` detects the
extension gems in the bundle and switches to building Ruby from source,
statically linking them into one module. That is the **only** route that
satisfies ADR-29 WD6 condition ②; a prebuilt-runtime + pure-ruby-gem pack
cannot carry `rbs`.

## Status — what's verified vs. what gates shipping

**`rake build` succeeds (2026-06-14).** `prism`, `rbs`, and `psych` all link
under `wasi-sdk-24.0` with zero linker errors, producing a **69.9 MB**
`rigor-playground.wasm`. The ADR's binding C-extension risk (`rbs`) is cleared.

The build initially aborted on `psych`: `libyaml` cross-compiled fine
(`LibYAMLProduct` builds `libyaml.a` and `--with-libyaml-dir` points at it),
but in a cross-compiled `--with-static-linked-ext` build `psych`'s `-lyaml`
never reached the final `wasm-ld` link, so every `yaml_*` symbol was undefined.
Fixed by [`build_patches/libyaml_link.rb`](build_patches/libyaml_link.rb),
preloaded into the build via `RUBYOPT`, which forces `libyaml.a` onto the
crossruby `XLDFLAGS` the way `ruby_wasm` already does for wasi-vfs.

**Size note.** 69.9 MB raw is well over the 25 MiB Cloudflare Workers Static
Assets cap — confirming the WD10 decision to host the binary on R2, not as a
static asset. (Compresses to roughly a third over the wire; `--optimize` /
stdlib trimming can shrink it further later.)

**Runtime verified (WD6 ③, 2026-06-14).** `rake smoke` boots the wasm in a
browser-representative VM (`@ruby/wasm-wasi` + `browser_wasi_shim`, writable
`/` preopen) and asserts the sample's diagnostics match the backend — they do,
byte for byte (the `nil.upcase` undefined-method and the inline-RBS
argument-type-mismatch). Four wasm integration fixes made it work and are in
the build / adapter: `gem "js"`, `require "rubygems"` (ruby.wasm runs
rubygems-disabled, which otherwise leaves the RBS type universe empty),
`require "/bundle/setup"` instead of `bundler/setup`, and staging a writable
`/work` for the read-only-FS sandbox.

**Remaining before shipping:**

1. **R2 + CI.** Set up the R2 bucket + secrets and enable the
   `playground-wasm` workflow's publish step.
2. **Docs-site wiring.** The `public/playground/` sync + `<meta>` R2-URL
   injection on `rigor.typedduck.fail`.

### Known v1 limitations / fallbacks

- **POSIX shim.** `vfs/boot.rb` no-ops `File#flock` / `IO#fsync` (absent under
  WASI) so the content-keyed cache works in the in-memory WASI filesystem —
  giving cross-keystroke RBS-environment reuse for free. *Fallback* if a
  `ruby_wasm` version's memfs misbehaves on cache writes (rename/mkdir): make
  the cache a pure no-op instead by neutralising the write path in `boot.rb`:

  ```ruby
  Rigor::Cache::Store.prepend(Module.new { def atomically_replace(*) = nil })
  ```

- **Data packing.** The `rigortype` gemspec lists `data/builtins/**/*.yml` and
  `sig/**/*.rbs` in `spec.files`, so `rbwasm` packs them with the path gem and
  the engine's `__dir__`-relative reads resolve. If a `ruby_wasm` version packs
  only `require_paths`, add explicit maps to the `rbwasm build` call in the
  Rakefile, e.g. `--dir ../../../data::/rigor-data` plus a `RIGOR_DATA_DIR`
  override (verify with `vm.eval('Dir.exist?(...)')`).

- **Main-thread analysis.** `vm.eval` runs synchronously; a slow keystroke
  blocks typing. WD9's responsiveness follow-up moves analysis to a Web Worker
  (paired with WD8's persistent-`Runner` warm env). Until then the page surfaces
  the engine boot non-blockingly: the CodeMirror editor renders and is editable
  immediately (the ruby.wasm glue is a lazy dynamic import, off the editor's
  critical path), while the wasm download (with live progress), VM boot, and
  first analysis are reported in the diagnostics panel + a "Checking…" status —
  no full-screen overlay gating the page.

- **`type-of` hover** is omitted from this v1 page (each hover would trigger a
  blocking full analysis). It returns from `boot.rb` already; add it once the
  Worker offload lands.

## Deploying (ADR-29 WD10)

Target: `https://rigor.typedduck.fail/playground/`, a sub-path of the Astro +
Starlight docs site (Cloudflare Workers Static Assets). The chosen pipeline:

- **Frontend** (`index.html`, ~tens of KB) is served as a **static asset**
  under the site's `public/playground/`, copied from this directory by a
  docs-site sync step (mirroring `sync-rigor-docs`). It runs full-bleed,
  outside the Starlight chrome; a Starlight page links to it.
- **The wasm binary** is built by **`rigor`'s own CI**
  ([`.github/workflows/playground-wasm.yml`](../../../.github/workflows/playground-wasm.yml))
  and published to **Cloudflare R2** — it likely exceeds the 25 MiB
  Workers-Static-Assets per-file cap, and R2 keeps the multi-MB binary out of
  both the per-deploy Astro bundle and git. The build is **version-pinned** to
  the `rigor` commit the site's submodule points at.
- **The page fetches the wasm from R2** via the `<meta name="rigor-wasm-url">`
  tag: empty here (so local `rake serve` uses the relative path), rewritten to
  the R2 URL by the site's sync step. `WebAssembly.compileStreaming` needs
  HTTPS (Cloudflare provides it); a cross-origin R2 URL needs CORS on the
  bucket; the content-hashed wasm is served `immutable`.

For local development, `rake serve` alone is the whole story — the relative
`./rigor-playground.wasm` default needs no R2.
