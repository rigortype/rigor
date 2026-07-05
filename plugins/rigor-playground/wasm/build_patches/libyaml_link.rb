# frozen_string_literal: true

# ADR-29 WD8 — psych/libyaml static-link fix for the from-source ruby.wasm build.
#
# Symptom: `rbwasm build` aborts at the final `wasm-ld` step with
#   undefined symbol: yaml_get_version   (and the rest of the yaml_* API)
# even though ruby_wasm builds `libyaml.a` and passes `--with-libyaml-dir` to Ruby's configure. In a
# cross-compiled `--with-static-linked-ext` build, psych's extconf does not propagate `-lyaml` into the final
# static link (the host can't run a wasm link-probe, so the lib never lands on the link line), so the libyaml
# archive is absent and every yaml_* symbol is undefined.
#
# Fix: append the libyaml static archive to the crossruby XLDFLAGS the same way ruby_wasm already does for
# wasi-vfs (`xldflags << @wasi_vfs.lib_wasi_vfs_a`), guaranteeing the symbols are on the final link regardless
# of what psych's Makefile requested. Loaded into the `rbwasm` process via RUBYOPT (see the Rakefile build
# task), so it is active before the build runs and stays confined to this build — ruby_wasm itself is
# untouched.
#
# RUBYOPT `-r` runs at interpreter startup, which can be *before* bundler has put the bundle's gems on the
# load path, so activate the bundle ourselves first (idempotent — a no-op if bundler/setup already ran).
require "bundler/setup"
require "ruby_wasm"

module RigorLibyamlLinkFix
  def configure_args(*)
    if @libyaml
      archive = File.join(@libyaml.install_root, "lib", "libyaml.a")
      @xldflags << archive unless @xldflags.include?(archive)
    end
    super
  end
end

RubyWasm::CrossRubyProduct.prepend(RigorLibyamlLinkFix)
