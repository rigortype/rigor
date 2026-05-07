# frozen_string_literal: true

# Integration spec for `examples/rigor-lisp-eval/`. Loads the
# example plugin source, drives a real `Analysis::Runner` over
# the demo, and asserts the diagnostics the plugin emits per
# call site. Treat the spec as the executable contract for the
# README's "What the plugin recognises" section.
#
# Boilerplate (`run_plugin`, `plugin_diagnostics`, requirer) is
# in `spec/integration/examples/support/plugin_helpers.rb`.
# Auto-included for every `*_plugin_spec.rb` file under this
# directory.

require "spec_helper"

PLUGIN_LIB = File.expand_path("../../../examples/rigor-lisp-eval/lib", __dir__)
$LOAD_PATH.unshift(PLUGIN_LIB) unless $LOAD_PATH.include?(PLUGIN_LIB)
require "rigor-lisp-eval"

RSpec.describe "examples/rigor-lisp-eval" do # rubocop:disable RSpec/DescribeClass
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::LispEval }

  it "infers Integer for pure integer arithmetic" do
    result = run_plugin(source: "Lisp.eval([:+, 1, [:*, 2, 3]])\n")
    diags = plugin_diagnostics(result)
    expect(diags.size).to eq(1)
    expect(diags.first.message).to include("inferred as Integer")
    expect(diags.first.severity).to eq(:info)
    expect(diags.first.qualified_rule).to eq("plugin.lisp-eval.inferred-return-type")
  end

  it "promotes to Float when any operand is a float literal" do
    result = run_plugin(source: "Lisp.eval([:+, 1, [:*, 2.0, 3]])\n")
    expect(plugin_diagnostics(result).first.message).to include("inferred as Float")
  end

  it "infers bool for comparison forms" do
    result = run_plugin(source: "Lisp.eval([:<, 1, 2])\n")
    expect(plugin_diagnostics(result).first.message).to include("inferred as bool")
  end

  it "unions branch types for `:if` forms with disagreeing branches" do
    result = run_plugin(source: "Lisp.eval([:if, [:<, 1, 2], 1, 2.0])\n")
    expect(plugin_diagnostics(result).first.message).to include("inferred as Integer | Float")
  end

  it "infers bool for boolean composition" do
    result = run_plugin(source: "Lisp.eval([:and, true, [:not, false]])\n")
    expect(plugin_diagnostics(result).first.message).to include("inferred as bool")
  end

  it "stays silent when the argument is not a literal Lisp expression" do
    result = run_plugin(source: <<~RUBY)
      program = [:+, 1, 2]
      Lisp.eval(program)
    RUBY
    expect(plugin_diagnostics(result)).to be_empty
  end

  it "surfaces ill-typed arithmetic as a type-error diagnostic" do
    result = run_plugin(source: "Lisp.eval([:+, 1, true])\n")
    error_diag = plugin_diagnostics(result).find { |d| d.rule == "type-error" }
    expect(error_diag).not_to be_nil
    expect(error_diag.severity).to eq(:error)
    expect(error_diag.message).to match(/`\+` expects numeric operands/)
    expect(error_diag.qualified_rule).to eq("plugin.lisp-eval.type-error")
  end

  it "ignores call sites that target a different module by default" do
    result = run_plugin(source: "Other.eval([:+, 1, 2])\n")
    expect(plugin_diagnostics(result)).to be_empty
  end

  it "respects the `module_name` / `method_name` config overrides" do
    result = run_plugin(
      source: "Calculator.run([:+, 1, 2])\n",
      plugin_entry: {
        "gem" => "rigor-lisp-eval",
        "config" => { "module_name" => "Calculator", "method_name" => "run" }
      }
    )
    diags = plugin_diagnostics(result)
    expect(diags.size).to eq(1)
    expect(diags.first.message).to start_with("Calculator.run return type inferred as Integer")
  end
end
