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
#
# **And they run through a real cache store as well as without one.** The loader has TWO build entries:
# its own `build_env` (taken only with no store — `--no-cache`) and the env-cache producer
# (`Cache::RbsEnvironment`, taken on every cached run, which is the CLI default). The first version of this
# gate built a store-less loader and stayed green while 0.3.8 ran the stand-down on no real `rigor check`
# at all (the reopen): the producer did not pass the deferred list. Same shape as #696's lesson that a nil
# store makes the pre-warm a no-op — a gate that cannot reach the producer cannot see it.
require "spec_helper"
require "tmpdir"
require "fileutils"
require "rigor/cache/store"

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

  # Materialises two directories, the second the plugin's contribution. Idempotent, so an example can
  # build a second loader over the same tree (the cache-HIT arm).
  def write_sigs(user_rbs, dir)
    plugin_dir = File.join(dir, "plugin_sig")
    user_dir = File.join(dir, "user_sig")
    [plugin_dir, user_dir].each { |d| FileUtils.mkdir_p(d) }
    File.write(File.join(plugin_dir, "relation.rbs"), plugin_rbs)
    File.write(File.join(user_dir, "relation.rbs"), user_rbs) if user_rbs
    [user_dir, plugin_dir]
  end

  def loader_over(user_dir, plugin_dir, cache_store: nil)
    Rigor::Environment::RbsLoader.new(
      libraries: [],
      signature_paths: [user_dir, plugin_dir],
      deferred_signature_paths: [plugin_dir],
      cache_store: cache_store
    )
  end

  def loader_for(user_rbs, dir, cache_store: nil)
    loader_over(*write_sigs(user_rbs, dir), cache_store: cache_store)
  end

  def store_for(dir)
    Rigor::Cache::Store.new(root: File.join(dir, "cache"))
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
      expect(standdown.first[1..3]).to eq(["::Store::Relation", 0, 1])
      # The source that displaced it, so the report can name both sides.
      expect(standdown.first[4]).to end_with("user_sig/relation.rbs")
      # A file that stood down is absent from the env BY DESIGN — which is exactly what the collision
      # quarantine used to read as "duplicated against bundled RBS". It is reported as a stand-down, once.
      expect(loader.quarantined_signatures).to be_empty
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

  describe "through the env-cache producer (the build every cached run takes)" do
    it "stands the plugin's file down on a cache MISS, and the survivor RESOLVES" do
      Dir.mktmpdir do |dir|
        loader = loader_for(non_generic_rbs, dir, cache_store: store_for(dir))
        expect(resolves?(loader, :collection_only)).to be(true)
        expect(resolves?(loader, :plugin_only)).to be(false)
        expect(loader.definition_build_failures).to be_empty
        expect(loader.signature_standdowns.size).to eq(1)
        expect(loader.quarantined_signatures).to be_empty
      end
    end

    it "reports the same stand-down on a cache HIT, from the marshalled env, without rebuilding" do
      Dir.mktmpdir do |dir|
        store = store_for(dir)
        user_dir, plugin_dir = write_sigs(non_generic_rbs, dir)
        # The cold loader builds through the producer and fills the store.
        expect(resolves?(loader_over(user_dir, plugin_dir, cache_store: store), :collection_only)).to be(true)

        allow(Rigor::Environment::RbsLoader).to receive(:build_env_for).and_call_original
        warm = loader_over(user_dir, plugin_dir, cache_store: store)
        expect(resolves?(warm, :collection_only)).to be(true)
        expect(resolves?(warm, :plugin_only)).to be(false)
        expect(warm.definition_build_failures).to be_empty
        standdown = warm.signature_standdowns
        expect(standdown.size).to eq(1)
        expect(standdown.first[0]).to end_with("plugin_sig/relation.rbs")
        expect(standdown.first[4]).to end_with("user_sig/relation.rbs")
        expect(warm.quarantined_signatures).to be_empty
        expect(Rigor::Environment::RbsLoader).not_to have_received(:build_env_for)
      end
    end

    it "keeps the plugin's declaration on a cached build when nothing else declares the class" do
      Dir.mktmpdir do |dir|
        loader = loader_for(nil, dir, cache_store: store_for(dir))
        expect(resolves?(loader, :plugin_only)).to be(true)
        expect(loader.signature_standdowns).to be_empty
      end
    end
  end

  # rbs 4.x's `ClassEntry#type_params` VALIDATES before answering and raises `GenericParameterMismatchError`
  # on an entry whose declarations already disagree; rbs 3.x validates one step earlier, in
  # `MultiEntry#primary`, which the env RESOLVE reaches. The stand-down's arity read used to go through
  # both, so a collision between two of the user's OWN sources made the loader raise the very error the
  # class's build reports — at read time on 4.x, inside the env build on 3.x. The read now takes the
  # entry's first declaration, which neither line validates, and the two lines keep their own (different)
  # accounts of the user's collision.
  describe "an environment two NON-deferred sources already collided" do
    def collided_loader(dir)
      user_dir, plugin_dir = write_sigs(non_generic_rbs, dir)
      File.write(File.join(user_dir, "relation_generic.rbs"), <<~RBS)
        module Store
          class Relation[T]
            def user_generic_only: () -> Integer
          end
        end
      RBS
      loader_over(user_dir, plugin_dir)
    end

    it "never raises from the stand-down reader, whichever rbs line built it" do
      Dir.mktmpdir do |dir|
        loader = collided_loader(dir)
        expect { loader.signature_standdowns }.not_to raise_error
        expect { loader.quarantined_signatures }.not_to raise_error
      end
    end

    it "keeps the user's collision where it belongs — the class's own definition build — when the env builds",
       if: RBS::VERSION.start_with?("4.") do
      Dir.mktmpdir do |dir|
        loader = collided_loader(dir)
        expect(loader.class_known?("Store::Relation")).to be(true)
        # The plugin still stands down against the FIRST declaration (the non-generic one, by load order).
        expect(loader.signature_standdowns.size).to eq(1)
        expect(loader.quarantined_signatures).to be_empty
        loader.instance_method(class_name: "Store::Relation", method_name: :collection_only)
        expect(loader.definition_build_failures.map { |failure| failure[1].to_s })
          .to include("RBS::GenericParameterMismatchError")
      end
    end

    it "reports the total env-build failure rbs 3.x raises at resolve, with nothing stood down",
       if: RBS::VERSION.start_with?("3.") do
      Dir.mktmpdir do |dir|
        loader = collided_loader(dir)
        expect(loader.class_known?("Store::Relation")).to be(false)
        expect(loader.env_build_failure&.first.to_s).to eq("RBS::GenericParameterMismatchError")
        expect(loader.signature_standdowns).to be_empty
      end
    end
  end
end
