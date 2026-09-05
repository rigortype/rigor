# frozen_string_literal: true

require "yaml"

module Rigor
  module Analysis
    # ADR-22 Slice 1 — PHPStan-shaped per-project baseline.
    #
    # Loads `.rigor-baseline.yml`, filters a current run's diagnostic stream against the recorded buckets, and
    # emits an `(surfaced, silenced_count)` pair for the CLI to render.
    #
    # Two row shapes are accepted (WD1):
    #
    #   # rule-ID row — bucket key (path, qualified_rule)
    #   - file: app/models/user.rb
    #     rule: call.undefined-method
    #     count: 3
    #
    #   # message-pattern row — bucket key
    #   #   (path, qualified_rule, message_regex)
    #   - file: app/lib/sig.rb
    #     rule: call.undefined-method
    #     message: "undefined method `merge' for Array"
    #     count: 1
    #
    # ## Semantics per (file, rule [, message]) bucket (WD4)
    #
    #   actual <= count    → ALL diagnostics in the bucket are silenced.
    #   actual >  count    → ALL diagnostics in the bucket surface (not just the excess delta — the bucket has
    #                        crossed its threshold; the team's review focus shifts from "which N is new" to
    #                        "what's going on with this rule in this file as a whole").
    #
    # ## Filter pipeline position (WD6)
    #
    # The baseline filter runs LAST among the diagnostic-suppression layers:
    #
    #   emit →  `# rigor:disable` (per-line)
    #        →  `# rigor:disable-file`
    #        →  severity_profile re-stamp
    #        →  baseline filter (this class)
    #        →  output
    #
    # ## Loading (WD2 (b))
    #
    # `Baseline.load` is called by the CLI when it has resolved an explicit baseline path (from `--baseline=PATH`
    # on the CLI or `baseline: <path>` in `.rigor.yml`). The presence of `.rigor-baseline.yml` on disk alone
    # never triggers a load — that's the CLI / Configuration's job to enforce.
    #
    # ## Path handling
    #
    # Baselines store file paths **relative to the project root** (the working directory when `rigor` is run).
    # This makes the generated `.rigor-baseline.yml` portable across machines and checkout locations. When
    # filtering a live diagnostic stream, the instance normalises each diagnostic's absolute path to a relative
    # one before the bucket lookup.
    class Baseline
      # The bucket key is intentionally tuple-shaped so rule-ID rows and message-pattern rows can coexist in a
      # single multimap. `message` is `nil` for rule-ID rows; a Regexp for message-pattern rows.
      # `count` shadows Struct#count; intentional — `count` is the PHPStan-compatible field name and we don't
      # use the Enumerable-style `Struct#count` on Bucket instances.
      Bucket = Struct.new(:file, :rule, :message_regex, :count, keyword_init: true) # rubocop:disable Lint/StructNewOverride

      CURRENT_VERSION = 1

      class << self
        # Load a baseline file from disk. Returns `nil` when the path is nil (the caller's "no baseline
        # configured" state). Raises {LoadError} on malformed content; callers translate to a user-facing
        # diagnostic.
        #
        # `project_root:` is the working directory against which stored relative paths are resolved during
        # filtering. Defaults to `Dir.pwd`.
        def load(path, project_root: Dir.pwd)
          return nil if path.nil?
          return new([], project_root: project_root) unless File.exist?(path)

          raw = YAML.safe_load_file(path, permitted_classes: [Symbol])
          parse_loaded(raw, path: path, project_root: project_root)
        end

        # Build a baseline from a current run's diagnostic stream. `match_mode:` is `:rule` (default) or
        # `:message`. The message-mode generator passes literal messages through `Regexp.escape` so generated
        # rows never accidentally over-match on punctuation.
        #
        # `project_root:` is used to convert absolute diagnostic paths to relative paths in the generated YAML.
        # Defaults to `Dir.pwd`.
        def from_diagnostics(diagnostics, match_mode: :rule, project_root: Dir.pwd)
          raise ArgumentError, "match_mode must be :rule or :message" unless %i[rule message].include?(match_mode)

          grouped = group_for_baseline(diagnostics, match_mode, project_root)
          buckets = grouped.map do |key, entries|
            Bucket.new(
              file: key[0],
              rule: key[1],
              message_regex: key[2],
              count: entries.size
            )
          end
          new(buckets, project_root: project_root)
        end

        private

        def parse_loaded(raw, path:, project_root:)
          raise LoadError, "#{path}: expected a Hash at top level, got #{raw.class}" unless raw.is_a?(Hash)

          version = raw["version"]
          unless version == CURRENT_VERSION
            raise LoadError, "#{path}: unsupported `version: #{version.inspect}` (expected #{CURRENT_VERSION})"
          end

          rows = raw["ignored"] || []
          raise LoadError, "#{path}: `ignored:` must be an Array" unless rows.is_a?(Array)

          new(rows.each_with_index.map { |row, idx| parse_row(row, path: path, index: idx) },
              project_root: project_root)
        end

        def parse_row(row, path:, index:)
          raise LoadError, "#{path}: ignored[#{index}] must be a Hash" unless row.is_a?(Hash)

          file = row["file"] or raise LoadError, "#{path}: ignored[#{index}] missing `file:`"
          rule = row["rule"] or raise LoadError, "#{path}: ignored[#{index}] missing `rule:`"
          count = row["count"]
          unless count.is_a?(Integer) && count.positive?
            raise LoadError, "#{path}: ignored[#{index}] `count:` must be a positive Integer (got #{count.inspect})"
          end

          message_regex = nil
          if (message = row["message"])
            message_regex = compile_message_regex(message, path: path, index: index)
          end

          Bucket.new(file: file, rule: rule, message_regex: message_regex, count: count)
        end

        def compile_message_regex(source, path:, index:)
          Regexp.new(source.to_s)
        rescue RegexpError => e
          raise LoadError, "#{path}: ignored[#{index}] `message:` is not a valid Regexp: #{e.message}"
        end

        # Returns Hash{[file, rule, regex_or_nil] => Array<Diagnostic>}.
        # In message mode, each unique message gets its own bucket;
        # in rule mode, every diagnostic for a (file, rule) pair
        # contributes to a single bucket regardless of message.
        # File paths are normalised to relative before keying.
        def group_for_baseline(diagnostics, match_mode, project_root)
          root = Pathname.new(project_root)
          diagnostics.each_with_object({}) do |diag, into|
            next if diag.qualified_rule.nil?
            next if diag.path.nil?

            rel = relative_path(diag.path, root)
            key = case match_mode
                  when :rule
                    [rel, diag.qualified_rule, nil]
                  when :message
                    [rel, diag.qualified_rule, message_pattern_for(diag.message)]
                  end
            (into[key] ||= []) << diag
          end
        end

        # Generates a Regexp source string for the baseline row. The string is `Regexp.escape`d so the YAML
        # round-trip produces a regex that matches the literal message. Users hand-editing the row can replace
        # the escaped form with a pattern.
        def message_pattern_for(message)
          Regexp.new(Regexp.escape(message.to_s))
        end

        def relative_path(path, root_pathname)
          Pathname.new(path).relative_path_from(root_pathname).to_s
        rescue ArgumentError
          path # different drive letter on Windows or non-child path
        end
      end

      class LoadError < StandardError; end

      attr_reader :buckets

      def initialize(buckets, project_root: Dir.pwd)
        @project_root = Pathname.new(project_root)
        @buckets = buckets.freeze
        # For each (file, qualified_rule) pair, two arrays:
        # - rule-ID rows (message_regex == nil)
        # - message-pattern rows (message_regex != nil)
        # The matcher walks message-pattern rows first (tighter match takes precedence); diagnostics that
        # don't match any message row fall through to the rule-ID row if one exists.
        @by_pair = buckets.group_by { |b| [b.file, b.rule] }.freeze
        freeze
      end

      # Apply the baseline filter to a diagnostic stream.
      #
      # Returns a 2-tuple:
      # - `surfaced` — the diagnostics that survived the filter (new findings + entire over-threshold buckets).
      # - `silenced_count` — how many diagnostics the baseline suppressed (for the WD7 stderr summary line).
      def filter(diagnostics)
        return [diagnostics, 0] if buckets.empty?

        grouped = group_diagnostics_for_filtering(diagnostics)
        surfaced = []
        silenced_count = 0

        grouped.each_value do |entries|
          bucket = entries[:bucket]
          diags = entries[:diagnostics]
          # No matching bucket → all surface as new findings. `actual <= count` → all silenced (within
          # threshold, WD4). `actual >  count` → all surface (over threshold, WD4).
          if bucket && diags.size <= bucket.count
            silenced_count += diags.size
          else
            surfaced.concat(diags)
          end
        end

        # Diagnostics that lacked a rule or a path bypass the baseline entirely (the baseline can't address
        # them).
        unkeyable = diagnostics.reject { |d| d.qualified_rule && d.path }
        [surfaced + unkeyable, silenced_count]
      end

      # A single bucket's drift state for slice 2 inspection. `status` is one of:
      #
      # - `:within`    — `actual <= count` (silenced by the filter).
      # - `:over`      — `actual > count` (over threshold; surfaced in the regular `rigor check` output).
      # - `:cleared`   — `actual == 0` (the bucket can be pruned).
      # - `:reducible` — `0 < actual < count` (the bucket's count can be tightened; future `regenerate` slice 5
      #                  handles this).
      DriftRow = Struct.new(:bucket, :actual_count, :status, keyword_init: true) do
        def delta
          actual_count - bucket.count
        end
      end

      # Walk the current diagnostic stream and report bucket-level drift. Each baseline bucket becomes one
      # DriftRow regardless of whether the current run still matches it.
      #
      # @rbs diagnostics: Array[Diagnostic] --
      #   Current run's diagnostic stream (PRE-filter — pass the raw `result.diagnostics` from `Runner#run`, not the
      #   post-baseline surface).
      # @rbs return: Array[DriftRow] -- One entry per baseline bucket, in baseline-file order.
      def audit(diagnostics)
        counts = Hash.new(0)
        diagnostics.each do |diag|
          next if diag.qualified_rule.nil? || diag.path.nil?

          bucket = claim_bucket_for(diag)
          counts[bucket_key(bucket)] += 1 if bucket
        end

        buckets.map do |bucket|
          actual = counts[bucket_key(bucket)]
          DriftRow.new(bucket: bucket, actual_count: actual, status: status_for(actual, bucket.count))
        end
      end

      # Returns a new Baseline with the given buckets dropped. Used by `rigor baseline prune` (slice 2) to
      # remove cleared buckets (`actual == 0`) from the on-disk file.
      def without(buckets_to_drop)
        dropset = buckets_to_drop.to_set
        self.class.new(buckets.reject { |b| dropset.include?(b) }, project_root: @project_root)
      end

      # Serialise to a YAML string. The generator path writes this through `File.write`; the dump format is
      # stable across versions of this class as long as the bucket shape is unchanged.
      def to_yaml
        rows = buckets.map do |bucket|
          row = { "file" => bucket.file, "rule" => bucket.rule }
          row["message"] = bucket.message_regex.source if bucket.message_regex
          row["count"] = bucket.count
          row
        end

        document = { "version" => CURRENT_VERSION, "ignored" => rows }
        YAML.dump(document)
      end

      # The number of buckets recorded. Useful for the CLI summary on `generate`.
      def size
        buckets.size
      end

      def empty?
        buckets.empty?
      end

      private

      def status_for(actual, count)
        return :cleared if actual.zero?
        return :over if actual > count
        return :within if actual == count

        :reducible
      end

      def bucket_key(bucket)
        [bucket.file, bucket.rule, bucket.message_regex&.source]
      end

      def normalize_path(path)
        return path if path.nil?

        Pathname.new(path).relative_path_from(@project_root).to_s
      rescue ArgumentError
        path # different drive letter on Windows or non-child path
      end

      def group_diagnostics_for_filtering(diagnostics)
        # First pass: bin each diagnostic into the bucket that claims it. Message-pattern rows take precedence
        # over rule-ID rows because they're more specific. A diagnostic that matches no row goes into a
        # synthetic "no-bucket" bin keyed by (file, rule).
        bins = {}
        diagnostics.each do |diag|
          next if diag.qualified_rule.nil? || diag.path.nil?

          bucket = claim_bucket_for(diag)
          key = if bucket
                  [bucket.file, bucket.rule,
                   bucket.message_regex&.source]
                else
                  [normalize_path(diag.path), diag.qualified_rule, :__none__]
                end
          bin = (bins[key] ||= { bucket: bucket, diagnostics: [] })
          bin[:diagnostics] << diag
        end
        bins
      end

      def claim_bucket_for(diagnostic)
        candidates = @by_pair[[normalize_path(diagnostic.path), diagnostic.qualified_rule]]
        return nil if candidates.nil? || candidates.empty?

        # Tighter (message-pattern) buckets first, then the rule-ID bucket as fallback.
        message_buckets, rule_buckets = candidates.partition(&:message_regex)
        message_buckets.each do |b|
          return b if b.message_regex.match?(diagnostic.message.to_s)
        end
        rule_buckets.first
      end
    end
  end
end
