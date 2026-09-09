# frozen_string_literal: true

require "spec_helper"
require "rigor/cache/rbs_descriptor"
require "rigor/cache/rbs_environment"
require "rigor/environment/rbs_loader"
require "fileutils"
require "tmpdir"

RSpec.describe Rigor::Cache::RbsDescriptor do
  let(:loader) { Rigor::Environment::RbsLoader.new }

  describe ".build_run (lazy-files run descriptor)" do
    it "carries the same gems + configs as the eager .build (the cache key is unchanged)" do
      eager = described_class.build(loader)
      run = described_class.build_run(loader)
      expect(run.gems).to eq(eager.gems)
      expect(run.configs).to eq(eager.configs)
    end

    it "does not digest the RBS signature tree until #files is read" do
      allow(described_class).to receive(:file_entries).and_call_original
      run = described_class.build_run(loader)

      # Building the descriptor + reading the key slots must NOT walk the signature tree.
      run.gems
      run.configs
      expect(described_class).not_to have_received(:file_entries)

      # The file entries are computed only on first #files access.
      entries = run.files
      expect(described_class).to have_received(:file_entries).once
      expect(entries).not_to be_empty
      # ADR-87 WD1 — the validation-only run descriptor rides the stat-then-digest `:stat` tier, while the
      # env-cache KEY descriptor (`.build`) keeps deterministic `:digest` entries over the same paths.
      expect(entries.map(&:comparator).uniq).to eq([:stat])
      expect(entries.map(&:path).sort).to eq(described_class.build(loader).files.map(&:path).sort)
    end

    it "memoises #files (a second read does not re-walk the tree)" do
      allow(described_class).to receive(:file_entries).and_call_original
      run = described_class.build_run(loader)
      first = run.files
      second = run.files
      expect(first).to equal(second)
      expect(described_class).to have_received(:file_entries).once
    end
  end

  # Issue #610 — which `signature_paths:` are DEFERRED (a bundled plugin's `sig/`, allowed to stand down
  # against a colliding generic arity) changes the env built from byte-identical files, so the env-cache
  # KEY carries the partition. The run-result key does not need it — it digests the whole configuration —
  # and its boot-slimming probe cannot rebuild a plugin-derived slot, so the shared `config_entries` stay
  # byte-identical between the two loaders.
  describe "the deferred partition" do
    it "changes the env-cache key and leaves the run key's shared slots alone" do
      Dir.mktmpdir do |dir|
        sig_dir = File.join(dir, "plugin_sig")
        Dir.mkdir(sig_dir)
        File.write(File.join(sig_dir, "relation.rbs"), "class Relation[Elem]\nend\n")
        eager = Rigor::Environment::RbsLoader.new(signature_paths: [sig_dir])
        deferred = Rigor::Environment::RbsLoader.new(signature_paths: [sig_dir], deferred_signature_paths: [sig_dir])

        expect(described_class.build(deferred)).not_to eq(described_class.build(eager))
        expect(described_class.build(deferred).configs.map(&:key)).to include("rbs.deferred_signature_paths")
        expect(described_class.build(eager).configs.map(&:key)).not_to include("rbs.deferred_signature_paths")
        expect(described_class.config_entries(deferred)).to eq(described_class.config_entries(eager))
        expect(described_class.build_run(deferred).configs).to eq(described_class.build_run(eager).configs)
      end
    end
  end

  # Issue #876 — {.build}'s digest IS the env-cache key, and this module is the loader's other cache-side
  # entry. The producer gate (`spec/rigor/cache/rbs_environment_spec.rb`, #864) reads `build_env_for`'s
  # keyword list off the method itself and proves `Cache::RbsEnvironment.compute` forwards every one; it
  # cannot see this side, which never calls `build_env_for` at all. An input that changes the built
  # environment and is not digested here shares a cache slot with the environment it should have replaced,
  # so the second configuration is served the first's marshalled env — silently, on every warm run. That is
  # #610's failure shape one layer down, and no gate watching the producer can catch it.
  #
  # The gate therefore pins the pairing itself: two loaders differing in exactly one `build_env_for` keyword
  # must build DIFFERENT environments and carry DIFFERENT env-cache keys. Reading the keyword list off the
  # method is what makes the next keyword fail here rather than ship — there is no expectation to update
  # when one is added, only a variation to supply.
  describe "the env-cache key's coverage of build_env_for's inputs" do
    let(:tmpdir) { Dir.mktmpdir("rigor-rbs-descriptor-digest-gate-") }
    # `plugin_sig_dir` declares the same class as `project_sig_dir` at a different generic arity: the pair
    # `add_deferred_signatures` was written for, and the only shape in which deferring a path changes the
    # env at all.
    let(:project_sig_dir) { sig_dir("project_sig", "collide.rbs", "class DigestGateCollide\nend\n") }
    let(:plugin_sig_dir) { sig_dir("plugin_sig", "collide.rbs", "class DigestGateCollide[Elem]\nend\n") }
    let(:extra_sig_dir) { sig_dir("extra_sig", "extra.rbs", "class DigestGateExtra\nend\n") }

    after { FileUtils.rm_rf(tmpdir) }

    def sig_dir(name, basename, content)
      path = File.join(tmpdir, name)
      FileUtils.mkdir_p(path)
      File.write(File.join(path, basename), content)
      path
    end

    # The keyword parameters of the loader's OWN `build_env_for`. Resolved past `RbsEnvMemo::Interception`,
    # which the suite prepends onto the same singleton with a mirrored signature: reading the mirror would
    # let a keyword added to the loader and to neither the memo nor this table pass unnoticed.
    def build_env_for_keywords
      owner = Rigor::Environment::RbsLoader.singleton_class
      method = owner.instance_method(:build_env_for)
      method = method.super_method until method.owner == owner
      method.parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }
    end

    # One `[base, varied]` pair per keyword. The base loader takes every keyword's FIRST value, so each pair
    # moves exactly one axis off a shared base. A pair whose two values build the same environment asserts
    # nothing about the digest, so the environment side is checked in the same example.
    def loader_variations
      {
        libraries: [[], ["pathname"]],
        signature_paths: [[project_sig_dir, plugin_sig_dir],
                          [project_sig_dir, plugin_sig_dir, extra_sig_dir]],
        virtual_rbs: [[], [["digest_gate_virtual.rbs", "class DigestGateVirtual\nend\n"]]],
        deferred_signature_paths: [[], [plugin_sig_dir]]
      }
    end

    # Keywords no value of which can change the built environment, and which therefore cannot invalidate a
    # cached one. Empty today. An entry here is a claim about the type universe — "every value of this
    # keyword builds the same env" — never a note that varying it in a spec is inconvenient: a keyword that
    # needs a file tree to vary gets the tree, the way `deferred_signature_paths` does above.
    def keywords_that_cannot_change_the_environment
      []
    end

    def loader_for(keywords)
      Rigor::Environment::RbsLoader.new(**keywords)
    end

    # Enough of the built env to tell the variations apart: which classes are declared, and how many
    # declarations each name carries — the deferred stand-down drops a declaration, not the name. Built from
    # the LOADER's readers (the keyword names double as them, as in the #864 producer gate), so what is
    # compared is the value the descriptor was handed, not the literal from the table.
    def env_fingerprint(loader)
      keywords = build_env_for_keywords.to_h { |keyword| [keyword, loader.public_send(keyword)] }
      env = Rigor::Environment::RbsLoader.build_env_for(**keywords)
      env.class_decls.map { |name, entry| [name.to_s, entry.each_decl.count] }.sort
    end

    def env_cache_key(loader)
      described_class.build(loader).cache_key_for(producer_id: Rigor::Cache::RbsEnvironment::PRODUCER_ID)
    end

    it "has a variation or an explicit exemption for every build_env_for keyword" do
      unclassified = build_env_for_keywords - loader_variations.keys - keywords_that_cannot_change_the_environment

      expect(unclassified).to be_empty,
                              "RbsLoader.build_env_for accepts #{unclassified.join(', ')}, which this gate " \
                              "neither varies nor exempts, so nothing proves the env-cache key moves when " \
                              "it does. Add a `[base, varied]` pair to `loader_variations` — a fixture " \
                              "tree if the value needs one — or exempt it with the reason it cannot " \
                              "change the built environment."
    end

    it "moves the env-cache key when any build_env_for input changes" do
      varied_keywords = build_env_for_keywords & loader_variations.keys
      base = loader_for(loader_variations.transform_values(&:first))
      base_fingerprint = env_fingerprint(base)
      base_key = env_cache_key(base)

      vacuous = []
      undigested = []
      varied_keywords.each do |keyword|
        loader = loader_for(loader_variations.transform_values(&:first)
                                             .merge(keyword => loader_variations.fetch(keyword).last))
        vacuous << keyword if env_fingerprint(loader) == base_fingerprint
        undigested << keyword if env_cache_key(loader) == base_key
      end

      aggregate_failures do
        expect(vacuous).to be_empty,
                           "The variation for #{vacuous.join(', ')} builds the same RBS environment as the " \
                           "base, so the digest assertion below proves nothing about it. Give it a value " \
                           "(or a fixture tree) that really changes the env."
        expect(undigested).to be_empty,
                              "RbsDescriptor.build does not digest #{undigested.join(', ')}: two loaders " \
                              "differing only there build different RBS environments and share one " \
                              "env-cache key, so whichever runs second is served the first's marshalled " \
                              "env forever. Digest the input (issue #876 — #610's failure shape on the " \
                              "cache-KEY side, which the producer gate cannot see)."
      end
    end
  end
end
