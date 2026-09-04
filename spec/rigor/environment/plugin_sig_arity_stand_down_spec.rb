# frozen_string_literal: true

# Issue #610 — when a BUNDLED PLUGIN's signature must stand down.
#
# `plugins/rigor-activerecord/sig` declares `class ActiveRecord::Relation[Elem]`; `rbs collection install`
# ships a NON-generic `ActiveRecord::Relation`. Two declarations of one class with different generic arity
# make `RBS::DefinitionBuilder` raise `GenericParameterMismatchError`, and Rigor keeps the class KNOWN after
# a failed build — so every call into a relation reads `Dynamic[top]`, real methods and typos alike, on a
# run that exits 0. `rigor-project-init` recommends both the plugin and the collection, so the two
# recommendations cancelled each other out.
#
# **The assertions here are positive, for the reason the sibling ADR-72 stand-down spec records.** A
# collapsed class produces ZERO diagnostics, so an absence-only assertion passes on the very state being
# fixed. Each example pins a method that must RESOLVE, and the equal-arity control pins the plugin's own
# declaration still winning — a blanket stand-down would pass a decline-only gate.
require "spec_helper"
require "tmpdir"

RSpec.describe "issue #610 plugin signature arity stand-down" do
  # Stands in for `plugins/*/sig`: a generic declaration carrying a method only it declares.
  def plugin_rbs = <<~RBS
    module Store
      class Relation[Elem]
        def each: () { (Elem) -> void } -> self
        def plugin_only: () -> Integer
      end
    end
  RBS

  # Stands in for `rbs collection install`: the same class, NON-generic. This is the collision.
  def non_generic_rbs = <<~RBS
    module Store
      class Relation
        def collection_only: () -> String
      end
    end
  RBS

  # The control: a second declaration at the SAME arity, declaring a method the plugin does not. RBS
  # reopens the class, which is ordinary and supported, so nothing may stand down.
  def same_arity_rbs = <<~RBS
    module Store
      class Relation[Elem]
        def user_only: () -> String
      end
    end
  RBS

  # Builds a loader over two directories, the second deferred as a plugin's contribution would be.
  def loader_for(user_rbs, dir)
    plugin_dir = File.join(dir, "plugin_sig")
    user_dir = File.join(dir, "user_sig")
    [plugin_dir, user_dir].each { |d| Dir.mkdir(d) }
    File.write(File.join(plugin_dir, "relation.rbs"), plugin_rbs)
    File.write(File.join(user_dir, "relation.rbs"), user_rbs) if user_rbs
    Rigor::Environment::RbsLoader.new(
      libraries: [],
      signature_paths: [user_dir, plugin_dir],
      deferred_signature_paths: [plugin_dir]
    )
  end

  def resolves?(loader, method_name)
    !loader.instance_method(class_name: "Store::Relation", method_name: method_name).nil?
  end

  it "keeps the plugin's own generic declaration when nothing else declares the class" do
    Dir.mktmpdir do |dir|
      loader = loader_for(nil, dir)
      expect(resolves?(loader, :plugin_only)).to be(true)
      expect(loader.signature_standdowns).to be_empty
    end
  end

  it "stands the plugin's file down against a different generic arity, and the survivor RESOLVES" do
    Dir.mktmpdir do |dir|
      loader = loader_for(non_generic_rbs, dir)
      # The whole point: on master neither of these resolves, because the build raises and the class
      # collapses. Asserting the survivor's method is what distinguishes "stood down" from "collapsed".
      expect(resolves?(loader, :collection_only)).to be(true)
      expect(resolves?(loader, :plugin_only)).to be(false)
      expect(loader.definition_build_failures).to be_empty
      standdown = loader.signature_standdowns
      expect(standdown.size).to eq(1)
      expect(standdown.first[0]).to end_with("plugin_sig/relation.rbs")
      expect(standdown.first[1..]).to eq(["::Store::Relation", 0, 1])
    end
  end

  it "does NOT stand down against an equal arity — the plugin's declaration still wins" do
    Dir.mktmpdir do |dir|
      loader = loader_for(same_arity_rbs, dir)
      expect(resolves?(loader, :plugin_only)).to be(true)
      expect(resolves?(loader, :user_only)).to be(true)
      expect(loader.signature_standdowns).to be_empty
    end
  end
end
