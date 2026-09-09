# frozen_string_literal: true

# Issue #917 — a class whose loaded RBS declares no `initialize` took its `.new` envelope from
# `BasicObject#initialize: () -> void`, and `call.wrong-arity` read that fallback as a declared nullary
# constructor. Every argument at `Gem::Specification.new("mygem", "1.0.0")` — correct code that runs —
# was reported.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "call.wrong-arity on an undeclared constructor (#917)" do
  def rules_and_messages
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    result = guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib]
    )
    result.diagnostics.map { |d| [d.qualified_rule, d.message] }
  end

  def write_declared_nullary_sig
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "declared.rbs"), <<~RBS)
      class DeclaredNullary
        def initialize: () -> void
      end
    RBS
  end

  around do |example|
    Dir.mktmpdir("rigor-undeclared-ctor-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "declines the undeclared constructor and keeps every declared one firing" do
    # The control arms are not optional. `DeclaredNullary` declares the very envelope the fallback
    # imitates, so a stand-down written over `.new` at large would pass without them; `Object.new` is the
    # one receiver whose `BasicObject`-sourced `initialize` IS its own declaration.
    write_declared_nullary_sig
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "ctor.rb"), <<~RUBY)
      require "rubygems"
      require "tempfile"
      require "stringio"

      class DeclaredNullary
        def initialize; end
      end

      Gem::Specification.new("mygem", "1.0.0")
      Tempfile.new("prefix")
      StringIO.new("body")
      DeclaredNullary.new(1)
      Object.new(1)
    RUBY

    expect(rules_and_messages).to eq(
      [["call.wrong-arity",
        "wrong number of arguments to `new' on DeclaredNullary (given 1, expected 0)"],
       ["call.wrong-arity",
        "wrong number of arguments to `new' on Object (given 1, expected 0)"]]
    )
  end
end
