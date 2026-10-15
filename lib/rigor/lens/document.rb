# frozen_string_literal: true

require "json"

require_relative "../version"
require_relative "../cache/engine_source"
require_relative "../analysis/run_cache_key"

module Rigor
  module Lens
    # Assembles the `lens/v0` document (docs/internal-spec/lens.md § Document) from a {Run::Outcome}.
    class Document
      SITE_FIELDS = %w[key kind name owner scope attribute members module_function builder ordinal span contract_span
                       anchor visibility contract params block body_return value].freeze

      def initialize(outcome:, configuration:, root:, config_path:)
        @outcome = outcome
        @configuration = configuration
        @root = root
        @config_path = config_path
      end

      def to_h
        { "schema" => SCHEMA, "revision" => REVISION, "producer" => producer, "context" => context,
          "capabilities" => CAPABILITIES, "files" => @outcome.targets.map { |target| file(target) },
          "members" => @outcome.member_rows }
      end

      private

      def producer
        identity = begin
          Cache::EngineSource.process_identity
        rescue StandardError
          "unknown"
        end
        { "name" => "rigor", "version" => Rigor::VERSION, "engine_source" => identity }
      end

      def context
        fields = {
          "config" => @config_path && relative(File.expand_path(@config_path)),
          "target_ruby" => @configuration.target_ruby,
          "rbs_version" => rbs_version,
          "signature_roots" => signature_roots.map { |root| relative(root) },
          "signature_digest" => signature_digest,
          "plugins" => @outcome.plugins,
          "lockfiles" => lockfiles
        }
        fields.merge("digest" => Lens.digest(JSON.generate(fields)))
      end

      def rbs_version
        require "rbs"
        RBS::VERSION
      end

      def signature_roots
        Environment.project_signature_roots(@configuration.signature_paths).map { |path| File.expand_path(path.to_s) }
      end

      def signature_digest
        listing = signature_roots.flat_map { |root| Dir.glob(File.join(root, "**", "*.rbs")) }.sort.map do |path|
          "#{relative(path)}\t#{Lens.digest(File.binread(path))}\n"
        end
        Lens.digest(listing.join)
      end

      def lockfiles
        Analysis::RunCacheKey.resolved_lockfile_paths(@configuration).compact.filter_map do |path|
          absolute = File.expand_path(path.to_s)
          next unless File.file?(absolute)

          { "path" => relative(absolute), "digest" => Lens.digest(File.binread(absolute)) }
        end
      end

      # Every field is present; those that apply only to some statuses are null elsewhere (lens.md § Files).
      def file(target)
        read = %w[ok parse_error].include?(target.status)
        head = { "argument" => target.argument, "path" => target.status == "not_found" ? nil : target.path,
                 "status" => target.status, "reason" => target.status == "ok" ? nil : target.reason,
                 "digest" => file_digest(target, read) }
        head.merge(analysed_fields(target.status == "ok" ? target : nil))
            .merge("diagnostics" => read ? target.diagnostics.map { |diagnostic| diagnostic_row(diagnostic) } : nil)
            .merge("inputs" => target.status == "ok" ? target.inputs : nil)
      end

      # The digest of the bytes the analysis read; a file that did not parse is read once more.
      def file_digest(target, read)
        return nil unless read
        return target.reader.digest if target.reader

        Lens.digest(File.binread(target.absolute))
      end

      def analysed_fields(target)
        reader = target&.reader
        { "complete" => reader && reader.omissions.empty?, "omissions" => reader&.omissions,
          "sites" => reader&.sites&.map { |site| site.data.slice(*SITE_FIELDS) } }
      end

      def diagnostic_row(diagnostic)
        { "rule" => diagnostic.qualified_rule, "severity" => diagnostic.severity.to_s,
          "message" => diagnostic.message, "line" => diagnostic.line, "column" => diagnostic.column }
      end

      def relative(absolute)
        Pathname(absolute).relative_path_from(Pathname(@root)).to_s
      end
    end
  end
end
