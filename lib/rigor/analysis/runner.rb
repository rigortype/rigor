# frozen_string_literal: true

require "prism"

require_relative "../environment"
require_relative "../scope"
require_relative "../cache/store"
require_relative "../plugin"
require_relative "../reflection"
require_relative "../type/combinator"
require_relative "../inference/coverage_scanner"
require_relative "../inference/scope_indexer"
require_relative "../inference/method_dispatcher/file_folding"
require_relative "check_rules"
require_relative "diagnostic"
require_relative "result"

module Rigor
  module Analysis
    class Runner # rubocop:disable Metrics/ClassLength
      RUBY_GLOB = "**/*.rb"
      DEFAULT_CACHE_ROOT = ".rigor/cache"

      attr_reader :cache_store, :plugin_registry

      # @param configuration [Rigor::Configuration]
      # @param explain [Boolean] surface fail-soft fallback events
      #   as `:info` diagnostics.
      # @param cache_store [Rigor::Cache::Store, nil] the persistent
      #   cache the runner exposes to producers (`RbsConstantTable`
      #   and successors). Pass `nil` to disable caching for this
      #   run; the CLI's `--no-cache` flag wires `nil` through.
      #   v0.0.9 group A slice 1 introduces the surface; later
      #   slices route real producers through it.
      def initialize(configuration:, explain: false,
                     cache_store: Cache::Store.new(root: DEFAULT_CACHE_ROOT),
                     plugin_requirer: nil)
        @configuration = configuration
        @explain = explain
        @cache_store = cache_store
        @plugin_requirer = plugin_requirer
        @plugin_registry = Plugin::Registry::EMPTY
      end

      # Walks every Ruby file under `paths`, parses it, builds a
      # per-node scope index through
      # `Rigor::Inference::ScopeIndexer`, and runs the
      # `Rigor::Analysis::CheckRules` catalogue over it. Returns
      # a `Rigor::Analysis::Result` aggregating every produced
      # diagnostic plus any Prism parse errors. The Environment
      # is built once at run start through `Environment.for_project`
      # so all files share the same RBS load.
      def run(paths = @configuration.paths)
        Inference::MethodDispatcher::FileFolding.fold_platform_specific_paths =
          @configuration.fold_platform_specific_paths

        environment = Environment.for_project(
          libraries: @configuration.libraries,
          signature_paths: @configuration.signature_paths,
          cache_store: @cache_store
        )

        @plugin_registry = load_plugins
        expansion = expand_paths(paths)

        diagnostics = plugin_load_diagnostics
        diagnostics += expansion.fetch(:errors)
        diagnostics += expansion.fetch(:files).flat_map { |path| analyze_file(path, environment) }

        Result.new(diagnostics: diagnostics)
      end

      private

      # Loads project-configured plugins through {Rigor::Plugin::Loader}
      # and returns the resulting {Rigor::Plugin::Registry}. Loader
      # failures are isolated: each surfaces as a `:plugin_loader`
      # diagnostic on the run's `Result` rather than aborting the
      # analysis. Plugins that load successfully but contribute no
      # protocol hooks are inert in slice 1; later v0.1.0 slices
      # wire the contribution merger through this registry.
      def load_plugins
        return Plugin::Registry::EMPTY if @configuration.plugins.empty?

        services = Plugin::Services.new(
          reflection: Reflection,
          type: Type::Combinator,
          configuration: @configuration,
          cache_store: @cache_store,
          trust_policy: build_trust_policy
        )
        if @plugin_requirer
          Plugin::Loader.load(configuration: @configuration, services: services, requirer: @plugin_requirer)
        else
          Plugin::Loader.load(configuration: @configuration, services: services)
        end
      end

      # Builds the {Rigor::Plugin::TrustPolicy} for this run. Trusted
      # gems are the gem-name half of every entry in
      # `Configuration#plugins`. Allowed read roots default to the
      # project root (CWD), the project's signature_paths, and each
      # trusted gem's `Gem::Specification#full_gem_path`, plus any
      # extras the user listed under `plugins_io.allowed_paths`.
      # Slice 2 keeps `network_policy` `:disabled` — the only value
      # the configuration accepts today.
      def build_trust_policy
        trusted_gems = @configuration.plugins.map { |entry| trusted_gem_name(entry) }.uniq
        roots = [Dir.pwd]
        Array(@configuration.signature_paths).each { |sp| roots << File.expand_path(sp) }
        trusted_gems.each do |gem_name|
          path = trusted_gem_root(gem_name)
          roots << path if path
        end
        @configuration.plugins_io_allowed_paths.each { |p| roots << File.expand_path(p) }

        Plugin::TrustPolicy.new(
          trusted_gems: trusted_gems,
          allowed_read_roots: roots,
          network_policy: @configuration.plugins_io_network
        )
      end

      def trusted_gem_name(entry)
        case entry
        when String then entry
        when Hash then entry["gem"] || entry["id"]
        end
      end

      def trusted_gem_root(gem_name)
        return nil if gem_name.nil? || gem_name.empty?

        spec = Gem.loaded_specs[gem_name]
        spec&.full_gem_path # rigor:disable undefined-method
      rescue StandardError
        nil
      end

      def plugin_load_diagnostics
        @plugin_registry.load_errors.map do |error|
          Diagnostic.new(
            path: ".rigor.yml",
            line: 1,
            column: 1,
            message: error.message,
            severity: :error,
            rule: "load-error",
            source_family: :plugin_loader
          )
        end
      end

      # ADR-7 § "Slice 5-A/5-B" — invokes every loaded plugin's
      # per-file diagnostic emission hook
      # (`Plugin::Base#diagnostics_for_file`) and re-stamps the
      # returned diagnostics with
      # `source_family: "plugin.<manifest.id>"` so plugin
      # authors cannot accidentally publish under another
      # plugin's identifier or under `:builtin`. Plugin
      # exceptions are isolated per ADR-2 § "Plugin Trust and
      # I/O Policy" — a raise from one plugin becomes a
      # `:plugin_loader` `runtime-error` diagnostic without
      # affecting other plugins or the rest of the run.
      def plugin_emitted_diagnostics(path, root, scope)
        return [] if @plugin_registry.empty?

        @plugin_registry.plugins.flat_map do |plugin|
          collect_plugin_diagnostics(plugin, path, root, scope)
        end
      end

      def collect_plugin_diagnostics(plugin, path, root, scope)
        raw = plugin.diagnostics_for_file(path: path, scope: scope, root: root)
        Array(raw).map { |diagnostic| stamp_plugin_diagnostic(diagnostic, plugin.manifest.id) }
      rescue StandardError => e
        [plugin_runtime_error_diagnostic(path, plugin, e)]
      end

      def stamp_plugin_diagnostic(diagnostic, plugin_id)
        Diagnostic.new(
          path: diagnostic.path,
          line: diagnostic.line,
          column: diagnostic.column,
          message: diagnostic.message,
          severity: diagnostic.severity,
          rule: diagnostic.rule,
          source_family: "plugin.#{plugin_id}"
        )
      end

      def plugin_runtime_error_diagnostic(path, plugin, error)
        plugin_id = safe_plugin_id(plugin)
        Diagnostic.new(
          path: path,
          line: 1,
          column: 1,
          message: "plugin #{plugin_id.inspect} raised during diagnostics_for_file: " \
                   "#{error.class}: #{error.message}",
          severity: :error,
          rule: "runtime-error",
          source_family: :plugin_loader
        )
      end

      def safe_plugin_id(plugin)
        plugin.manifest.id
      rescue StandardError
        plugin.class.to_s
      end

      # Resolves the user-supplied path list into:
      # - `:files`  — the concrete `.rb` files to analyze.
      # - `:errors` — `Diagnostic` entries for each path that
      #   does not exist or is not a recognisable Ruby source.
      #
      # Surfacing path errors is a first-preview must-have:
      # `rigor check ./does_not_exist.rb` previously exited
      # cleanly with no output, which silently masked typos.
      def expand_paths(paths)
        files = []
        errors = []
        Array(paths).each do |path|
          if File.directory?(path)
            files.concat(Dir.glob(File.join(path, RUBY_GLOB)))
          elsif File.file?(path) && path.end_with?(".rb")
            files << path
          elsif File.exist?(path)
            errors << path_error(path, "not a Ruby file (expected `.rb` or a directory)")
          else
            errors << path_error(path, "no such file or directory")
          end
        end
        { files: files, errors: errors }
      end

      def path_error(path, message)
        Diagnostic.new(
          path: path,
          line: 1,
          column: 1,
          message: message,
          severity: :error
        )
      end

      def analyze_file(path, environment) # rubocop:disable Metrics/MethodLength
        parse_result = Prism.parse_file(path)
        return parse_diagnostics(path, parse_result) unless parse_result.errors.empty?

        scope = Scope.empty(environment: environment)
        index = Inference::ScopeIndexer.index(parse_result.value, default_scope: scope)
        diagnostics = CheckRules.diagnose(
          path: path,
          root: parse_result.value,
          scope_index: index,
          comments: parse_result.comments,
          disabled_rules: @configuration.disabled_rules
        )
        diagnostics += plugin_emitted_diagnostics(path, parse_result.value, scope)
        diagnostics + explain_diagnostics(path, parse_result.value, scope)
      rescue Errno::ENOENT => e
        [
          Diagnostic.new(
            path: path,
            line: 1,
            column: 1,
            message: e.message,
            severity: :error
          )
        ]
      rescue StandardError => e
        [
          Diagnostic.new(
            path: path,
            line: 1,
            column: 1,
            message: "internal analyzer error: #{e.class}: #{e.message}",
            severity: :error
          )
        ]
      end

      # v0.0.2 #10 — fail-soft fallback explanation. When
      # `--explain` is set the runner additionally walks the
      # file with `Rigor::Inference::CoverageScanner` and emits
      # one `:info` diagnostic per directly-unrecognized node,
      # naming the node class and the type the engine fell back
      # to. The CoverageScanner is the canonical "first-event-
      # per-node" probe: it already filters out pass-through
      # wrappers (`ProgramNode`, `StatementsNode`,
      # `ParenthesesNode`) so the explain stream is attributable
      # to the leaf node that actually triggered the fallback.
      def explain_diagnostics(path, root, scope)
        return [] unless @explain

        result = Inference::CoverageScanner.new(scope: scope).scan(root)
        result.events.map { |event| explain_diagnostic(path, event) }
      end

      def explain_diagnostic(path, event)
        location = event.location
        line = location ? location.start_line : 1
        column = location ? location.start_column + 1 : 1
        Diagnostic.new(
          path: path,
          line: line,
          column: column,
          message: "fail-soft fallback at #{event.node_class}: #{event.inner_type.describe(:short)}",
          severity: :info,
          rule: "fallback"
        )
      end

      def parse_diagnostics(path, parse_result)
        parse_result.errors.map do |error|
          location = error.location
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            message: error.message,
            severity: :error
          )
        end
      end
    end
  end
end
