# frozen_string_literal: true

# Issue #2422 — the #610 stand-down, extended from a plugin file's class header to its members.
#
# A bundled plugin's deferred signature file that redeclares, at equal arity, a method another source already
# declares used to reopen the class with both declarations in it: `RBS::DefinitionBuilder` raised
# `DuplicatedMethodDefinitionError` for that class and every class under it, so `Object#acts_like?` in an `rbs
# collection install` took `NilClass`, `Integer` and `String` down with it. Now the plugin leaves out each such
# member before its file is added, and the rest of the file loads.
#
# The assertions are positive for the reason `plugin_sig_arity_stand_down_spec.rb` records: a collapsed class
# produces zero diagnostics, so each example pins a method that must resolve, with the type of the source that
# should have won.
require "spec_helper"
require "tmpdir"
require "fileutils"
require "rigor/cache/store"

RSpec.describe "issue #2422 plugin signature member stand-down" do
  let(:plugin_sig) { File.expand_path("../../../plugins/rigor-activesupport-core-ext/sig", __dir__) }
  let(:eight_rows) do
    %w[
      Array#compact_blank! FalseClass#to_param Hash#compact_blank Integer#ordinalize NilClass#to_param
      Object#acts_like? Time#to_fs TrueClass#to_param
    ]
  end

  # The reporter's eight rows, as `rbs collection install` (activesupport 7.0) declares them. Each return type
  # differs from the plugin's, so which declaration bound is visible.
  def collection_rbs = <<~RBS
    class Object
      def acts_like?: (untyped duck) -> bool
    end
    class Array[unchecked out Elem]
      def compact_blank!: () -> Integer
    end
    class Hash[unchecked out K, unchecked out V]
      def compact_blank: () -> Symbol
    end
    class Integer
      def ordinalize: () -> Symbol
    end
    class NilClass
      def to_param: () -> Symbol
    end
    class TrueClass
      def to_param: () -> Symbol
    end
    class FalseClass
      def to_param: () -> Symbol
    end
    class Time
      def to_fs: (?Symbol format) -> Symbol
    end
  RBS

  def write_collection(dir, rbs = collection_rbs)
    sig = File.join(dir, "collection")
    FileUtils.mkdir_p(sig)
    File.write(File.join(sig, "activesupport.rbs"), rbs)
    sig
  end

  def as_loader(signature_paths, cache_store: nil, virtual_rbs: [])
    Rigor::Environment::RbsLoader.new(
      libraries: Rigor::Environment::DEFAULT_LIBRARIES,
      signature_paths: signature_paths + [plugin_sig],
      deferred_signature_paths: [plugin_sig],
      cache_store: cache_store,
      virtual_rbs: virtual_rbs
    )
  end

  def return_of(loader, class_name, method_name)
    loader.instance_method(class_name: class_name, method_name: method_name)&.method_types&.map do |t|
      t.type.return_type.to_s
    end
  end

  def member_rows(loader)
    loader.signature_standdowns.select { |row| row[5] == :member }
  end

  # The collection's return type for each of the eight, which differs from the plugin's.
  def collection_returns
    {
      %w[Object acts_like?] => "bool", %w[Array compact_blank!] => "::Integer", %w[Hash compact_blank] => "::Symbol",
      %w[Integer ordinalize] => "::Symbol", %w[NilClass to_param] => "::Symbol", %w[TrueClass to_param] => "::Symbol",
      %w[FalseClass to_param] => "::Symbol", %w[Time to_fs] => "::Symbol"
    }
  end

  def assert_collection_wins(loader)
    collection_returns.each do |(class_name, method_name), type|
      expect(return_of(loader, class_name, method_name)).to eq([type]), "#{class_name}##{method_name}"
    end
    acts_like = loader.instance_method(class_name: "Object", method_name: :acts_like?)
    expect(acts_like.method_types.first.type.required_positionals.first.type.to_s).to eq("untyped")
  end

  # What the false `call.possible-nil-receiver` and the swallowed `1.foo` stood on: every class builds, a
  # core method and a plugin-only method resolve, and a typo still does not.
  def assert_universe_builds(loader)
    expect(return_of(loader, "NilClass", :nil?)).to eq(["true"])
    expect(return_of(loader, "String", :present?)).to eq(["bool"])
    expect(loader.instance_method(class_name: "Integer", method_name: :foo)).to be_nil
    expect(loader.instance_method(class_name: "Integer", method_name: :abs)).not_to be_nil
    expect(loader.definition_build_failures).to be_empty
  end

  it "stands each of the reporter's eight members down and every class builds" do
    Dir.mktmpdir do |dir|
      loader = as_loader([write_collection(dir)])
      assert_collection_wins(loader)
      assert_universe_builds(loader)
      rows = member_rows(loader)
      expect(rows.map { |row| row[1] }.sort).to eq(eight_rows)
      expect(rows.map(&:first).uniq).to eq([File.join(plugin_sig, "active_support", "core_ext.rbs")])
      expect(rows.map { |row| row[4] }.uniq).to eq([File.join(dir, "collection", "activesupport.rbs")])
      expect(loader.quarantined_signatures).to be_empty
    end
  end

  it "loads the plugin file whole, with nothing reported, when no other source declares its members" do
    loader = as_loader([])
    expect(return_of(loader, "Integer", :ordinalize)).to eq(["::String"])
    expect(return_of(loader, "Object", :acts_like?)).to eq(["bool"])
    expect(loader.signature_standdowns).to be_empty
    assert_universe_builds(loader)
  end

  it "keeps an uncontested plugin member, its %a{pure} annotation included" do
    Dir.mktmpdir do |dir|
      loader = as_loader([write_collection(dir)])
      present = loader.instance_method(class_name: "Object", method_name: :present?)
      expect(present.annotations.map(&:string)).to include("pure")
      expect(present.defs.map { |d| d.member.location.buffer.name }).to all(end_with("core_ext.rbs"))
    end
  end

  it "stands the plugin member down against an inline RBS declaration too" do
    inline = ["virtual:app/models/thing.rb", "class Integer\n  def ordinalize: () -> Symbol\nend\n"]
    loader = as_loader([], virtual_rbs: [inline])
    expect(return_of(loader, "Integer", :ordinalize)).to eq(["::Symbol"])
    expect(loader.definition_build_failures).to be_empty
    expect(member_rows(loader)).to eq(
      [[File.join(plugin_sig, "active_support", "core_ext.rbs"), "Integer#ordinalize", nil, nil,
        "virtual:app/models/thing.rb", :member]]
    )
  end

  describe "through the env-cache producer" do
    it "reports the same rows and answers on a warm run, without rebuilding the env" do
      Dir.mktmpdir do |dir|
        store = Rigor::Cache::Store.new(root: File.join(dir, "cache"))
        collection = write_collection(dir)
        cold = as_loader([collection], cache_store: store)
        assert_collection_wins(cold)
        cold_rows = cold.signature_standdowns

        allow(Rigor::Environment::RbsLoader).to receive(:build_env_for).and_call_original
        warm = as_loader([collection], cache_store: store)
        assert_collection_wins(warm)
        assert_universe_builds(warm)
        expect(warm.signature_standdowns).to eq(cold_rows)
        expect(member_rows(warm).size).to eq(8)
        expect(Rigor::Environment::RbsLoader).not_to have_received(:build_env_for)
      end
    end
  end

  # Synthetic plugin files for the member shapes the real plugin does not carry.
  describe "member shapes" do
    def build(plugin_rbs, other_rbs, dir)
      plugin = File.join(dir, "plugin_sig")
      other = File.join(dir, "other_sig")
      [plugin, other].each { |d| FileUtils.mkdir_p(d) }
      File.write(File.join(plugin, "plugin.rbs"), plugin_rbs)
      File.write(File.join(other, "other.rbs"), other_rbs)
      Rigor::Environment::RbsLoader.new(
        libraries: [], signature_paths: [other, plugin], deferred_signature_paths: [plugin]
      )
    end

    def labels(loader)
      loader.signature_standdowns.select { |row| row[5] == :member }.map { |row| row[1] }
    end

    it "stands down only the colliding side of a same-named singleton and instance method" do
      Dir.mktmpdir do |dir|
        loader = build(
          "class Gadget\n  def self.make: () -> Integer\n  def make: () -> Integer\nend\n",
          "class Gadget\n  def self.make: () -> String\nend\n", dir
        )
        expect(loader.singleton_method(class_name: "Gadget", method_name: :make).method_types.map(&:to_s))
          .to eq(["() -> ::String"])
        expect(loader.instance_method(class_name: "Gadget", method_name: :make).method_types.map(&:to_s))
          .to eq(["() -> ::Integer"])
        expect(labels(loader)).to eq(["Gadget.make"])
      end
    end

    it "narrows a `def self?.m` to its untaken side" do
      Dir.mktmpdir do |dir|
        loader = build(
          "module Tool\n  def self?.run: () -> Integer\nend\n",
          "module Tool\n  def self.run: () -> String\nend\n", dir
        )
        expect(loader.singleton_method(class_name: "Tool", method_name: :run).method_types.map(&:to_s))
          .to eq(["() -> ::String"])
        expect(loader.instance_method(class_name: "Tool", method_name: :run).method_types.map(&:to_s))
          .to eq(["() -> ::Integer"])
        expect(labels(loader)).to eq(["Tool.run"])
      end
    end

    it "narrows an `attr_accessor` to its untaken half" do
      Dir.mktmpdir do |dir|
        loader = build(
          "class Gadget\n  attr_accessor name: Integer\nend\n",
          "class Gadget\n  def name: () -> String\nend\n", dir
        )
        expect(loader.instance_method(class_name: "Gadget", method_name: :name).method_types.map(&:to_s))
          .to eq(["() -> ::String"])
        expect(loader.instance_method(class_name: "Gadget", method_name: :name=)).not_to be_nil
        expect(labels(loader)).to eq(["Gadget#name"])
      end
    end

    it "keeps the plugin's overload continuation, and the class builds" do
      Dir.mktmpdir do |dir|
        loader = build(
          "class Gadget\n  def size: (Symbol) -> Symbol | ...\nend\n",
          "class Gadget\n  def size: () -> Integer\nend\n", dir
        )
        expect(loader.instance_method(class_name: "Gadget", method_name: :size).method_types.map(&:to_s))
          .to eq(["(::Symbol) -> ::Symbol", "() -> ::Integer"])
        expect(loader.definition_build_failures).to be_empty
        expect(labels(loader)).to be_empty
      end
    end

    it "keeps the #610 whole-file stand-down on a class-header arity conflict" do
      Dir.mktmpdir do |dir|
        loader = build(
          "class Relation[Elem]\n  def size: () -> Integer\n  def plugin_only: () -> Integer\nend\n",
          "class Relation\n  def size: () -> String\nend\n", dir
        )
        expect(loader.instance_method(class_name: "Relation", method_name: :plugin_only)).to be_nil
        expect(loader.instance_method(class_name: "Relation", method_name: :size).method_types.map(&:to_s))
          .to eq(["() -> ::String"])
        expect(loader.signature_standdowns.map { |row| row[1..3] }).to eq([["::Relation", 0, 1]])
      end
    end
  end
end
