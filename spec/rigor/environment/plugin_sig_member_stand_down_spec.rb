# frozen_string_literal: true

# Issue #2422 — the #610 stand-down, extended from a plugin file's class header to its members.
#
# A bundled plugin's deferred signature file that redeclares, at equal arity, a method another source already
# declares used to reopen the class with both declarations in it: `RBS::DefinitionBuilder` raised
# `DuplicatedMethodDefinitionError` for that class and every class under it, so `Object#acts_like?` in an `rbs
# collection install` took `NilClass`, `Integer` and `String` down with it. Now each such member composes with the
# other source's `def` as an overload continuation (the plugin's overloads first) when that source is not the
# project's own, and stands down when it is the project's `sig/` or inline RBS (#610's authority), or when it
# cannot be continued. A colliding constant or other declaration stands down on its own.
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

  # `project:` — the subset of `signature_paths` that is the project's own `sig/`; the rest stand in for an `rbs
  # collection install`.
  def as_loader(signature_paths, project: [], cache_store: nil, virtual_rbs: [])
    Rigor::Environment::RbsLoader.new(
      libraries: Rigor::Environment::DEFAULT_LIBRARIES,
      signature_paths: signature_paths + [plugin_sig],
      deferred_signature_paths: [plugin_sig],
      project_signature_paths: project,
      cache_store: cache_store,
      virtual_rbs: virtual_rbs
    )
  end

  def types_of(loader, class_name, method_name, singleton: false)
    lookup = singleton ? :singleton_method : :instance_method
    loader.public_send(lookup, class_name: class_name, method_name: method_name)&.method_types&.map(&:to_s)
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

  it "stands each of the reporter's eight members down to the project's own sig/, and every class builds" do
    Dir.mktmpdir do |dir|
      sig = write_collection(dir)
      loader = as_loader([sig], project: [sig])
      assert_collection_wins(loader)
      assert_universe_builds(loader)
      rows = member_rows(loader)
      expect(rows.map { |row| row[1] }.sort).to eq(eight_rows)
      expect(rows.map(&:first).uniq).to eq([File.join(plugin_sig, "active_support", "core_ext.rbs")])
      expect(rows.map { |row| row[4] }.uniq).to eq([File.join(dir, "collection", "activesupport.rbs")])
      expect(loader.quarantined_signatures).to be_empty
    end
  end

  it "composes each of the eight with a collection's declaration, the plugin's overloads first" do
    Dir.mktmpdir do |dir|
      loader = as_loader([write_collection(dir)])
      collection_returns.each do |(class_name, method_name), type|
        returns = return_of(loader, class_name, method_name)
        expect(returns.size).to eq(2), "#{class_name}##{method_name}"
        expect(returns.last).to eq(type), "#{class_name}##{method_name}"
      end
      expect(return_of(loader, "Integer", :ordinalize)).to eq(["::String", "::Symbol"])
      assert_universe_builds(loader)
      expect(loader.signature_standdowns).to be_empty
    end
  end

  # The user's ruling on the review of #2424: the plugin writes these wider than the collection on purpose, and
  # the collection's `-> false` / `-> true` alone fold `if o.html_safe?` and `unless o.duplicable?` into dead
  # branches on correct code.
  it "keeps the plugin's wider `html_safe?` / `duplicable?` ahead of a collection's literal returns" do
    Dir.mktmpdir do |dir|
      loader = as_loader([write_collection(dir, "class Object\n  def html_safe?: () -> false\n  " \
                                                "def duplicable?: () -> true\nend\n")])
      expect(types_of(loader, "Object", :html_safe?)).to eq(["() -> bool", "() -> false"])
      expect(types_of(loader, "Object", :duplicable?)).to eq(["() -> bool", "() -> true"])
      expect(loader.definition_build_failures).to be_empty
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
        cold = as_loader([collection], project: [collection], cache_store: store)
        assert_collection_wins(cold)
        cold_rows = cold.signature_standdowns

        allow(Rigor::Environment::RbsLoader).to receive(:build_env_for).and_call_original
        warm = as_loader([collection], project: [collection], cache_store: store)
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
    # `own:` — whether the other source is the project's own `sig/` (stand down) or not (compose).
    def build(plugin_rbs, other_rbs, dir, own: true)
      plugin = File.join(dir, "plugin_sig")
      other = File.join(dir, "other_sig")
      [plugin, other].each { |d| FileUtils.mkdir_p(d) }
      File.write(File.join(plugin, "plugin.rbs"), plugin_rbs)
      File.write(File.join(other, "other.rbs"), other_rbs)
      Rigor::Environment::RbsLoader.new(
        libraries: [], signature_paths: [other, plugin], deferred_signature_paths: [plugin],
        project_signature_paths: own ? [other] : []
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

    it "composes a narrower plugin overload with a collection's, so a call only the collection's accepts resolves" do
      Dir.mktmpdir do |dir|
        loader = build("class Gadget\n  def pick: (Integer) -> Integer\nend\n",
                       "class Gadget\n  def pick: (String) -> String\nend\n", dir, own: false)
        expect(types_of(loader, "Gadget", :pick)).to eq(["(::Integer) -> ::Integer", "(::String) -> ::String"])
        expect(labels(loader)).to be_empty
      end
    end

    it "composes onto a method the collection itself declares as a continuation of core" do
      Dir.mktmpdir do |dir|
        loader = build("class String\n  def to_s: (Integer) -> String\nend\n",
                       "class String\n  def to_s: (Symbol) -> String | ...\nend\n", dir, own: false)
        expect(types_of(loader, "String", :to_s)).to eq(
          ["(::Integer) -> ::String", "(::Symbol) -> ::String", "() -> ::String"]
        )
        expect(loader.definition_build_failures).to be_empty
      end
    end

    it "composes a plugin `def` onto a collection's attribute or alias too" do
      Dir.mktmpdir do |dir|
        loader = build("class Gadget\n  def name: () -> Integer\n  def nick: () -> Integer\nend\n",
                       "class Gadget\n  attr_reader name: String\n  def label: () -> String\n  alias nick label\nend\n",
                       dir, own: false)
        expect(types_of(loader, "Gadget", :name)).to eq(["() -> ::Integer", "() -> ::String"])
        expect(types_of(loader, "Gadget", :nick)).to eq(["() -> ::Integer", "() -> ::String"])
        expect(loader.definition_build_failures).to be_empty
      end
    end

    it "still stands an attribute down against a collection, since it cannot be continued" do
      Dir.mktmpdir do |dir|
        loader = build("class Gadget\n  attr_reader name: Integer\nend\n",
                       "class Gadget\n  def name: () -> String\nend\n", dir, own: false)
        expect(types_of(loader, "Gadget", :name)).to eq(["() -> ::String"])
        expect(labels(loader)).to eq(["Gadget#name"])
      end
    end

    # Review of #2424, M3: the planner recurses into a type nested in a module, which is where most of a gem's
    # surface lives (`ActiveSupport::Duration#parts`).
    it "plans a type nested in a namespace" do
      Dir.mktmpdir do |dir|
        loader = build(
          "module ActiveSupport\n  class Duration\n    def parts: () -> Integer\n    " \
          "def plugin_only: () -> Integer\n  " \
          "end\nend\n",
          "module ActiveSupport\n  class Duration\n    def parts: () -> String\n  end\nend\n", dir
        )
        expect(types_of(loader, "ActiveSupport::Duration", :parts)).to eq(["() -> ::String"])
        expect(types_of(loader, "ActiveSupport::Duration", :plugin_only)).to eq(["() -> ::Integer"])
        expect(labels(loader)).to eq(["ActiveSupport::Duration#parts"])
      end
    end

    # Review of #2424, m2: two plugin files that both declare a method load in sorted path order, so the later
    # one composes onto the earlier and its overloads come first.
    it "loads two plugin files in sorted order, the later composing onto the earlier" do
      Dir.mktmpdir do |dir|
        first = File.join(dir, "p1")
        second = File.join(dir, "p2")
        [first, second].each { |d| FileUtils.mkdir_p(d) }
        File.write(File.join(first, "a.rbs"), "class Gadget\n  def m: () -> Integer\nend\n")
        File.write(File.join(second, "b.rbs"), "class Gadget\n  def m: () -> String\nend\n")
        loader = Rigor::Environment::RbsLoader.new(
          libraries: [], signature_paths: [second, first], deferred_signature_paths: [second, first]
        )
        expect(types_of(loader, "Gadget", :m)).to eq(["() -> ::String", "() -> ::Integer"])
      end
    end

    it "stands a type down on its own when another source declares its name as a class alias" do
      Dir.mktmpdir do |dir|
        loader = build("class Gizmo\n  def a: () -> Integer\nend\nclass Widget\n  def b: () -> Integer\nend\n",
                       "class Gizmo = Integer\n", dir, own: false)
        expect(types_of(loader, "Widget", :b)).to eq(["() -> ::Integer"])
        expect(loader.signature_standdowns.map { |row| [row[1], File.basename(row[4].to_s)] })
          .to eq([%w[Gizmo other.rbs]])
      end
    end

    it "stands a type down on its own when another source declares it with the other kind" do
      Dir.mktmpdir do |dir|
        loader = build("class Gizmo\n  def a: () -> Integer\nend\nclass Widget\n  def b: () -> Integer\nend\n",
                       "module Gizmo\nend\n", dir, own: false)
        expect(loader.class_known?("Gizmo")).to be(true)
        expect(types_of(loader, "Widget", :b)).to eq(["() -> ::Integer"])
        expect(loader.signature_standdowns.map { |row| row[1] }).to eq(["Gizmo"])
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

  # Review of #2424, M2: inline RBS now loads before the plugins' files, so a constant both declare used to raise
  # `DuplicatedDeclarationError` on the plugin's file and drop all of `ffi.rbs`.
  it "stands only a colliding constant down, keeping the rest of the plugin's file" do
    ffi_sig = File.expand_path("../../../plugins/rigor-ffi/sig", __dir__)
    inline = ["virtual:lib/a.rb", "module FFI\n  class Pointer\n    NULL: FFI::Pointer\n  end\nend\n"]
    loader = Rigor::Environment::RbsLoader.new(
      libraries: [], signature_paths: [ffi_sig], deferred_signature_paths: [ffi_sig], virtual_rbs: [inline]
    )
    expect(types_of(loader, "FFI::MemoryPointer", :read_string)).not_to be_nil
    expect(types_of(loader, "FFI::Pointer", :null?)).to eq(["() -> bool"])
    expect(loader.quarantined_signatures).to be_empty
    expect(loader.signature_standdowns.map do |row|
      [row[1], row[4]]
    end).to eq([["FFI::Pointer::NULL", "virtual:lib/a.rb"]])
  end

  # Issue #2439 — rigor-activerecord's `framework.rbs` declares `StatementInvalid` and `ConnectionNotEstablished`
  # `< ActiveRecordError`; activerecord 7.1+ in `gem_rbs_collection` declares both `< AdapterError`. Two clauses
  # raised `RBS::SuperclassMismatchError`, so the plugin's class header now drops its superclass whenever another
  # source gives the class one, and keeps it otherwise.
  describe "superclass clause" do
    let(:ar_sig) { File.expand_path("../../../plugins/rigor-activerecord/sig", __dir__) }

    # The 7.1+ shape: `AdapterError` between the two errors and `ActiveRecordError`.
    def adapter_rbs = <<~RBS
      module ActiveRecord
        class ActiveRecordError < StandardError
        end
        class AdapterError < ActiveRecordError
        end
        class ConnectionNotEstablished < AdapterError
        end
        class StatementInvalid < AdapterError
        end
      end
    RBS

    def ar_loader(dir, rbs, project: false, cache_store: nil)
      paths = []
      unless rbs.nil?
        other = File.join(dir, "other_sig")
        FileUtils.mkdir_p(other)
        File.write(File.join(other, "activerecord.rbs"), rbs)
        paths << other
      end
      Rigor::Environment::RbsLoader.new(
        libraries: Rigor::Environment::DEFAULT_LIBRARIES, signature_paths: paths + [ar_sig],
        deferred_signature_paths: [ar_sig], project_signature_paths: project ? paths : [], cache_store: cache_store
      )
    end

    def superclass_rows(loader)
      member_rows(loader).filter_map { |row| [row[1], File.basename(row[4].to_s)] if row[1].include?(" < ") }
    end

    def ancestors(loader, name) = loader.ancestor_names_for(name)

    it "reopens the class under another source's superclass, and every class builds" do
      Dir.mktmpdir do |dir|
        loader = ar_loader(dir, adapter_rbs)
        expect(loader.definition_build_failures).to be_empty
        expect(ancestors(loader, "ActiveRecord::StatementInvalid"))
          .to include("ActiveRecord::AdapterError", "ActiveRecord::ActiveRecordError", "StandardError")
        expect(ancestors(loader, "ActiveRecord::RecordNotUnique")).to include("ActiveRecord::AdapterError")
        expect(superclass_rows(loader)).to eq(
          [["ActiveRecord::ConnectionNotEstablished < ActiveRecordError", "activerecord.rbs"],
           ["ActiveRecord::StatementInvalid < ActiveRecordError", "activerecord.rbs"]]
        )
      end
    end

    it "reports no row where the other source names the same superclass (activerecord 6.0-7.0)" do
      Dir.mktmpdir do |dir|
        loader = ar_loader(dir, adapter_rbs.gsub("< AdapterError", "< ActiveRecordError"))
        expect(loader.definition_build_failures).to be_empty
        expect(ancestors(loader, "ActiveRecord::StatementInvalid")).to include("ActiveRecord::ActiveRecordError")
        expect(superclass_rows(loader)).to be_empty
      end
    end

    it "keeps the plugin's superclass when no other source gives the class one" do
      Dir.mktmpdir do |dir|
        [nil, "module ActiveRecord
  class StatementInvalid
    def sql: () -> String?
  end
end
"].each do |rbs|
          loader = ar_loader(dir, rbs)
          expect(ancestors(loader, "ActiveRecord::StatementInvalid"))
            .to include("ActiveRecord::ActiveRecordError", "StandardError")
          expect(superclass_rows(loader)).to be_empty
        end
      end
    end

    it "yields to a superclass the project's own sig/ declares" do
      Dir.mktmpdir do |dir|
        loader = ar_loader(dir, "class MyBase < StandardError
end
" \
                                "class ActiveRecord::ConnectionNotEstablished < MyBase
end
", project: true)
        expect(loader.definition_build_failures).to be_empty
        expect(ancestors(loader, "ActiveRecord::ConnectionNotEstablished")).to include("MyBase")
        expect(ancestors(loader, "ActiveRecord::ConnectionNotEstablished")).not_to include("ActiveRecord::ActiveRecordError")
        expect(superclass_rows(loader))
          .to eq([["ActiveRecord::ConnectionNotEstablished < ActiveRecordError", "activerecord.rbs"]])
      end
    end

    it "reports the same rows on a warm run, without rebuilding the env" do
      Dir.mktmpdir do |dir|
        store = Rigor::Cache::Store.new(root: File.join(dir, "cache"))
        cold_rows = superclass_rows(ar_loader(dir, adapter_rbs, cache_store: store))
        allow(Rigor::Environment::RbsLoader).to receive(:build_env_for).and_call_original
        warm = ar_loader(dir, adapter_rbs, cache_store: store)
        expect(superclass_rows(warm)).to eq(cold_rows)
        expect(cold_rows.size).to eq(2)
        expect(Rigor::Environment::RbsLoader).not_to have_received(:build_env_for)
      end
    end
  end
end
