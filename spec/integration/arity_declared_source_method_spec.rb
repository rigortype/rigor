# frozen_string_literal: true

# Issue #991 — `call.wrong-arity` bailed on `scope.discovered_method?(class_name, call_node.name, kind)`
# before it ever asked for a declaration, so a project `def` bought the method a blanket exemption from
# arity checking, EVEN WHEN a `sig/` entry or an inline `# @rbs` / `#:` annotation (ADR-93) gave the method
# a real, trustworthy signature. `call.argument-type-mismatch` already made the opposite call on the same
# `trustworthy_signature` lookup: the two rules must agree on whose contract binds.
#
# The `sig/` and inline-annotation arms below are the two ways a project method acquires a trustworthy
# signature (acceptance criteria 1 and 2); the no-declaration arm is the unchanged control (criterion 3).
#
# Issue #992 — the no-declaration arm above builds its fixture with `Configuration.new` and no
# `plugin_requirer:`, so `rigor-rbs-inline` never loads and `Foo#f` resolves no signature at all: the
# arm proves nothing about a NORMAL project, where ADR-93 auto-wires the plugin by default. Under that
# default, a file carrying ONE annotation gets a full `(untyped, …) -> untyped` skeleton synthesized for
# EVERY `def` in it (#823), so a sibling method with no declaration of its own still resolves a
# `method_def` — one `wrong_arity_diagnostic` must not trust, or whether an undeclared method gets
# arity-checked would depend on an unrelated annotation elsewhere in its file. The regression arm below
# exercises the plugin for real and checks exactly that: a declared `Foo#f` fires per usual, alongside an
# undeclared `Bar#g` in the SAME file that must stay silent.
#
# The case #991 was actually filed for is narrower still, and needed its own fact rather than reusing
# `rigor:v1:inferred-return`: an author who writes `# @rbs num: Float` and nothing else has made an
# assertion about the parameter list, even though the return — nothing about it was written — still
# defaults, and defaulting the return is the ONLY provenance `inferred-return?` can see. Gating
# `wrong_arity_diagnostic` on that directive silenced this exact case, indistinguishable from a fully
# bare `def`. `rigor:v1:inferred-signature` (present only when EVERY type slot on the member defaulted,
# not only the return) is what the rule reads instead — see the "param annotated, return left to the
# synthesizer" arm below, which is the issue's own repro.

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

  # The issue's own repro: `# @rbs num: Float` and nothing else. The parameter is authored; the return
  # is not, and `rigor-rbs-inline` defaults it exactly as it would for a fully bare `def`. Only
  # `rigor:v1:inferred-signature` — present when EVERY type slot defaulted — tells the two apart;
  # `rigor:v1:inferred-return` alone cannot, since it is present on both.
  it "fires on an inline `# @rbs`-declared method whose PARAMETER is authored and whose return is " \
     "left to the synthesizer (#991)" do
    plugin_requirer = require_rbs_inline_plugin
    write_project(<<~RUBY)
      class Foo
        # @rbs num: Float
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

  # An author-written `#: (String) -> untyped` return is a real, authored contract — not the
  # synthesizer's defaulted placeholder — even though both render as `untyped`. `defaulted_type?` in the
  # plugin tells them apart by construction (the placeholder is a distinctive alias, scrubbed to
  # `untyped` only after the provenance check), so this member carries neither `inferred-return` nor
  # `inferred-signature` and the rule must witness normally.
  it "fires on a method whose author wrote an explicit `#: (String) -> untyped` full signature" do
    plugin_requirer = require_rbs_inline_plugin
    write_project(<<~RUBY)
      class Baz
        #: (String) -> untyped
        def h(s)
          s
        end
      end

      Baz.new.h
      Baz.new.h(1, 2)
    RUBY

    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => %w[lib], "workers" => 0,
        "plugins" => [{ "gem" => "rigor-rbs-inline", "id" => "rbs-inline",
                        "config" => { "require_magic_comment" => false } }]
      )
    )
    diagnostics = rules_and_messages(configuration, plugin_requirer: plugin_requirer)
    expect(diagnostics).to eq(
      [["call.wrong-arity", "wrong number of arguments to `h' on Baz (given 0, expected 1)"],
       ["call.wrong-arity", "wrong number of arguments to `h' on Baz (given 2, expected 1)"],
       ["call.argument-type-mismatch", "argument type mismatch at `h' on Baz: expected String, got 1"]]
    )
  ensure
    Rigor::Plugin.unregister!
  end

  # A mixin reached through an annotated file: `Helper#helper` carries no annotation of its own, only
  # `Foo#f` (elsewhere in the same file) does, which is what pulls the plugin's file-wide skeleton in.
  # `C` never defines `helper` itself, so the only signature `wrong_arity_diagnostic` can resolve for
  # `C.new.helper` is the fully-defaulted one synthesized for `Helper#helper` — which must decline the
  # same way an unannotated same-class method does.
  def mixin_project
    <<~RUBY
      class Foo
        # @rbs num: Float
        # @rbs return: Float
        def f(num)
          num
        end
      end

      module Helper
        def helper(a)
          a
        end
      end

      class C
        include Helper
      end

      #{calls}
      C.new.helper
      C.new.helper(1, 2)
    RUBY
  end

  it "stays silent on a mixin method reached through a file the inline plugin annotates for an " \
     "unrelated class (#992 regression)" do
    plugin_requirer = require_rbs_inline_plugin
    write_project(mixin_project)

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

  # `Bar#g` carries no declaration of its own; only `Foo#f`'s inline annotation makes the file
  # "annotated" and pulls the plugin in. `expected_diagnostics` names only `Foo#f`, so `Bar#g`'s two
  # calls proving silent is exactly `diagnostics == expected_diagnostics`, not a separate assertion.
  def undeclared_sibling_project
    <<~RUBY
      class Foo
        # @rbs num: Float
        # @rbs return: Float
        def f(num)
          num
        end
      end

      class Bar
        def g(x)
          x
        end
      end

      #{calls}
      Bar.new.g
      Bar.new.g(1, 2)
    RUBY
  end

  it "stays silent on an undeclared sibling method even though the inline plugin annotates " \
     "another method in the same file (#992 regression)" do
    plugin_requirer = require_rbs_inline_plugin
    write_project(undeclared_sibling_project)

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
end
