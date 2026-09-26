# frozen_string_literal: true

require "spec_helper"
require "prism"
require "tmpdir"
require "rigor/inference/scope_indexer"

# Issue #992 — `Scope::DiscoveryIndex#discovered_parameter_envelopes`, as the declaration walk records it.
RSpec.describe "ScopeIndexer parameter envelopes (#992)" do
  let(:opaque) { Rigor::Source::ParameterEnvelope::OPAQUE }
  let(:module_mark) { Rigor::Scope::DiscoveryIndex::ENVELOPE_MODULE_MARK }
  let(:dynamic_mark) { Rigor::Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK }

  def envelopes(source)
    Rigor::Inference::ScopeIndexer.build_methods_and_def_nodes(Prism.parse(source).value).fetch(2)
  end

  it "records a def's envelope under [kind, name], on both sides of the class" do
    table = envelopes(<<~RUBY)
      class A
        def f(a, b = 1) = a
        def self.g(*r) = r
        class << self
          def h(x) = x
        end
      end
    RUBY
    expect(table.fetch("A")).to eq(
      %i[instance f] => [1, 2, false], %i[singleton g] => [0, nil, false], %i[singleton h] => [1, 1, false]
    )
  end

  it "records every other contribution the existence table sees as opaque, joined with the def" do
    table = envelopes(<<~RUBY)
      class A
        def f(a) = a
        attr_reader :f
        def g(a) = a
        alias h g
        define_method(:i) { |x| x }
        Point = Struct.new(:x)
      end
    RUBY
    expect(table.fetch("A")).to include(
      %i[instance f] => opaque, %i[instance g] => opaque, %i[singleton g] => opaque,
      %i[instance h] => opaque, %i[instance i] => opaque
    )
  end

  it "keeps a reopening with the same shape and makes a different one opaque" do
    expect(envelopes("class A\n  def f(a) = a\nend\nclass A\n  def f(b) = b\nend\n").fetch("A"))
      .to eq(%i[instance f] => [1, 1, false])
    expect(envelopes("class A\n  def f(a) = a\nend\nclass A\n  def f(a, b) = b\nend\n").fetch("A"))
      .to eq(%i[instance f] => opaque)
  end

  it "marks modules, and classes whose method table is rewritten beyond what a literal names" do
    table = envelopes(<<~RUBY)
      module M
      end
      N = Module.new do
        def x = 1
      end
      class A
        class_eval "def f = 1"
      end
      class B
        include Module.new
      end
      C.class_eval { def f = 1 }
    RUBY
    expect(table.fetch("M")).to eq(module_mark => opaque)
    expect(table.fetch("N")).to include(module_mark => opaque)
    expect(table.fetch("A")).to include(dynamic_mark => opaque)
    expect(table.fetch("B")).to include(dynamic_mark => opaque)
    # A constant-receiver eval block's defs attribute to the receiver, so `C#f` is a
    # literal def — no dynamic mark. The STRING eval form stays opaque (`A` above).
    expect(table.fetch("C")).to eq(%i[instance f] => [0, 0, false])
  end

  it "adds the project-wide key only on a whole-project pass" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.rb")
      File.write(path, "class A\n  def f(a) = a\nend\n")
      index = Rigor::Inference::ScopeIndexer.discovered_project_index_for_paths([path]).fetch(:def_index)
      expect(index.fetch(:parameter_envelopes)).to include(Rigor::Scope::DiscoveryIndex::ENVELOPE_PROJECT_WIDE => {})
    end
    expect(envelopes("class A\n  def f(a) = a\nend\n")).not_to have_key(Rigor::Scope::DiscoveryIndex::ENVELOPE_PROJECT_WIDE)
  end
end
