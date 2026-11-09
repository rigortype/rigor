# frozen_string_literal: true

# Issue #2994 — a class whose instance-side chain mixes in a module no table names (`include(*MODS)`,
# `ResolutionChain#unnamed_mixin?`, #2993) may answer any instance name from that module, ahead of `Object`'s private
# top-level `def`. The #618 veto (`ExpressionTyper#instance_self_answers?`) reads the mark, so the top-level `def` does
# not bind an implicit-self call there. On the class-object side, the `included` hook of a module in the splat runs with
# the class as `base` and may extend it with anything, so the singleton chain carries an `:include_hook` open mark
# (#2996) and `K.bar` declines instead of answering the superclass's `bar`. Every row's Ruby behaviour was witnessed on
# Ruby 4.0.5: each quiet call returns "X", and each reported call raises `NoMethodError`. The literal-include rows are
# controls: the veto and the binding stand there exactly as before.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a top-level def and a class-object read beside a mixin no name spells (#2994)" do
  let(:top) { "def m1 = nil\n" }
  let(:mods) { "module M1\n  def m1 = \"x\"\nend\nMODS = [M1]\n" }
  let(:hooked) do
    "class Base\n  def self.bar = 1\nend\nmodule X\n  def bar = \"x\"\nend\n" \
      "module M1\n  def self.included(base) = base.extend(X)\nend\nMODS = [M1]\n"
  end

  def undefined_messages(files)
    FileUtils.mkdir_p("lib")
    files.each { |name, source| File.write(File.join("lib", name), source) }
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  around do |example|
    Dir.mktmpdir("rigor-unnamed-mixin-top-def-") { |dir| Dir.chdir(dir) { example.run } }
  end

  describe "the instance side" do
    it "does not bind a top-level def inside the class that splats the module in" do
      source = "#{top}#{mods}class Sup\n  include(*MODS)\n  def t = m1.upcase\nend\n"
      expect(undefined_messages("a.rb" => source)).to be_empty
    end

    it "does not bind it when the top-level def, the modules and the class sit in other files" do
      files = { "top.rb" => top, "mods.rb" => mods, "sup.rb" => "class Sup\n  include(*MODS)\n  def t = m1.upcase\nend\n" }
      expect(undefined_messages(files)).to be_empty
    end

    it "does not bind it inside a subclass declared in another file" do
      files = { "a.rb" => "#{top}#{mods}class Sup\n  include(*MODS)\nend\n",
                "b.rb" => "class Sub < Sup\n  def t = m1.upcase\nend\n" }
      expect(undefined_messages(files)).to be_empty
    end

    it "still vetoes it beside a literal include of the module (control)" do
      source = "#{top}#{mods}class Lit\n  include M1\n  def t = m1.upcase\nend\n"
      expect(undefined_messages("a.rb" => source)).to be_empty
    end

    it "still binds it in a class with no mixin (control)" do
      source = "#{top}#{mods}class Bare\n  include Comparable\n  def t = m1.upcase\nend\n"
      expect(undefined_messages("a.rb" => source)).to eq(["undefined method `upcase' for nil"])
    end
  end

  describe "the class-object side" do
    it "declines the superclass's method on a class that splats in a module whose hook extends it" do
      source = "#{hooked}class K < Base\n  include(*MODS)\nend\nK.bar.upcase\n"
      expect(undefined_messages("a.rb" => source)).to be_empty
    end

    it "declines it when the hooked module, the class and the call sit in three files" do
      files = { "a.rb" => hooked, "k.rb" => "class K < Base\n  include(*MODS)\nend\n", "c.rb" => "K.bar.upcase\n" }
      expect(undefined_messages(files)).to be_empty
    end

    it "declines it on a subclass of the class that splats the module in" do
      files = { "a.rb" => "#{hooked}class K < Base\n  include(*MODS)\nend\n",
                "b.rb" => "class Sub < K\nend\nSub.bar.upcase\n" }
      expect(undefined_messages(files)).to be_empty
    end

    it "still answers the superclass's method beside a literal include of a module with no hook (control)" do
      source = "#{hooked}module M2\nend\nclass K2 < Base\n  include M2\nend\nK2.bar.upcase\n"
      expect(undefined_messages("a.rb" => source)).to eq(["undefined method `upcase' for 1"])
    end
  end
end
