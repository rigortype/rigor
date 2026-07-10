# frozen_string_literal: true

require "tmpdir"

module Rigor
  module Inference
    # Generic fork-over-slices map for the embarrassingly-parallel per-file passes of the
    # `rigor coverage --protection` path — the ADR-67 {ParameterInferenceCollector} rounds and the
    # {ProtectionScanner} scan (P3-10). The expensive shared state (the RBS environment, plugin registry,
    # seeded scope, parsed ASTs) is built ONCE on the parent; children copy-on-write inherit it and each map
    # a contiguous slice of `items` to a marshalable payload that the parent collects **in slice order**.
    #
    # A child that exits abnormally (crash, unmarshalable payload) has its slice re-run in-process, so the
    # returned array is identical to a plain sequential `[block.call(items)]` — order-preserving and
    # complete. Slice order is the caller's `items` order, so a caller that merges the payloads in array
    # order reproduces a sequential run byte-for-byte.
    #
    # This owns only the fork mechanics; the parent-side prewarm (forcing the RBS env to fully build so
    # children inherit it warm) and the payload merge are the caller's responsibility.
    module ForkMap
      module_function

      # @param items [Array] work items (file paths, or `[path, ast]` pairs), in caller order.
      # @param workers [Integer] resolved worker count (≤1, empty items, or no `fork` → sequential).
      # @yield [Array] a contiguous slice of `items`; must return a **marshalable** object.
      # @return [Array] the per-slice block results, in original slice order.
      def call(items:, workers:, &block)
        worker_count = [workers, items.size].min
        return [block.call(items)] unless parallel?(worker_count) && !items.empty?

        fork_map(items, worker_count, block)
      end

      def parallel?(worker_count)
        worker_count > 1 && Process.respond_to?(:fork)
      end

      # Forks `worker_count` children over contiguous slices, waits for each, and returns the Marshal'd
      # per-slice payloads in slice order. A child that exits abnormally has its slice re-run in-process.
      def fork_map(items, worker_count, block)
        slices = items.each_slice((items.size.to_f / worker_count).ceil).to_a
        payloads = Array.new(slices.size)

        Dir.mktmpdir("rigor-fork-map") do |tmpdir|
          children = slices.each_with_index.map do |slice, index|
            out_path = File.join(tmpdir, "worker-#{index}")
            { pid: fork { run_worker(slice, block, out_path) }, index: index, slice: slice, out_path: out_path }
          end
          collect(children, payloads, block)
        end

        payloads
      end

      # Child-process body: run the block over the slice, Marshal the result to `out_path`, and `exit!`
      # (skipping `at_exit` / stdio flush — the payload is durable on disk). Any failure exits non-zero so
      # the parent re-runs the slice in-process.
      def run_worker(slice, block, out_path)
        File.binwrite(out_path, Marshal.dump(block.call(slice)))
        exit!(0)
      rescue StandardError
        exit!(1)
      end

      # Waits for every child, placing each successful payload at its slice index; a child that exited
      # abnormally has its slice re-run in-process (identical to the sequential result).
      def collect(children, payloads, block)
        children.each do |child|
          _, status = Process.waitpid2(child[:pid])
          payload = worker_payload(status, child[:out_path])
          payloads[child[:index]] = payload.nil? ? block.call(child[:slice]) : payload.fetch(:value)
        end
      end

      # @return [Hash{value: Object}, nil] the child's payload wrapped so a legitimately-nil block result is
      #   distinguishable from an abnormal exit. `Marshal.load` is safe: the blob was written by our own
      #   forked child to a temp file we created.
      def worker_payload(status, out_path)
        return nil unless status.success? && File.exist?(out_path)

        { value: Marshal.load(File.binread(out_path)) } # rubocop:disable Security/MarshalLoad
      rescue StandardError
        nil
      end
    end
  end
end
