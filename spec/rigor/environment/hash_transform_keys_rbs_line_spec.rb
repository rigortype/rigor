# frozen_string_literal: true

# `Hash#transform_keys(replacements)` and `#transform_keys!(replacements)` on either `rbs` line.
#
# rbs 4.0 declares the replacements-hash overloads Ruby 3.0 added; no rbs 3.x release does. Under 3.x a
# correct `h.transform_keys({ a: :z })` therefore reported `call.wrong-arity` ("given 1, expected 0"), and
# `transform_keys!` answered `Enumerator`. `data/core_overlay/hash_rbs3.rbs` supplies rbs 4.2's overloads,
# loaded on the 3.x line only.
#
# This file lives under `spec/rigor/environment` because that is what CI's "RBS compatibility (RBS 3.x)"
# job runs. The pinned development bundle is rbs 4.x, so on a plain `make verify` only the 4.x arm runs.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "Hash#transform_keys replacements overloads across rbs lines" do
  let(:loader) { Rigor::Environment::RbsLoader.new(libraries: []) }

  def hash_method(name)
    loader.instance_method(class_name: "Hash", method_name: name)
  end

  def overlay_sources(method)
    method.defs.map { |definition| File.basename(definition.member.location.buffer.name.to_s) }
  end

  it "declares a one-positional transform_keys overload, with and without a block" do
    one_positional = hash_method(:transform_keys).method_types.select do |method_type|
      method_type.type.required_positionals.size == 1
    end

    expect(one_positional.map { |method_type| method_type.block.nil? }).to contain_exactly(true, false)
  end

  it "answers self from the one-positional transform_keys! overload" do
    one_positional = hash_method(:transform_keys!).method_types.select do |method_type|
      method_type.type.required_positionals.size == 1
    end

    expect(one_positional).not_to be_empty
    expect(one_positional.map { |method_type| method_type.type.return_type.to_s }).to all(eq("self"))
  end

  # An `| ...` continuation with no base declaration raises `InvalidOverloadMethodError` and degrades all of
  # `Hash` to `Dynamic[top]`, where every call, the surplus-argument control included, reports nothing.
  it "leaves Hash's definition buildable" do
    expect(loader.instance_definition("Hash")).not_to be_nil
  end

  rbs3 = Gem::Version.new(RBS::VERSION) < Gem::Version.new("4.0")

  it "loads the rbs 3.x overlay on the rbs 3.x line", if: rbs3 do
    expect(overlay_sources(hash_method(:transform_keys))).to include("hash_rbs3.rbs")
    expect(overlay_sources(hash_method(:transform_keys!))).to include("hash_rbs3.rbs")
  end

  # On 4.x the `| ...` continuation would prepend a second copy of the overloads upstream declares.
  it "leaves the rbs 4.x declarations to rbs core", unless: rbs3 do
    expect(overlay_sources(hash_method(:transform_keys))).not_to include("hash_rbs3.rbs")
    expect(overlay_sources(hash_method(:transform_keys!))).not_to include("hash_rbs3.rbs")
  end

  describe "call.wrong-arity" do
    around do |example|
      Dir.mktmpdir("rigor-transform-keys-rbs-line-") { |dir| Dir.chdir(dir) { example.run } }
    end

    def arity_lines(source)
      FileUtils.mkdir_p("lib")
      File.write(File.join("lib", "keys.rb"), source)
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
      )
      result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
      result.diagnostics.select { |d| d.qualified_rule == "call.wrong-arity" }.map(&:line)
    end

    # The two-argument control keeps a blanket arity stand-down on `transform_keys` from passing. The
    # zero-argument and block-only lines guard rbs 3.x's own overloads, which the overlay's precede.
    it "accepts a replacements hash and still reports a surplus argument" do
      lines = arity_lines(<<~RUBY)
        h = { a: 1, b: 2 }
        h.transform_keys({ a: :z })
        h.transform_keys({ a: :z }) { |k| k.to_s }
        h.transform_keys!({ a: :z })
        h.transform_keys!({ a: :z }) { |k| k }
        h.transform_keys
        h.transform_keys { |k| k.to_s }
        h.transform_keys!
        h.transform_keys! { |k| k }
        h.transform_keys({ a: :z }, 2)
      RUBY

      expect(lines).to eq([10])
    end
  end
end
