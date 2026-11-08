# frozen_string_literal: true

# Issue #2979 — `K = Struct.new("Named", …)` binds `K` and `Struct::Named` to one class object
# (`K.equal?(Struct::Named)`), so a method defined under either name is the other's too: in the block, in a
# `class Struct::Named` reopening and in a `class K` reopening. `call.undefined-method` reads a struct-instance
# carrier as open, so these rows call through `self.` in a reopening and through `Struct::Named.new`, the shapes
# that reach a project class's method tables; `sig/` declares both names so the rule runs. Every row's Ruby
# behaviour was witnessed on Ruby 4.0.5.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "Struct.new with a class-name String: one class under two names (#2979)" do
  defs = <<~RUBY
    N = Struct.new("Named2", :n_url) do
      def own_url = 1
    end
    NK = Struct.new("NamedK", :k_url, keyword_init: true) do
      def own_k = 1
    end
    class N
      def from_k = 1
    end
  RUBY

  reopen = <<~RUBY
    class Struct::Named2
      def extra_url = 1
      def go2 = [self.own_url, self.from_k]
    end
    class Struct::NamedK
      def extra_k = 1
      def go2 = self.own_k
    end
    class N
      def go3 = self.extra_url
    end
    class NK
      def go3 = self.extra_k
    end
    def run
      [Struct::Named2.new(1).own_url, Struct::Named2.new(1).from_k, Struct::NamedK.new(k_url: 1).own_k]
    end
  RUBY

  sig = "class N\nend\nclass NK\nend\nclass Struct::Named2\nend\nclass Struct::NamedK\nend\n"
  let(:sig_source) { sig }

  def undefined_messages(files)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "types.rbs"), sig_source)
    files.each { |name, source| File.write(File.join("lib", name), source) }
    settings = { "paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0 }
    configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(settings))
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message).sort
  end

  around do |example|
    Dir.mktmpdir("rigor-struct-named-same-class-") { |dir| Dir.chdir(dir) { example.run } }
  end

  # File order is not load order: the reopening file sorts before and after the defining one, and the whole program
  # in one file is the third order.
  { "a reopening file sorted first" => { "n.rb" => defs, "a.rb" => reopen },
    "a reopening file sorted last" => { "n.rb" => defs, "z.rb" => reopen },
    "one file" => { "n.rb" => "#{defs}#{reopen}" } }.each do |where, files|
    it "reads a method under either name from the other, keyword_init: included, with #{where}" do
      expect(undefined_messages(files)).to be_empty
    end
  end

  it "still reports a name neither name defines, on both names" do
    unknown = "class N\n  def u1 = self.zz1\nend\nclass Struct::Named2\n  def u2 = self.zz2\nend\n" \
              "def u3 = Struct::Named2.new(1).zz3\n"
    expect(undefined_messages({ "n.rb" => defs, "r.rb" => reopen, "u.rb" => unknown }))
      .to eq(["undefined method `zz1' for N", "undefined method `zz2' for Struct::Named2",
              "undefined method `zz3' for Struct::Named2"])
  end

  describe "the same-class entries the indexer records" do
    def same_class_names(source, name)
      root = Prism.parse(source).value
      scope = Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
      Rigor::Scope::DiscoveryIndex.same_class_names(scope.discovered_parameter_envelopes[name])
    end

    it "binds the constant and Struct::Named to each other, blockless and nested included" do
      source = "N = Struct.new(\"Named\", :a)\nmodule Outer\n  NN = Struct.new(\"Named3\", :o) { def x = 1 }\nend\n"
      expect([same_class_names(source, "N"), same_class_names(source, "Struct::Named"),
              same_class_names(source, "Outer::NN"), same_class_names(source, "Struct::Named3")])
        .to eq([["Struct::Named"], ["N"], ["Struct::Named3"], ["Outer::NN"]])
    end

    # Ruby raises NameError for `Struct.new("lower", :a)` ("identifier lower needs to be constant"), so it names no
    # `Struct::` class; under `Class.new(Struct.new("Named", :a))` the constant is a subclass, not the class; and a
    # receiver other than `Struct` makes no `Struct::` class at all.
    it "binds nothing for a String that is not a constant name, a wrapped factory, or another receiver" do
      source = "L = Struct.new(\"lower\", :a)\nW = Class.new(Struct.new(\"Wrapped\", :a))\n" \
               "O = Other.new(\"Oth\", :a)\n"
      expect(%w[L W Struct::Wrapped O Struct::Oth].map { |name| same_class_names(source, name) })
        .to eq([[], [], [], [], []])
    end
  end
end
