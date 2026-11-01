# frozen_string_literal: true

# Issue #2470 — a `data/vendored_gem_sigs/` member another signature source also declares stands down.
#
# The activerecord 8.1 collection's `patch.rbs` declares `def async_exec` on `PG::Connection`, where Rigor's
# vendored `pg.rbs` has `alias async_exec exec`. Both used to reach the env, so `RBS::DefinitionBuilder` raised
# `DuplicatedMethodDefinitionError` for `PG::Connection`. The env was the same with and without the cache; only
# the cache path's whole-universe tables (`RbsLoader#type_param_names_table` and the rest, built over every known
# class on a cold store) demanded the class when the program did not, so only that path printed the warning.
#
# The assertions are positive: a collapsed class reads `Dynamic[top]` and draws nothing, so each example pins the
# declaration that must bind.
require "spec_helper"
require "tmpdir"
require "fileutils"
require "rigor/cache/store"

RSpec.describe "issue #2470 vendored signature member stand-down" do
  let(:vendored_pg) { File.expand_path("../../../data/vendored_gem_sigs/pg/pg.rbs", __dir__) }

  # What the activerecord 8.1 collection's `patch.rbs` declares on `PG::Connection`.
  def patch_rbs = <<~RBS
    module PG
      class Connection
        def async_exec: (*untyped) -> untyped
      end
    end
  RBS

  def write_sig(dir, rbs = patch_rbs)
    sig = File.join(dir, "collection")
    FileUtils.mkdir_p(sig)
    File.write(File.join(sig, "patch.rbs"), rbs)
    sig
  end

  def as_loader(signature_paths, cache_store: nil)
    Rigor::Environment::RbsLoader.new(
      libraries: Rigor::Environment::DEFAULT_LIBRARIES,
      signature_paths: signature_paths,
      cache_store: cache_store
    )
  end

  def types_of(loader, method_name)
    loader.instance_method(class_name: "PG::Connection", method_name: method_name)&.method_types&.map(&:to_s)
  end

  def buffers_of(loader, method_name)
    loader.instance_method(class_name: "PG::Connection", method_name: method_name).defs.map do |d|
      d.member.location.buffer.name.to_s
    end.uniq
  end

  def assert_collection_wins(loader, sig)
    expect(types_of(loader, :async_exec)).to eq(["(*untyped) -> untyped"])
    expect(buffers_of(loader, :async_exec)).to eq([File.join(sig, "patch.rbs")])
    # The rest of the vendored class still binds.
    expect(buffers_of(loader, :exec)).to eq([vendored_pg])
    expect(types_of(loader, :query).first).to include("::PG::Result")
    expect(loader.definition_build_failures).to be_empty
  end

  it "lets the collection's `def async_exec` bind in place of the vendored alias, uncached" do
    Dir.mktmpdir do |dir|
      sig = write_sig(dir)
      loader = as_loader([sig])
      expect { assert_collection_wins(loader, sig) }.not_to output(/definition build failed/).to_stderr
    end
  end

  it "builds every class of the whole-universe tables on a cold cache, and answers the same warm" do
    Dir.mktmpdir do |dir|
      sig = write_sig(dir)
      store = Rigor::Cache::Store.new(root: File.join(dir, "cache"))
      cold = as_loader([sig], cache_store: store)
      expect { cold.prewarm }.not_to output(/definition build failed/).to_stderr
      assert_collection_wins(cold, sig)

      allow(Rigor::Environment::RbsLoader).to receive(:build_env_for).and_call_original
      warm = as_loader([sig], cache_store: store)
      expect { warm.prewarm }.not_to output(/definition build failed/).to_stderr
      assert_collection_wins(warm, sig)
      expect(Rigor::Environment::RbsLoader).not_to have_received(:build_env_for)
    end
  end

  it "keeps the vendored base under another source's overload continuation" do
    Dir.mktmpdir do |dir|
      sig = write_sig(dir, "module PG\n  class Connection\n    def exec: (Symbol) -> Integer | ...\n  end\nend\n")
      loader = as_loader([sig])
      expect(types_of(loader, :exec).first).to eq("(::Symbol) -> ::Integer")
      expect(types_of(loader, :exec).size).to eq(3)
      expect(buffers_of(loader, :exec)).to eq([File.join(sig, "patch.rbs"), vendored_pg])
      # The vendored alias stays, and follows the continued method.
      expect(types_of(loader, :async_exec)).to eq(types_of(loader, :exec))
      expect(loader.definition_build_failures).to be_empty
    end
  end

  it "leaves out each member another source declares, and keeps an alias following the method it names" do
    Dir.mktmpdir do |dir|
      sig = write_sig(dir, "module PG\n  class Connection\n    def async_exec: (*untyped) -> untyped\n    " \
                           "def exec: (*untyped) -> Symbol\n  end\nend\n")
      loader = as_loader([sig])
      expect(types_of(loader, :exec)).to eq(["(*untyped) -> ::Symbol"])
      expect(types_of(loader, :async_exec)).to eq(["(*untyped) -> untyped"])
      # `alias query exec` follows the method it names, whichever source declares it.
      expect(types_of(loader, :query)).to eq(["(*untyped) -> ::Symbol"])
      expect(loader.definition_build_failures).to be_empty
    end
  end

  it "leaves every vendored directory on the batch path when no other source declares a vendored member" do
    Dir.mktmpdir do |dir|
      sig = write_sig(dir, "module PG\n  class Connection\n    def made_up: () -> Integer\n  end\nend\n")
      plan = Rigor::Environment::VendoredSignaturePlan.build(
        [Pathname(File.dirname(vendored_pg))], [File.join(sig, "patch.rbs")]
      )
      expect(plan.dirs).to be_empty
      loader = as_loader([sig])
      expect(types_of(loader, :made_up)).to eq(["() -> ::Integer"])
      expect(buffers_of(loader, :async_exec)).to eq([vendored_pg])
    end
  end

  # Review of #2600 — a member stands down only to a file that stays in the env. A taker the build quarantines
  # would otherwise leave the method with no declaration, and correct code would draw `call.undefined-method`.
  describe "when the file the member stood down to is quarantined" do
    {
      "a constant core or the vendored file already declares" =>
        "module PG\n  VERSION: String\n  class Connection\n    def async_exec: (*untyped) -> untyped\n  end\nend\n",
      "a class the vendored file declares as a class, written as a module" =>
        "module PG::Connection\n  def async_exec: (*untyped) -> untyped\nend\n"
    }.each do |shape, rbs|
      it "keeps the vendored member for #{shape}, uncached and through the cache alike" do
        Dir.mktmpdir do |dir|
          sig = write_sig(dir, rbs)
          store = Rigor::Cache::Store.new(root: File.join(dir, "cache"))
          loaders = [as_loader([sig]), as_loader([sig], cache_store: store), as_loader([sig], cache_store: store)]
          answers = loaders.map { |loader| [types_of(loader, :async_exec), buffers_of(loader, :async_exec)] }
          loaders.each do |loader|
            expect(loader.quarantined_signatures.map { |row| row.first.to_s }).to include(File.join(sig, "patch.rbs"))
          end
          expect(answers.first.first).to eq(types_of(as_loader([sig]), :exec))
          expect(answers.first.last).to eq([vendored_pg])
          expect(answers.uniq.size).to eq(1)
        end
      end
    end
  end

  it "reads a header that carries an annotation on the same line" do
    Dir.mktmpdir do |dir|
      # The file's only header naming a vendored type is annotated, so the pre-filter must read past it.
      sig = write_sig(dir, "%a{rigor:test} class PG::Connection\n  def async_exec: (*untyped) -> untyped\nend\n")
      loader = as_loader([sig])
      expect(buffers_of(loader, :async_exec)).to eq([File.join(sig, "patch.rbs")])
      expect(loader.definition_build_failures).to be_empty
    end
  end

  it "plans every `.rbs` under a vendored directory, as the loader's batch path reads it" do
    Dir.mktmpdir do |dir|
      root = File.join(dir, "vendored")
      FileUtils.mkdir_p(File.join(root, "nested"))
      File.write(File.join(root, "nested", "x.rbs"), "class VendoredX\n  def m: () -> Integer\nend\n")
      sig = write_sig(dir, "class VendoredX\n  def m: () -> String\nend\n")
      plan = Rigor::Environment::VendoredSignaturePlan.build([Pathname(root)], [File.join(sig, "patch.rbs")])
      expect(plan.dirs).to eq([Pathname(root)])
      expect(plan.sources.map { |buffer, _, _| buffer.name.to_s }).to eq([File.join(root, "nested", "x.rbs")])
      expect(plan.takers.to_a).to eq([File.join(sig, "patch.rbs")])
    end
  end
end
