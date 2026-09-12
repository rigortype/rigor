# frozen_string_literal: true

# Issue #991 — `call.wrong-arity` bailed on `scope.discovered_method?(class_name, call_node.name, kind)`
# before it ever asked for a declaration, so a project `def` bought the method a blanket exemption from
# arity checking, EVEN WHEN a `sig/` entry or an inline `# @rbs` / `#:` annotation (ADR-93) gave the method
# a real, trustworthy signature. `call.argument-type-mismatch` already made the opposite call on the same
# `trustworthy_signature` lookup: the two rules must agree on whose contract binds.
#
# The `sig/` and inline-annotation arms below are the two ways a project method acquires a trustworthy
# signature (acceptance criteria 1 and 2); the no-declaration arm is the unchanged control (criterion 3).

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "call.wrong-arity on a source-defined method with a trustworthy signature (#991)" do
  # The same three call shapes drive every arm: zero args (arity), two args (arity), and a `String`
  # (type) — against a project `def f(num)` whose declared contract is always `(Float) -> Float`.
  def calls
    <<~RUBY
      Foo.new.f
      Foo.new.f(1.0, 2.0)
      Foo.new.f("x")
    RUBY
  end

  def def_f
    <<~RUBY
      class Foo
        def f(num)
          num
        end
      end
    RUBY
  end

  def write_project(source)
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "arity.rb"), source)
  end

  def rules_and_messages(configuration, plugin_requirer: nil)
    result = guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil, plugin_requirer: plugin_requirer),
      %w[lib]
    )
    result.diagnostics.map { |d| [d.qualified_rule, d.message] }
  end

  # Shared by the two declared-signature arms: both give `Foo#f` the exact same `(Float) -> Float`
  # contract, one through `sig/`, one through an inline annotation, so both must produce identical
  # diagnostics against the shared `calls`.
  def expected_diagnostics
    [["call.wrong-arity", "wrong number of arguments to `f' on Foo (given 0, expected 1)"],
     ["call.wrong-arity", "wrong number of arguments to `f' on Foo (given 2, expected 1)"],
     ["call.argument-type-mismatch",
      "argument type mismatch at parameter `num' of `f' on Foo: expected Float, got \"x\""]]
  end

  # Requires and registers the bundled `rigor-rbs-inline` plugin from source, and returns the
  # `plugin_requirer:` lambda `Runner.new` needs to load it — mirrors `spec/rigor/cli_spec.rb`'s
  # `--treat-all-as-inline-rbs` setup, which does the same `$LOAD_PATH` + `require` + explicit
  # re-registration dance because `Configuration.new` (unlike `.load`) never auto-wires the plugin.
  def require_rbs_inline_plugin
    plugin_lib = File.expand_path("../../plugins/rigor-rbs-inline/lib", __dir__)
    $LOAD_PATH.unshift(plugin_lib) unless $LOAD_PATH.include?(plugin_lib)
    require "rigor-rbs-inline"
    Rigor::Plugin.unregister!
    lambda do |_name|
      Rigor::Plugin.register(Rigor::Plugin::RbsInline)
      true
    end
  end

  around do |example|
    Dir.mktmpdir("rigor-arity-declared-source-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "fires on a sig/-declared method the project also defines in source" do
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "foo.rbs"), <<~RBS)
      class Foo
        def f: (Float num) -> Float
      end
    RBS
    write_project("#{def_f}\n#{calls}")

    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
    expect(rules_and_messages(configuration)).to eq(expected_diagnostics)
  end

  it "fires on an inline `# @rbs`-declared method the project also defines in source (ADR-93)" do
    plugin_requirer = require_rbs_inline_plugin
    write_project(<<~RUBY)
      class Foo
        # @rbs num: Float
        # @rbs return: Float
        def f(num)
          num
        end
      end

      #{calls}
    RUBY

    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => %w[lib], "workers" => 0,
        "plugins" => [{ "gem" => "rigor-rbs-inline", "id" => "rbs-inline",
                        "config" => { "require_magic_comment" => false } }]
      )
    )
    diagnostics = rules_and_messages(configuration, plugin_requirer: plugin_requirer)
    expect(diagnostics).to eq(expected_diagnostics)
  ensure
    Rigor::Plugin.unregister!
  end

  it "stays silent on the same call shapes when the method carries no declaration at all (control)" do
    write_project("#{def_f}\n#{calls}")

    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    expect(rules_and_messages(configuration)).to be_empty
  end
end
