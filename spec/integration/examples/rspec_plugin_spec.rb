# frozen_string_literal: true

# Integration spec for `examples/rigor-rspec/`.
# Tier 3A of the Rails plugins roadmap. Deliberately
# scoped — only flags duplicate `let` / `subject`
# declarations and self-referencing let blocks. The
# heavier mock-target / let-typo detection is out of scope
# for v0.1.0.

require "spec_helper"

RSPEC_PLUGIN_LIB = File.expand_path("../../../examples/rigor-rspec/lib", __dir__)
$LOAD_PATH.unshift(RSPEC_PLUGIN_LIB) unless $LOAD_PATH.include?(RSPEC_PLUGIN_LIB)
require "rigor-rspec"

RSpec.describe "examples/rigor-rspec" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Rspec }

  describe "duplicate-let detection" do
    it "flags two `let(:name)` declarations in the same scope" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "User" do
            let(:user) { :first }
            let(:user) { :second }
          end
        RUBY
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "duplicate-let" }
      expect(err).not_to be_nil
      expect(err.severity).to eq(:warning)
      expect(err.message).to include("duplicate `let(:user)`")
      expect(err.message).to include("first declared at line 2")
    end

    it "flags `subject(:name)` duplicates" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "Greeting" do
            subject(:greeting) { "hi" }
            subject(:greeting) { "hello" }
          end
        RUBY
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "duplicate-let" }
      expect(err).not_to be_nil
      expect(err.message).to include("subject(:greeting)")
    end

    it "does NOT flag `let` declarations in different scopes (nested context)" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "User" do
            let(:user) { :outer }
            context "when inner" do
              let(:user) { :inner }
            end
          end
        RUBY
      )
      diags = plugin_diagnostics(result).select { |d| d.rule == "duplicate-let" }
      expect(diags).to be_empty
    end

    it "flags THREE duplicates with two diagnostics (the second and third occurrences)" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "X" do
            let(:foo) { 1 }
            let(:foo) { 2 }
            let(:foo) { 3 }
          end
        RUBY
      )
      dupes = plugin_diagnostics(result).select { |d| d.rule == "duplicate-let" }
      expect(dupes.size).to eq(2)
    end
  end

  describe "self-reference detection" do
    it "flags `let(:user) { user }` (literal self-reference)" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "User" do
            let(:user) { user }
          end
        RUBY
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "self-reference" }
      expect(err).not_to be_nil
      expect(err.severity).to eq(:error)
      expect(err.message).to include("`user`")
    end

    it "flags `let(:value) { value.something }` (deeper expression)" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "X" do
            let(:value) { value.upcase }
          end
        RUBY
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "self-reference" }
      expect(err).not_to be_nil
    end

    it "does NOT flag a let referencing a different let" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "X" do
            let(:user) { :alice }
            let(:greeting) { "Hello, \#{user}" }
          end
        RUBY
      )
      diags = plugin_diagnostics(result).select { |d| d.rule == "self-reference" }
      expect(diags).to be_empty
    end

    it "does NOT flag a let whose body uses an unrelated method" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "X" do
            let(:user) { build_user }
          end
        RUBY
      )
      diags = plugin_diagnostics(result).select { |d| d.rule == "self-reference" }
      expect(diags).to be_empty
    end
  end

  describe "edge cases" do
    it "ignores files with no `RSpec.describe` block" do
      result = run_plugin(source: "x = 1\nputs x\n")
      expect(plugin_diagnostics(result)).to be_empty
    end

    it "ignores `let` calls outside an RSpec describe block" do
      result = run_plugin(
        source: <<~RUBY
          # Not an RSpec file — just calls `let` at top level.
          let(:user) { :first }
          let(:user) { :second }
        RUBY
      )
      expect(plugin_diagnostics(result)).to be_empty
    end

    it "handles `subject` with no name (the implicit subject)" do
      # Two `subject { ... }` calls at the same scope are
      # still duplicates of the implicit `:subject`.
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "X" do
            subject { :first }
            subject { :second }
          end
        RUBY
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "duplicate-let" }
      expect(err).not_to be_nil
      expect(err.message).to include("subject(:subject)")
    end
  end
end
