# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# The storage invariant of the two memos behind ADR-57 N5's overridable-method adoption gate.
# `ExpressionTyper#override_gate_buckets` and `#method_definers_index` are consulted on every adopted
# self-call return, so they have to be memoised; what they must NOT do is keep one entry per analysed
# file. A `Scope` merges its file's discovery with the project pre-pass, so an identity-keyed store
# grows an entry per file and — because the keys ARE the tables — pins every file's whole discovery
# index for the length of the run. `#method_definers_index` is the expensive half: each entry is a
# whole inverted `method_name -> [owner names]` index over a file's merged def table.
#
# None of that is visible to a diagnostic assertion: the answers stay correct and the run just holds
# more, which is why it survived until it was measured. These examples pin the shape instead, the way
# `class_graph_memo_slot_spec.rb` does for the sibling memo.
#
# The keys are read as literal Symbols because the `*_KEY` constants are `private_constant` — the spec
# deliberately reaches for the thread-locals, since the whole point is that no production caller can
# observe this.
RSpec.describe "override-gate memo storage" do
  def gate_key = :__rigor_overridable_method_gate__
  def index_key = :__rigor_method_definers_index__
  def index_alt_key = :__rigor_method_definers_index_alt__

  # Each file carries its own base/subclass pair with an overridden literal-returning method read
  # through implicit self, which is what drives a file's analysis into the gate. The read inside
  # `initialize` is deliberate: the ivar pre-pass types it under the PROJECT-SEED tables and `probe`
  # types it under the file's merged tables, so each file asks the memos under two different scopes.
  def write_project(dir, files)
    files.times do |i|
      File.write(File.join(dir, "f#{i}.rb"), <<~RUBY)
        class Base#{i}
          def flag = false

          def initialize
            @seen = flag
          end

          def probe
            return :off unless flag

            :on
          end
        end

        class Sub#{i} < Base#{i}
          def flag = true
        end
      RUBY
    end
  end

  def run_check(dir)
    configuration = Rigor::Configuration.new("paths" => [dir], "parallel" => { "workers" => 0 })
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
  end

  # Counts the inverted indexes the memo is holding, under EITHER shape: a store keeps one per def
  # table it ever saw, the bounded form keeps at most one per kind per way.
  def held_indexes
    ways = [Thread.current[index_key], Thread.current[index_alt_key]].compact
    return 0 if ways.empty?
    return ways.first.size if ways.first.is_a?(Hash)

    ways.sum { |way| way[2..].compact.size }
  end

  # Counts the gate's answer buckets the same way.
  def held_gate_buckets
    held = Thread.current[gate_key]
    return 0 if held.nil?
    return held.values.sum { |by_super| by_super.values.sum(&:size) } if held.is_a?(Hash)

    1
  end

  def clear_memos
    Thread.current[gate_key] = nil
    Thread.current[index_key] = nil
    Thread.current[index_alt_key] = nil
  end

  around do |example|
    clear_memos
    example.run
  ensure
    clear_memos
  end

  it "holds one gate slot keyed on the discovery index, whatever the file count" do
    Dir.mktmpdir do |dir|
      write_project(dir, 6)
      run_check(dir)

      slot = Thread.current[gate_key]
      # A store would be a Hash here, one bucket deep per file; the bound is the Array itself.
      expect(slot).to be_an(Array)
      expect(slot.size).to eq(2)
      expect(slot[0]).to be_a(Rigor::Scope::DiscoveryIndex)
      expect(slot[1].keys).to contain_exactly(:instance, :singleton)
    end
  end

  it "holds at most two definers ways, each keyed on the two def tables" do
    Dir.mktmpdir do |dir|
      write_project(dir, 6)
      run_check(dir)

      ways = [Thread.current[index_key], Thread.current[index_alt_key]].compact
      expect(ways.size).to be <= 2
      ways.each do |way|
        expect(way.size).to eq(4)
        expect(way[0]).to be_a(Hash)
        expect(way[1]).to be_a(Hash)
      end
      expect(held_indexes).to be <= 4
    end
  end

  # The positive control for both examples above: a memo that was never CONSULTED would also be
  # bounded, and a fixture whose gate never runs cannot tell "correctly bounded" from "never reached".
  it "serves the run's gate questions from those memos" do
    Dir.mktmpdir do |dir|
      write_project(dir, 6)
      run_check(dir)

      answers = Thread.current[gate_key][1]
      expect(answers[:instance]).not_to be_empty
      expect(held_indexes).to be > 0
    end
  end

  # Six files and two files must leave the same residue. This is the regression itself: under the old
  # stores both numbers grew with the first.
  it "does not grow with the file count" do
    two = nil
    six = nil
    Dir.mktmpdir do |dir|
      write_project(dir, 2)
      run_check(dir)
      two = [held_gate_buckets, held_indexes]
    end
    clear_memos
    Dir.mktmpdir do |dir|
      write_project(dir, 6)
      run_check(dir)
      six = [held_gate_buckets, held_indexes]
    end

    expect(six).to eq(two)
  end

  # The gate's key is the whole `DiscoveryIndex`, not the trio the walk is usually described by:
  # `#related_to_owner?` reaches `Scope#ancestor_name_candidates` and `#known_user_class?`, which read
  # `discovered_header_nestings` and `discovered_methods` too. A narrower key would let an index that
  # swapped only one of those serve an answer computed against the old table.
  it "replaces the gate slot when the discovery index changes even if the walked trio is shared" do
    Dir.mktmpdir do |dir|
      write_project(dir, 2)
      run_check(dir)
      index = Thread.current[gate_key][0]
      bucket = Thread.current[gate_key][1]

      environment = Rigor::Environment.new(rbs_loader: Rigor::Environment::RbsLoader.default)
      scope = Rigor::Scope.new(environment: environment, locals: {}).with_discovery(index)
      expect(Rigor::Inference::ExpressionTyper.new(scope: scope).send(:override_gate_buckets)).to be(bucket)

      # Same three walked tables, a different index object.
      shifted = scope.with_discovery(index.with(discovered_methods: index.discovered_methods.dup))
      shifted_bucket = Rigor::Inference::ExpressionTyper.new(scope: shifted).send(:override_gate_buckets)
      expect(shifted_bucket).not_to be(bucket)
      expect(Thread.current[gate_key][0]).to be(shifted.discovery)
    end
  end

  # The definers memo is keyed the other way round on purpose: `#build_method_definers_index` reads the
  # one table it is handed, so the def tables are the complete key AND a narrower one than the index
  # object, which the project-seed scope replaces per file while its def tables stay put. Widening this
  # key to the `DiscoveryIndex` would rebuild the seed's table once per file.
  it "serves the definers index across discovery indexes that share the def tables" do
    Dir.mktmpdir do |dir|
      write_project(dir, 2)
      run_check(dir)
      index = Thread.current[index_key]
      def_nodes = index[0]

      environment = Rigor::Environment.new(rbs_loader: Rigor::Environment::RbsLoader.default)
      discovery = Thread.current[gate_key][0]
      scope = Rigor::Scope.new(environment: environment, locals: {}).with_discovery(discovery)
      typer = Rigor::Inference::ExpressionTyper.new(scope: scope)
      first = typer.send(:method_definers_index, :instance)

      # A different `DiscoveryIndex` carrying the SAME def tables must not rebuild the index.
      shifted = scope.with_discovery(discovery.with(discovered_methods: discovery.discovered_methods.dup))
      second = Rigor::Inference::ExpressionTyper.new(scope: shifted).send(:method_definers_index, :instance)
      expect(second).to be(first)
      expect(Thread.current[index_key][0]).to be(def_nodes)
    end
  end
end
