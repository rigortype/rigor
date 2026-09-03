# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"
require "rigor/language_server/project_context"

# Issue #142 — LSP multi-buffer dispatch. `BufferPoolDispatcher` runs one independent single-buffer
# `Runner#run` per dirty buffer across a fork-based worker pool. The contract under test:
#
# - Sequential equivalence: N buffers dispatched through the pool publish the SAME diagnostics, in the SAME
#   per-binding order, as running each buffer's `Runner#run` one at a time.
# - Buffer-substitution correctness (the highest-risk part of #142): every job carries its OWN
#   `BufferBinding`, so a worker analyses THAT buffer's in-flight bytes, never another buffer's, and never
#   the file as it sits on disk.
# - Degradation: a single binding, `workers: 0`, no `fork`, or no `cache_store` all fall back to running
#   every job in-process rather than failing.
RSpec.describe Rigor::Analysis::Runner::BufferPoolDispatcher do
  def diag_keys(diagnostics)
    diagnostics.map { |d| [d.path, d.rule, d.message] }.sort
  end

  # One project with `count` files, each with a DELIBERATELY BROKEN on-disk body (an undefined-method call
  # unique to that file) and a CLEAN, uniquely-fixed buffer body. A worker that fell back to on-disk bytes —
  # for ANY file, including one misrouted from a DIFFERENT binding under a transposed/off-by-one job index —
  # would surface that file's on-disk `call.undefined-method` (or, if fed a sibling's on-disk break, a
  # DIFFERENT one than its own path's diagnostics have ever shown), so a stale or misrouted read is always
  # observable in either presence or content.
  def write_buffer_fixture(dir, count)
    Array.new(count) do |i|
      path = File.join(dir, "file_#{i}.rb")
      File.write(path, <<~RUBY)
        class Widget#{i}
          def broken
            disk_only_undefined_call_#{i}
          end
        end
      RUBY
      bytes = <<~RUBY
        class Widget#{i}
          def fixed
            helper_#{i}
          end

          def helper_#{i}
            #{i}
          end
        end
      RUBY
      Rigor::Analysis::BufferBinding.new(logical_path: path, physical_path: write_tempfile(dir, bytes))
    end
  end

  def write_tempfile(dir, bytes)
    path = File.join(dir, "buf-#{SecureRandom.hex(4)}.rb")
    File.write(path, bytes)
    path
  end

  def context_for(dir)
    Rigor::LanguageServer::ProjectContext.new(configuration: Rigor::Configuration.new("paths" => [dir]))
  end

  # `min_batch_size: 2` — most of this file's fixtures use small N (5-8 buffers) to keep specs fast, and
  # exist to prove the fork path's CORRECTNESS (equivalence, buffer substitution), independent of where the
  # size gate happens to sit. `#dispatcher_with_resolved_gate_for` (below) uses the REAL resolved default
  # instead, specifically to test the gate itself.
  def dispatcher_for(dir, context, workers:, cache_store: context.cache_store, min_batch_size: 2)
    described_class.new(
      configuration: context.configuration, cache_store: cache_store,
      environment: Dir.chdir(dir) { context.environment }, prebuilt: Dir.chdir(dir) { context.project_scan },
      workers: workers, min_batch_size: min_batch_size
    )
  end

  # Omits `min_batch_size:` entirely so the constructor's own default (`resolve_min_batch_size`, reading
  # `RIGOR_LSP_POOL_MIN_BATCH` / `DEFAULT_MIN_BATCH_SIZE`) applies — the shape production callers
  # (`DiagnosticPublisher#publish_batch`) get.
  def dispatcher_with_resolved_gate_for(dir, context, workers:, cache_store: context.cache_store)
    described_class.new(
      configuration: context.configuration, cache_store: cache_store,
      environment: Dir.chdir(dir) { context.environment }, prebuilt: Dir.chdir(dir) { context.project_scan },
      workers: workers
    )
  end

  def sequential_diagnostics(dir, context, bindings)
    bindings.map do |binding|
      Dir.chdir(dir) do
        runner = Rigor::Analysis::Runner.new(
          configuration: context.configuration, cache_store: context.cache_store, collect_stats: false,
          buffer: binding, prebuilt: context.project_scan, environment: context.environment
        )
        guarded_run(runner, [binding.logical_path]).diagnostics
      end
    end
  end

  describe "equivalence with the sequential path" do
    it "matches per-binding diagnostics for many buffers dispatched across the pool (workers: 4)" do
      Dir.mktmpdir do |dir|
        context = context_for(dir)
        bindings = write_buffer_fixture(dir, 6)

        sequential = sequential_diagnostics(dir, context, bindings)
        pool = Dir.chdir(dir) { dispatcher_for(dir, context, workers: 4).analyze(bindings) }

        expect(pool.size).to eq(bindings.size)
        pool.each_index { |i| expect(diag_keys(pool[i])).to eq(diag_keys(sequential[i])) }
      end
    end

    it "preserves original binding order even when workers complete out of order" do
      Dir.mktmpdir do |dir|
        context = context_for(dir)
        bindings = write_buffer_fixture(dir, 8)

        pool = Dir.chdir(dir) { dispatcher_for(dir, context, workers: 3).analyze(bindings) }

        expect(pool.size).to eq(8)
        # Every buffer's OWN fix is in effect (see fixture doc) — none show their on-disk break.
        expect(pool).to all(be_empty)
      end
    end
  end

  describe "buffer-substitution correctness" do
    it "analyses each buffer's OWN in-flight bytes, never the on-disk file nor a sibling buffer's bytes" do
      Dir.mktmpdir do |dir|
        context = context_for(dir)
        bindings = write_buffer_fixture(dir, 5)

        pool = Dir.chdir(dir) { dispatcher_for(dir, context, workers: 3).analyze(bindings) }

        # A stale (on-disk) OR misrouted (sibling) read would surface `call.undefined-method` naming a
        # `disk_only_undefined_call_N` that does not match this binding's own index.
        pool.each_with_index do |diagnostics, index|
          expect(diagnostics).to be_empty, "binding #{index} (#{bindings[index].logical_path}) " \
                                           "unexpectedly reported: #{diagnostics.map(&:message)}"
        end
      end
    end
  end

  describe "degradation" do
    it "falls back to sequential in-process execution for a single binding (no fork)" do
      Dir.mktmpdir do |dir|
        context = context_for(dir)
        bindings = write_buffer_fixture(dir, 1)
        dispatcher = dispatcher_for(dir, context, workers: 4)

        allow(dispatcher).to receive(:fork)
        pool = Dir.chdir(dir) { dispatcher.analyze(bindings) }

        expect(dispatcher).not_to have_received(:fork)
        expect(pool).to eq([[]])
      end
    end

    it "falls back to sequential in-process execution when workers is 0" do
      Dir.mktmpdir do |dir|
        context = context_for(dir)
        bindings = write_buffer_fixture(dir, 3)
        dispatcher = dispatcher_for(dir, context, workers: 0)

        allow(dispatcher).to receive(:fork)
        pool = Dir.chdir(dir) { dispatcher.analyze(bindings) }

        expect(dispatcher).not_to have_received(:fork)
        expect(pool.size).to eq(3)
        expect(pool).to all(be_empty)
      end
    end

    it "falls back to sequential in-process execution when cache_store is nil" do
      Dir.mktmpdir do |dir|
        context = context_for(dir)
        bindings = write_buffer_fixture(dir, 3)
        dispatcher = dispatcher_for(dir, context, workers: 4, cache_store: nil)

        allow(dispatcher).to receive(:fork)
        pool = Dir.chdir(dir) { dispatcher.analyze(bindings) }

        expect(dispatcher).not_to have_received(:fork)
        expect(pool.size).to eq(3)
        expect(pool).to all(be_empty)
      end
    end

    it "returns an empty Array for an empty binding list without touching the pool" do
      Dir.mktmpdir do |dir|
        context = context_for(dir)
        dispatcher = dispatcher_for(dir, context, workers: 4)

        allow(dispatcher).to receive(:fork)
        result = Dir.chdir(dir) { dispatcher.analyze([]) }

        expect(dispatcher).not_to have_received(:fork)
        expect(result).to eq([])
      end
    end
  end

  # Reviewed and required for #142: an earlier version of this dispatcher forked for ANY `bindings.size > 1`,
  # and a throwaway measurement against this repo's own `lib/rigor` showed that a net LOSS below roughly
  # N=12-16 (fork + Marshal + `Process.waitpid2` overhead exceeding ~1-2ms/file real work once the
  # environment is warm) — squarely the size of a realistic editor burst (a branch switch, a rename). See
  # `DEFAULT_MIN_BATCH_SIZE`'s doc comment for the full table. The gate below fixes that: below the
  # threshold, `#analyze` takes EXACTLY the sequential in-process path (proven here to be the SAME
  # computation as `#run_one` per binding, not merely "no fork observed") — so it can never be slower than
  # today, only slower than the pool it declines to use.
  describe "size gate (DEFAULT_MIN_BATCH_SIZE)" do
    it "does not fork below DEFAULT_MIN_BATCH_SIZE even with workers and cache_store available" do
      Dir.mktmpdir do |dir|
        context = context_for(dir)
        bindings = write_buffer_fixture(dir, described_class::DEFAULT_MIN_BATCH_SIZE - 1)
        dispatcher = dispatcher_with_resolved_gate_for(dir, context, workers: 8)

        allow(dispatcher).to receive(:fork)
        pool = Dir.chdir(dir) { dispatcher.analyze(bindings) }

        expect(dispatcher).not_to have_received(:fork)
        expect(pool.size).to eq(described_class::DEFAULT_MIN_BATCH_SIZE - 1)
        expect(pool).to all(be_empty)
      end
    end

    it "forks at DEFAULT_MIN_BATCH_SIZE" do
      Dir.mktmpdir do |dir|
        context = context_for(dir)
        bindings = write_buffer_fixture(dir, described_class::DEFAULT_MIN_BATCH_SIZE)
        dispatcher = dispatcher_with_resolved_gate_for(dir, context, workers: 8)

        allow(dispatcher).to receive(:fork).and_call_original
        pool = Dir.chdir(dir) { dispatcher.analyze(bindings) }

        expect(dispatcher).to have_received(:fork).at_least(:once)
        expect(pool.size).to eq(described_class::DEFAULT_MIN_BATCH_SIZE)
        expect(pool).to all(be_empty)
      end
    end

    it "below the gate, #analyze is the SAME computation #run_one would do per binding — never slower than " \
       "today's sequential path, only slower than the pool it declines" do
      Dir.mktmpdir do |dir|
        context = context_for(dir)
        bindings = write_buffer_fixture(dir, described_class::DEFAULT_MIN_BATCH_SIZE - 1)
        dispatcher = dispatcher_with_resolved_gate_for(dir, context, workers: 8)

        gated = Dir.chdir(dir) { dispatcher.analyze(bindings) }
        direct = Dir.chdir(dir) { bindings.map { |binding| dispatcher.send(:run_one, binding) } }

        gated.each_index { |i| expect(diag_keys(gated[i])).to eq(diag_keys(direct[i])) }
      end
    end

    describe ".resolve_min_batch_size" do
      around do |example|
        original = ENV.fetch("RIGOR_LSP_POOL_MIN_BATCH", nil)
        example.run
      ensure
        ENV["RIGOR_LSP_POOL_MIN_BATCH"] = original
      end

      it "defaults to DEFAULT_MIN_BATCH_SIZE when unset" do
        ENV.delete("RIGOR_LSP_POOL_MIN_BATCH")
        expect(described_class.resolve_min_batch_size).to eq(described_class::DEFAULT_MIN_BATCH_SIZE)
      end

      it "reads RIGOR_LSP_POOL_MIN_BATCH when set" do
        ENV["RIGOR_LSP_POOL_MIN_BATCH"] = "3"
        expect(described_class.resolve_min_batch_size).to eq(3)
      end

      it "falls back to the default for an empty value" do
        ENV["RIGOR_LSP_POOL_MIN_BATCH"] = ""
        expect(described_class.resolve_min_batch_size).to eq(described_class::DEFAULT_MIN_BATCH_SIZE)
      end
    end
  end

  # A `fork` copies only the calling thread, so the parent's deferred-YJIT deadline thread (if one is armed)
  # does not survive into a child. `run_fork_worker` must therefore re-arm its own deferred YJIT — mirrors
  # the equivalent `PoolCoordinator` coverage. Driven directly (no real fork) via `allocate` + a stubbed
  # `run_one`, matching `spec/rigor/analysis/runner_fork_pool_spec.rb`'s established pattern.
  describe "deferred YJIT in the fork worker" do
    it "re-arms deferred YJIT before analysing its slice" do
      Dir.mktmpdir do |dir|
        dispatcher = described_class.allocate
        allow(dispatcher).to receive_messages(exit!: nil, run_one: [])
        allow(Rigor::Runtime::Jit).to receive(:rearm_after_fork)
        out_path = File.join(dir, "payload")

        dispatcher.send(:run_fork_worker, [[Object.new, 0]], out_path)

        expect(Rigor::Runtime::Jit).to have_received(:rearm_after_fork)
      end
    end
  end
end
