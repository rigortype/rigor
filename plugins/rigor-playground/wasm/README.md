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

This scaffolding is **"ready to build", not "shipping"**. The blocking
unknown is whether `rbs`'s C extension links cleanly under the wasi-sdk — the
WD6 ② spike. To resolve it:

1. `rake build`. If it completes, `prism` + `rbs` link → **WD6 ② green**.
2. `rake smoke` (or open the page). Confirm the sample's diagnostics match the
   backend's for the same input → **contract fidelity** (WD2).
3. Wire a CI job that runs the adapter under `wasmtime` on a fixed corpus →
   **WD6 ③**.

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
  (paired with WD8's persistent-`Runner` warm env). v1 surfaces a boot overlay
  and a "Checking…" status instead.

- **`type-of` hover** is omitted from this v1 page (each hover would trigger a
  blocking full analysis). It returns from `boot.rb` already; add it once the
  Worker offload lands.

## Deploying

`index.html` + `rigor-playground.wasm` are static files. Upload both to any
static host (Cloudflare Pages, GitHub Pages, Netlify). Serve `.wasm` as
`application/wasm`. No COOP/COEP headers are required for the single-threaded
VM. This is the deployment ADR-29 WD6 unlocks once the build is verified.
