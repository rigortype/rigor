# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# The class-graph memo's storage invariant. `ExpressionTyper#class_graph_buckets` is consulted once per
# call site of a project class, so it has to be memoised; what it must NOT do is keep one bucket per
# analysed file. A `Scope` merges its file's discovery with the project pre-pass, so an identity-keyed
# store grows a bucket per file and — because the key IS the index — pins every file's whole discovery
# index for the length of the run. That is invisible to every diagnostic assertion in the suite: the
# answers stay correct and the run just holds more, which is why it survived until it was measured.
#
# These examples pin the shape instead: ONE slot, keyed on the `DiscoveryIndex` identity. The sibling
# memos bounded the same way (`MethodDispatcher::RbsDispatch`'s `core_stdlib_memo`,
# `Reflection.ancestor_constant_scopes`) have the same invariant.
#
# The key is read as a literal Symbol because `CLASS_GRAPH_CACHE_KEY` is a `private_constant` — the
# spec deliberately reaches for the thread-local rather than a public accessor, since the whole point is
# that no production caller can observe this.
RSpec.describe "class-graph memo storage" do
  def slot_key = :__rigor_class_graph_cache__

  # Every file gets its own class pair so every file's analysis drives the ancestor walk through its own
  # merged discovery index — which is exactly the condition that grew the old store.
  def write_project(dir, files)
    files.times do |i|
      File.write(File.join(dir, "f#{i}.rb"), <<~RUBY)
        class Base#{i}
          def value
            #{i}
          end
        end

        class Child#{i} < Base#{i}
        end

        Child#{i}.new.value
      RUBY
    end
  end

  def run_check(dir)
    configuration = Rigor::Configuration.new("paths" => [dir], "parallel" => { "workers" => 0 })
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    guarded_run(runner)
    runner
  end

  around do |example|
    Thread.current[slot_key] = nil
    example.run
  ensure
    Thread.current[slot_key] = nil
  end

  it "holds one slot after a multi-file run, whatever the file count" do
    Dir.mktmpdir do |dir|
      write_project(dir, 6)
      run_check(dir)

      slot = Thread.current[slot_key]
      # A store would be a Hash here, one bucket deep per file; the bound is the Array itself.
      expect(slot).to be_an(Array)
      expect(slot.size).to eq(2)
      expect(slot[0]).to be_a(Rigor::Scope::DiscoveryIndex)
      expect(slot[1].keys).to include(:name, :user_def)
    end
  end

  # The positive control for the example above: a bounded slot that was never CONSULTED would also be a
  # one-element Array, and a fixture whose walk never runs cannot tell "correctly bounded" from "never
  # reached". This asserts the memo really did serve the run's ancestor walks.
  it "serves the run's ancestor walks from that slot" do
    Dir.mktmpdir do |dir|
      write_project(dir, 6)
      run_check(dir)

      bucket = Thread.current[slot_key][1]
      expect(bucket[:user_def]).not_to be_empty
    end
  end

  # Six files and two files must leave the same residue. This is the regression itself: under the old
  # store the second number grew with the first.
  it "does not grow with the file count" do
    two = nil
    six = nil
    Dir.mktmpdir do |dir|
      write_project(dir, 2)
      run_check(dir)
      two = Thread.current[slot_key].size
    end
    Thread.current[slot_key] = nil
    Dir.mktmpdir do |dir|
      write_project(dir, 6)
      run_check(dir)
      six = Thread.current[slot_key].size
    end

    expect(six).to eq(two)
  end

  # The key is the whole `DiscoveryIndex`, not the three tables the walk is usually described by: the
  # ancestor-name resolver also reads `discovered_header_nestings` and `discovered_methods`
  # (`Scope#ancestor_name_candidates` / `#known_user_class?`). A narrower key would let an index that
  # swapped only one of those serve a name resolution computed against the old table.
  it "replaces the slot when the discovery index changes even if the walked tables are shared" do
    Dir.mktmpdir do |dir|
      write_project(dir, 2)
      run_check(dir)
      slot = Thread.current[slot_key]
      index = slot[0]
      bucket = slot[1]

      environment = Rigor::Environment.new(rbs_loader: Rigor::Environment::RbsLoader.default)
      scope = Rigor::Scope.new(environment: environment, locals: {}).with_discovery(index)
      typer = Rigor::Inference::ExpressionTyper.new(scope: scope)
      expect(typer.send(:class_graph_buckets)).to be(bucket)

      # Same three walked tables, a different index object.
      shifted = scope.with_discovery(index.with(discovered_methods: index.discovered_methods.dup))
      shifted_bucket = Rigor::Inference::ExpressionTyper.new(scope: shifted).send(:class_graph_buckets)
      expect(shifted_bucket).not_to be(bucket)
      expect(Thread.current[slot_key][0]).to be(shifted.discovery)
    end
  end
end
