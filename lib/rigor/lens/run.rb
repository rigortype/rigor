# frozen_string_literal: true

require_relative "file_reader"
require_relative "contract_reader"
require_relative "members"
require_relative "slot"
require_relative "../analysis/incremental_session"
require_relative "../cache/incremental_snapshot"
require_relative "../cache/store"
require_relative "../sig_gen/alias_index"
require_relative "../sig_gen/type_elaborator"

module Rigor
  module Lens
    # The check-equivalent computation behind `rigor lens` (docs/internal-spec/lens.md § Computation). The session
    # is the `--incremental` one rooted at the configuration's `paths:`, so it shares the snapshot with
    # `rigor check --incremental`; the targets are forced into the run and read inside it, on the seeded index.
    class Run
      # One target's answer: `status` is `ok` or a failure reason; the rest is set only for `ok`.
      Target = Data.define(:argument, :path, :absolute, :status, :reason, :reader, :diagnostics, :inputs)
      Outcome = Data.define(:targets, :member_rows)

      # @param root — the project root (absolute); every path in the answer is relative to it
      def initialize(configuration:, root:, arguments:, workers:)
        @configuration = configuration
        @root = root
        @arguments = arguments
        @argument_paths = arguments.to_set { |argument| File.expand_path(argument) }
        @workers = workers
        @captured = {}
        @contracts = {}
        @site_paths = {}
      end

      def call
        session = build_session
        project = session.project_files.to_h { |path| [File.expand_path(path), path] }
        resolved = @arguments.map { |argument| resolve(argument, project) }
        forced = resolved.filter_map { |entry| entry[:session_path] }
        session.force_targets = forced
        diagnostics = analyse(session, forced)
        targets = resolved.map { |entry| target(entry, diagnostics, session) }
        Outcome.new(targets: targets, member_rows: members(targets, session))
      end

      private

      def build_session
        cache_root = @configuration.cache_path
        Analysis::IncrementalSession.new(
          configuration: @configuration,
          cache_store: Cache::Store.new(root: cache_root, max_bytes: @configuration.cache_max_bytes),
          workers: @workers, on_file_indexed: method(:capture)
        )
      end

      # A cold run is a baseline; a pooled baseline indexes the targets in workers, where the callback never
      # runs, so one forced recheck in this process captures them.
      def analyse(session, forced)
        fingerprint = Cache::IncrementalSnapshot.fingerprint(configuration: @configuration,
                                                             roots: @configuration.paths)
        snapshot = Cache::IncrementalSnapshot.new(root: @configuration.cache_path)
        diagnostics, = session.run_incremental(snapshot: snapshot, fingerprint: fingerprint)
        missing = forced.reject { |path| @captured.key?(File.expand_path(path)) }
        diagnostics = session.recheck.diagnostics unless missing.empty?
        diagnostics
      end

      def resolve(argument, project)
        absolute = File.expand_path(argument)
        entry = { argument: argument, absolute: absolute, path: relative(absolute) }
        return entry.merge(status: "not_found", reason: "no such file") unless File.file?(absolute)
        return entry.merge(status: "not_ruby", reason: "not a Ruby source file") unless absolute.end_with?(".rb")

        session_path = project[absolute]
        return entry.merge(status: "outside_project", reason: "not under the configured paths:") unless session_path

        entry.merge(status: "ok", session_path: session_path)
      end

      def capture(path, parse_result, scope, index)
        absolute = File.expand_path(path)
        return unless @argument_paths.include?(absolute)

        reader = FileReader.new(path: relative(absolute), parse_result: parse_result, index: index,
                                spell: speller(scope.environment)).read
        reader.sites.each do |site|
          @site_paths[site.data["key"]] = absolute
          site.data["members"].each { |name| read_contract(site.data["owner"], site.data["scope"], name, scope) }
        end
        @captured[absolute] = reader
      end

      def read_contract(owner, member_scope, name, scope)
        key = [owner, member_scope, name]
        return if @contracts.key?(key)

        @contracts[key] = contract_reader(scope.environment).read(owner, member_scope.to_sym, name, scope)
      end

      def target(entry, diagnostics, session)
        base = { argument: entry[:argument], path: entry[:path], absolute: entry[:absolute], status: entry[:status],
                 reason: entry[:reason], reader: nil, diagnostics: nil, inputs: nil }
        return Target.new(**base) unless entry[:status] == "ok"

        reader = @captured[entry[:absolute]]
        own = diagnostics.select { |diagnostic| File.expand_path(diagnostic.path.to_s) == entry[:absolute] }
        if reader
          return Target.new(**base, reader: reader, diagnostics: own,
                                    inputs: inputs(session, entry[:session_path]))
        end

        Target.new(**base, **uncaptured(own))
      end

      # A forced target the run did not index: a file that does not parse stops before indexing.
      def uncaptured(own)
        if own.any? { |diagnostic| diagnostic.rule.nil? && diagnostic.severity == :error }
          { status: "parse_error", reason: "the file does not parse", diagnostics: own }
        else
          { status: "failed", reason: "the file was not analysed" }
        end
      end

      def inputs(session, session_path)
        rows = session.dependency_sources(session_path).filter_map do |source|
          absolute = File.expand_path(source)
          next if absolute == File.expand_path(session_path) || !File.file?(absolute)

          { "path" => relative(absolute), "digest" => Lens.digest(File.binread(absolute)) }
        end
        rows.sort_by { |input| input["path"] }
      end

      def members(targets, session)
        sites = targets.flat_map { |target| target.reader&.sites || [] }
        omissions = targets.flat_map { |target| target.reader&.omissions || [] }
        requested = targets.filter_map { |target| target.reader && target.absolute }.to_set
        Members.new(sites: sites, omissions: omissions, contracts: @contracts,
                    elsewhere: elsewhere(session, requested), site_paths: @site_paths).build
      end

      # Other project files that define a member, from the per-file discovery bundles the session keeps.
      def elsewhere(session, requested)
        bundles = session.seed_bundles
        lambda do |owner, scope, name|
          entries = bundles.filter_map do |path, bundle|
            absolute = File.expand_path(path)
            next if requested.include?(absolute)

            line = defined_line(bundle, owner, scope, name)
            line == false ? nil : { "path" => relative(absolute), "line" => line }
          end
          entries.sort_by { |entry| entry["path"] }
        end
      end

      # The line a bundle records for the member, nil when it defines the member without a recorded line (an
      # `attr_*`), or false when it does not define it.
      # A top-level `def` is recorded under discovery's own key, apart from `class Object`; both count for
      # `Object#name`.
      def defined_line(bundle, owner, scope, name)
        owners = if owner == "Object" && scope == "instance"
                   [owner,
                    Inference::ScopeIndexer::TOP_LEVEL_DEF_KEY]
                 else
                   [owner]
                 end
        owners.each do |key|
          line = defined_line_for(bundle, key, scope, name)
          return line unless line == false
        end
        false
      end

      def defined_line_for(bundle, owner, scope, name)
        table = scope == "singleton" ? bundle[:singleton_def_sources] : bundle[:def_sources]
        source = table&.dig(owner, name.to_sym)
        return Integer(source.to_s.split(":").last) if source

        kinds = bundle[:methods]&.dig(owner, name.to_sym)
        return false if kinds.nil?
        return nil if kinds == :both || kinds.to_s == scope

        false
      end

      def speller(environment)
        @alias_index ||= SigGen::AliasIndex.build(environment: environment, signature_paths: signature_roots,
                                                  excluded_paths: plugin_signature_paths(environment))
        lambda do |type, owner|
          @alias_index.fold(SigGen::TypeElaborator.elaborate(type, environment: environment).erase_to_rbs, owner)
        end
      end

      def contract_reader(environment)
        @contract_reader ||= ContractReader.new(
          Provenance.new(root: @root, signature_roots: signature_roots.map { |path| File.expand_path(path.to_s) },
                         plugin_roots: plugin_roots(environment))
        )
      end

      # `{absolute signature directory => plugin id}` for every loaded plugin that ships signatures.
      def plugin_roots(environment)
        plugins = environment&.plugin_registry&.plugins || []
        plugins.each_with_object({}) do |plugin, roots|
          Array(plugin.signature_paths).each { |path| roots[File.expand_path(path.to_s)] = plugin.manifest.id }
        end
      rescue StandardError
        {}
      end

      def signature_roots
        @signature_roots ||= Environment.project_signature_roots(@configuration.signature_paths)
      end

      def plugin_signature_paths(environment)
        environment&.plugin_registry&.signature_paths || []
      rescue StandardError
        []
      end

      def relative(absolute)
        Pathname(absolute).relative_path_from(Pathname(@root)).to_s
      end
    end
  end
end
