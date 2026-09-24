# frozen_string_literal: true

require "tmpdir"

require "rigor"
require "rigor/analysis/runner"

# `Hash#compare_by_identity` raises `FrozenError` on a frozen hash and changes how every later lookup matches its keys,
# but the effect classifier and the catalogue's `mutators: hash` read only `MutationWidening::HASH_MUTATORS`, which
# leaves it out on purpose: that table answers "the pair set changed", and `compare_by_identity` changes what a read
# answers instead (`HashLookupMutation::MUTATORS`, #1280). A method whose one effect was `@h.compare_by_identity`
# therefore summarised as effect-free. `default=` / `default_proc=` escaped the same gap only because the attribute
# writer rule claims every `foo=`, and `rehash` was in no table at all.
RSpec.describe "a Hash receiver mutation in an effect summary" do
  let(:hash_mutators) { Rigor::Effects::MutationClassifier::HASH_MUTATORS }

  describe "end to end" do
    def configuration
      data = { "paths" => ["lib"], "parallel" => { "workers" => 0 }, "effects" => {} }
      Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(data))
    end

    let(:table) do
      Dir.mktmpdir("rigor-hash-receiver-mutation-") do |dir|
        Dir.chdir(dir) do
          FileUtils.mkdir_p(%w[lib sig])
          File.write("lib/registry.rb", <<~RUBY)
            class Registry
              def initialize
                @h = {}
              end

              def by_identity
                @h.compare_by_identity
              end

              def by_identity?
                @h.compare_by_identity?
              end

              def rebuild
                @h.rehash
              end

              def adopt(table)
                table.compare_by_identity
              end

              def fresh
                {}.compare_by_identity
              end

              def memo
                @memo ||= Hash.new.compare_by_identity
              end
            end
          RUBY
          # The parameter needs a declared type: a class's mutator set applies only when the typer named the
          # receiver's class, and an untyped parameter is `Dynamic`.
          File.write("sig/registry.rbs", <<~RBS)
            class Registry
              @h: Hash[Symbol, Integer]

              def initialize: () -> void
              def by_identity: () -> Hash[Symbol, Integer]
              def by_identity?: () -> bool
              def rebuild: () -> Hash[Symbol, Integer]
              def adopt: (Hash[Symbol, Integer] table) -> Hash[Symbol, Integer]
              def fresh: () -> Hash[untyped, untyped]
              def memo: () -> Hash[untyped, untyped]
            end
          RBS

          runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
          guarded_run(runner, ["lib"])
          runner.effect_table
        end
      end
    end

    it "reads `@h.compare_by_identity` as mutate.self" do
      entry = table["Registry#by_identity"]

      expect(entry.proven.to_a).to eq(["mutate.self"])
      expect(entry).to be_exhaustive
    end

    # The predicate asks, and changes nothing. It is in no mutator set and is no attribute writer.
    it "reads `@h.compare_by_identity?` as nothing" do
      entry = table["Registry#by_identity?"]

      expect(entry.proven).to be_empty
      expect(entry).to be_exhaustive
    end

    it "reads `compare_by_identity` on a parameter as mutate.instance" do
      expect(table["Registry#adopt"].proven.to_a).to eq(["mutate.instance"])
    end

    it "reads `@h.rehash` as mutate.self" do
      expect(table["Registry#rebuild"].proven.to_a).to eq(["mutate.self"])
    end

    # `{}.compare_by_identity` is the common spelling of an identity hash, and once the call counted as a mutation
    # its receiver needed an owner: a bare `{}` is no local, so it read as `unknown-ownership` and every method
    # building one — `initialize` included, and through `.new` every constructor caller — stopped being exhaustive.
    # A receiver that is itself an allocation is one no caller can hold yet, so its mutation is frame-local.
    it "reads a mutation of a fresh allocation as mutate.local, and keeps the method exhaustive" do
      entry = table["Registry#fresh"]

      expect(entry.proven.to_a).to eq(["mutate.local"])
      expect(entry).to be_exhaustive
      expect(entry).to be_trivial
    end

    it "keeps an allocating receiver frame-local under an ivar memo" do
      entry = table["Registry#memo"]

      expect(entry.proven.to_a).to eq(%w[mutate.local mutate.self])
      expect(entry).to be_exhaustive
    end
  end

  describe "the Hash mutator set" do
    # An oracle that needs no list of names, as the String table's drift guard is: every public Hash method is called
    # on a frozen receiver under a handful of argument shapes, and the ones that raise `FrozenError` are the receiver
    # mutators. A mutator Ruby adds shows up here unprompted, whichever widening table it would belong to. The block
    # goes only to the argument-less shape, which is the one the iterating mutators (`delete_if`, `transform_keys!`)
    # need; with an argument it only draws warnings from readers (`any?(pattern) { }`, `fetch(k, d) { }`).
    it "lists exactly the methods that refuse a frozen receiver" do
      argument_shapes = [[], [:a], [0], [:a, 1], [{ b: 2 }]]
      refusing = CoreMethods.public_instance_methods(Hash).select do |name|
        [{ a: 1 }, {}].any? do |receiver|
          argument_shapes.any? do |arguments|
            block = arguments.empty? ? proc {} : nil
            receiver.dup.freeze.public_send(name, *arguments, &block)
            false
          rescue FrozenError
            true
          rescue StandardError, NotImplementedError
            false
          end
        end
      end

      expect(refusing).to match_array(hash_mutators.to_a)
    end

    # `data/builtins/ruby_core/hash.yml` tags a C body that checks its receiver for frozenness as `c_effects: mutate`:
    # an independent reading of the same surface, from CRuby's source rather than from calling it. `initialize_copy`
    # runs only on an object `dup` is still building, and `freeze` changes no content.
    it "lists every method the builtin catalogue saw check its receiver for frozenness" do
      path = File.expand_path("../../../data/builtins/ruby_core/hash.yml", __dir__)
      methods = YAML.safe_load_file(path, permitted_classes: [Symbol]).dig("classes", "Hash", "instance_methods")
      tagged = methods.select { |_, entry| Array(entry["c_effects"]).include?("mutate") }.keys

      expect(tagged - %w[initialize initialize_copy freeze] - hash_mutators.map(&:to_s)).to be_empty
    end

    # The two widening tables stay apart (they answer different questions of a `HashShape`), and the effect side reads
    # them as one. Neither is re-spelt here: a name added to either reaches the classifier and the catalogue with it.
    it "cites both widening tables rather than re-spelling them" do
      expect(hash_mutators).to be_superset(Rigor::Inference::MutationWidening::HASH_MUTATORS)
      expect(hash_mutators).to be_superset(Rigor::Inference::HashLookupMutation::MUTATORS)
      expect(hash_mutators - Rigor::Inference::MutationWidening::HASH_MUTATORS -
             Rigor::Inference::HashLookupMutation::MUTATORS).to eq(Set[:rehash])
    end

    # ADR-103 WD3: a posture's answer and the classifier's must come from one set, or the catalogued path and the
    # uncatalogued one would disagree about the same call.
    it "is the set the effect classifier and the effect catalogue read" do
      expect(Rigor::Effects::Catalog::MUTATOR_SETS.fetch("hash")).to equal(hash_mutators)

      classifier = Rigor::Effects::MutationClassifier.new(singleton: false, parameters: [], owned_locals: [])
      call = ->(name) { Prism.parse("h.#{name}(x)").value.statements.body.first }
      expect(hash_mutators.reject { |name| classifier.mutating?(call.call(name), "Hash") }).to be_empty
      expect(classifier.mutating?(call.call(:compare_by_identity?), "Hash")).to be(false)

      catalog = Rigor::Effects::Catalog.default
      expect(catalog.lookup("Hash", "compare_by_identity").mutates_receiver?).to be(true)
      expect(catalog.lookup("Hash", "compare_by_identity?").mutates_receiver?).to be(false)
    end
  end
end
