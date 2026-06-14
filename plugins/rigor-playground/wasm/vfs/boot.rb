# frozen_string_literal: true

# ADR-29 WD8/WD9 — the in-VM adapter packed into the ruby.wasm build.
#
# This is the wasm analogue of plugins/rigor-playground/lib/rigor/playground/app.rb:
# it exposes the same four operations (check / annotate / annotate-lines /
# type-of) but as in-process Ruby callable from JavaScript via `vm.eval`,
# with no Rack, no HTTP, and no network. The frontend (index.html) sets the
# request as a JSON string on a JS global, calls `vm.eval`, and reads the
# returned JSON string back.
#
# Contract fidelity (ADR-29 WD2): every operation routes through
# `Rigor::CLI.start(argv, out:, err:)` against StringIO buffers — byte-for-byte
# the same invocation the backend's `run_cli` uses — so the JSON shapes are
# identical between the server and the browser. Only the bytes' origin differs.

# The nix/wasi runtime can default to US-ASCII; force UTF-8 so File.read and
# JSON handle non-ASCII source. Mirrors app.rb's preamble.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

# ── WASI POSIX shim (ADR-29 WD6 condition ③) ────────────────────────────────
#
# WASI provides no flock(2) and a no-op fsync; the cache write path
# (lib/rigor/cache/store.rb#atomically_replace) calls both. A single-VM
# playground needs no cross-process atomicity, so neutralising these two
# calls lets the existing content-keyed cache operate purely in the in-memory
# WASI filesystem — which is a *feature*: it persists across keystrokes within
# the page session, giving the RBS-environment reuse the WD8 perf note asks
# for, without a bespoke persistent-Runner path. The shim is confined to this
# wasm boot file; the engine is untouched. (Fallback if a ruby_wasm version's
# memfs misbehaves on cache writes: see wasm/README.md — neutralise
# Cache::Store#atomically_replace instead, which forces a pure no-op cache.)
File.class_eval { def flock(*) = 0 }
IO.class_eval   { def fsync(*) = 0 }

# ruby.wasm runs with rubygems disabled (`Gem` is a stub that is never fully
# loaded; `/bundle/setup` only unshifts $LOAD_PATH). Rigor's RBS environment
# loader needs the real rubygems (`Gem::MissingSpecError`, `Gem::Requirement`,
# …), and without it the RBS env builds EMPTY — the analysis then runs with
# zero type information and flags nothing. A single require initialises it.
require "rubygems"
require "json"
require "fileutils"
require "stringio"
require "rigor/cli"

# WASI exposes the packed gem + config tree (/bundle, /playground) READ-ONLY,
# and the host (index.html / smoke.mjs) provides exactly one writable mount at
# /work. Rigor's cache is cwd-relative (`<cwd>/.rigor/`) and the adapter writes
# a per-request buffer file, so both need a writable cwd — stage one under
# /work by copying the read-only config in and chdir-ing there.
WASM_WORK_DIR = "/work"

# `js` only exists in the browser ruby.wasm build. Guard the require so this
# file can also be loaded under a plain wasmtime/WASI smoke run (WD6 ③ CI),
# where the request is read from $stdin instead of a JS global.
begin
  require "js"
  HAS_JS = true
rescue LoadError
  HAS_JS = false
end

module Rigor
  module Playground
    # In-VM request handler. Stateless except for the buffer file it writes
    # under the (packed, writable) working directory.
    module Wasm
      MAX_SOURCE_BYTES = 64 * 1024            # mirrors app.rb
      BUFFER_PATH      = "buffer.rb"          # relative to Dir.pwd (/playground)
      VIRTUAL_LABEL    = "<playground>"

      module_function

      # Browser entry point: read the request JSON from the JS global set by
      # the frontend, dispatch, and return a JSON string. `kind` is one of
      # "check" / "annotate" / "annotate-lines" / "type-of".
      def dispatch(kind)
        req = JSON.parse(JS.global[:rigorRequestJson].to_s)
        run(kind, req)
      rescue StandardError => e
        JSON.generate({ "error" => e.message })
      end

      # Transport-agnostic core. `request` is a Hash with "source" and, for
      # type-of, "line"/"column". Returns a JSON string.
      def run(kind, request)
        source = request.fetch("source", "").to_s
        return too_large if source.bytesize > MAX_SOURCE_BYTES

        case kind
        when "check"          then check(source)
        when "annotate"       then annotate(source)
        when "annotate-lines" then annotate_lines(source)
        when "type-of"        then type_of(source, request["line"].to_i, request["column"].to_i)
        else
          JSON.generate({ "error" => "unknown operation: #{kind}" })
        end
      end

      # ── operations (1:1 with app.rb handlers) ──────────────────────────────

      def check(source)
        path = write_buffer(source)
        data = JSON.parse(run_cli(["check", "--format=json", path]))
        diags = Array(data["diagnostics"]).filter_map do |d|
          next unless d["path"] == path

          d.merge("path" => VIRTUAL_LABEL)
        end
        errors = diags.count { |d| d["severity"] == "error" }
        JSON.generate({ "success" => errors.zero?, "error_count" => errors, "diagnostics" => diags })
      rescue JSON::ParserError
        JSON.generate({ "success" => true, "error_count" => 0, "diagnostics" => [] })
      end

      def annotate(source)
        path = write_buffer(source)
        JSON.generate({ "annotated" => run_cli(["annotate", "--no-color", path]) })
      end

      def annotate_lines(source)
        path = write_buffer(source)
        annotated = run_cli(["annotate", "--no-color", path])
        annotations = {}
        annotated.each_line.with_index(1) do |line, num|
          # `rigor annotate` appends `#=> <type>` to each expression line.
          m = line.match(/#=>\s*(.+?)\s*\z/)
          annotations[num.to_s] = m[1] if m
        end
        JSON.generate({ "annotations" => annotations })
      end

      def type_of(source, line, column)
        path = write_buffer(source)
        out  = run_cli(["type-of", "--format=json", "#{path}:#{line}:#{column}"])
        JSON.generate(JSON.parse(out))
      rescue JSON::ParserError
        JSON.generate({ "error" => "could not resolve type at position" })
      end

      # ── helpers ────────────────────────────────────────────────────────────

      def run_cli(argv)
        out = StringIO.new
        err = StringIO.new
        Rigor::CLI.start(argv, out: out, err: err)
        out.string
      end

      def write_buffer(source)
        File.write(BUFFER_PATH, source.encode("UTF-8", invalid: :replace, undef: :replace))
        BUFFER_PATH
      end

      def too_large
        JSON.generate({ "error" => "Source exceeds 64 KB limit" })
      end
    end
  end
end

# Stage the writable working dir: copy the packed (read-only) .rigor.yml into
# /work and chdir there, so `Rigor::CLI.start`'s cwd-based config discovery
# finds it (loads rigor-rbs-inline, strict severity) and the cwd-relative cache
# + buffer writes land on the writable mount.
FileUtils.mkdir_p(WASM_WORK_DIR)
FileUtils.cp(File.join(File.dirname(__FILE__), ".rigor.yml"), File.join(WASM_WORK_DIR, ".rigor.yml"))
Dir.chdir(WASM_WORK_DIR)

# Plain-WASI smoke path (WD6 ③): `wasmtime … -- /playground/boot.rb <kind>`
# reads the source from stdin and prints the JSON result. No-ops in the
# browser, where dispatch() is driven by JS instead.
if !HAS_JS && $PROGRAM_NAME == __FILE__ && !ARGV.empty?
  kind = ARGV[0]
  puts Rigor::Playground::Wasm.run(kind, { "source" => $stdin.read })
end
