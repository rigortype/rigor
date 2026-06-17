# frozen_string_literal: true

module Rigor
  # Classifies each configured `signature_paths:` entry by what it
  # actually contributes to the RBS environment, so a caller can warn
  # when a configured path resolves to nothing.
  #
  # The failure this guards against is silent. {Environment::RbsLoader}
  # `add`s a `signature_paths:` entry only when `path.directory?`, and
  # only the `.rbs` files under it carry signatures — so a typo'd or
  # moved path (or a directory holding no `.rbs`) loads zero signatures
  # with no trace on stderr or in the run summary. The downstream symptom
  # is the most authoritative diagnostics: every call into the extensions
  # the missing RBS was meant to describe fires `call.undefined-method` at
  # `evidence_tier: high`. A one-character path typo can manufacture
  # hundreds of plausible-looking false positives; surfacing the empty
  # entry makes the real cause visible.
  #
  # The audit deliberately mirrors the loader's own acceptance test
  # (`path.directory?` + a recursive `**/*.rbs` glob) so a `:ok` verdict
  # means the loader did load from it and a warning means it did not.
  module SignaturePathAudit
    # One configured `signature_paths:` entry's resolution status.
    #
    # `status` is one of:
    # - `:ok`            — a directory containing at least one `.rbs`.
    # - `:missing`       — the path does not exist.
    # - `:not_directory` — the path exists but is not a directory (the
    #   loader only `add`s directories, so a `.rbs` file passed directly
    #   is silently ignored).
    # - `:empty`         — a directory with no `.rbs` file (recursive).
    Entry = Data.define(:path, :status, :rbs_file_count) do
      def ok?
        status == :ok
      end

      def warning?
        !ok?
      end

      # One-line, human-facing reason. The wording matches the loader's
      # actual behaviour ("loaded nothing from it") rather than the
      # filesystem error, so the message points at the consequence.
      def message
        case status
        when :missing
          "signature_paths: #{path.inspect} does not exist (no signatures loaded from it)"
        when :not_directory
          "signature_paths: #{path.inspect} is not a directory (no signatures loaded from it)"
        when :empty
          "signature_paths: #{path.inspect} matched 0 signature files"
        else
          "signature_paths: #{path.inspect} loaded #{rbs_file_count} signature file(s)"
        end
      end

      def to_h
        { "path" => path, "status" => status.to_s, "rbs_file_count" => rbs_file_count, "message" => message }
      end
    end

    # Audits each configured entry. `signature_paths` is the
    # {Configuration#signature_paths} array (absolute paths, already
    # resolved against the config file's directory). Pass `nil` — the
    # unset default, where Rigor auto-detects `<root>/sig` — to get an
    # empty result: an absent auto-detected `sig/` is a normal setup, not
    # a misconfiguration, so it is never audited.
    #
    # @param signature_paths [Array<String, Pathname>, nil]
    # @return [Array<Entry>]
    def self.audit(signature_paths)
      Array(signature_paths).map { |path| classify(path.to_s) }
    end

    # The subset of {audit} that resolved to nothing — the entries worth
    # warning about.
    #
    # @param signature_paths [Array<String, Pathname>, nil]
    # @return [Array<Entry>]
    def self.warnings(signature_paths)
      audit(signature_paths).select(&:warning?)
    end

    def self.classify(path)
      return Entry.new(path: path, status: :missing, rbs_file_count: 0) unless File.exist?(path)
      return Entry.new(path: path, status: :not_directory, rbs_file_count: 0) unless File.directory?(path)

      count = Dir.glob(File.join(path, "**", "*.rbs")).size
      Entry.new(path: path, status: count.zero? ? :empty : :ok, rbs_file_count: count)
    end
  end
end
