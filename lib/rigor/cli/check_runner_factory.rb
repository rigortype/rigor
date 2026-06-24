# frozen_string_literal: true

require_relative "../analysis/runner"
require_relative "../cache/store"

module Rigor
  class CLI
    # Shared factory for building an {Analysis::Runner} from CLI option
    # hashes + a loaded {Configuration}.
    #
    # Extracted from {CheckCommand} so that `rigor doctor` and future
    # `describe --deep` can reuse the exact same runner-setup logic
    # (cache, workers, buffer, explain) without diverging from the
    # primary check path (ADR-77 WD3).
    module CheckRunnerFactory
      module_function

      # Builds a runner matching the configuration/plugin/cache resolution
      # that `rigor check` itself uses.
      #
      # @param configuration [Rigor::Configuration]
      # @param options [Hash] parsed CLI options (must contain at least
      #   `:no_cache`, `:explain`, `:stats`, `:workers`)
      # @param buffer [Rigor::Analysis::BufferBinding, nil]
      # @param cache_root [String]
      # @return [Rigor::Analysis::Runner]
      def build(configuration:, options:, buffer:, cache_root:)
        cache_store = if options.fetch(:no_cache)
                        nil
                      else
                        Cache::Store.new(
                          root: cache_root,
                          max_bytes: configuration.cache_max_bytes
                        )
                      end
        Analysis::Runner.new(
          configuration: configuration,
          explain: options.fetch(:explain),
          cache_store: cache_store,
          collect_stats: options.fetch(:stats),
          workers: resolve_workers(options, configuration),
          buffer: buffer
        )
      end

      # Resolves the worker count by precedence: CLI `--workers=N`
      # (most explicit) > env `RIGOR_RACTOR_WORKERS` > config
      # `.rigor.yml` `parallel.workers:` > 0 (sequential default).
      # Returns an Integer; non-numeric values raise so typos fail
      # loudly. CLI / env may pass a negative value — clamped to 0
      # (sequential) so a stray `-1` doesn't crash the pool spawn loop.
      def resolve_workers(options, configuration)
        cli_value = options[:workers]
        return [Integer(cli_value), 0].max if cli_value

        env_value = ENV.fetch("RIGOR_RACTOR_WORKERS", nil)
        return [Integer(env_value), 0].max if env_value && !env_value.empty?

        configuration.parallel_workers
      end
    end
  end
end
