# frozen_string_literal: true

require "rbconfig"

module Rigor
  module Analysis
    # End-of-run telemetry for the `rigor check` CLI's `--stats`
    # output. Captures four cheap-to-measure groups:
    #
    # - **Check targets** — the Ruby files the analyser actually
    #   walks for diagnostics (`expand_paths` output).
    # - **Type universe** — RBS class/module declarations the
    #   analyser had visibility of, broken down by source:
    #   `project_sig` (declarations whose source file lives under
    #   the configured `signature_paths`) vs `bundled` (RBS core,
    #   stdlib libraries, gem-bundled RBS — everything outside
    #   the project's own `sig/` tree).
    # - **Gem source-walk** — the ADR-10
    #   `dependencies.source_inference` catalogue. Reports the
    #   class count and the number of opt-in gems contributing.
    # - **Process** — wall-clock seconds + peak resident set size.
    #
    # The split between "check targets" and "type universe" makes
    # explicit that the analyser's diagnostic surface is bounded
    # by the user-controlled `paths:` configuration; the (typically
    # much larger) RBS class universe is symbol-discovery, not a
    # diagnostic surface.
    #
    # Stats collection is intentionally cheap: wall + RSS are
    # single syscalls, target file count is already in
    # `expand_paths`, gem source-walk uses
    # `Index#class_to_gem.size`, and the RBS class breakdown
    # walks `class_decl_paths` (a frozen `Hash<String, String>`
    # populated once per environment by the RBS loader; ~1000-2000
    # entries × one `String#start_with?`).
    class RunStats
      attr_reader :wall_seconds, :peak_rss_bytes,
                  :target_files,
                  :rbs_classes_total, :rbs_classes_project_sig, :rbs_classes_bundled,
                  :gem_walk_classes, :gem_walk_gems, :rbs_attribution_available

      def initialize(wall_seconds:, peak_rss_bytes:, # rubocop:disable Metrics/ParameterLists
                     target_files:,
                     rbs_classes_total:, rbs_classes_project_sig:, rbs_classes_bundled:,
                     gem_walk_classes:, gem_walk_gems:,
                     rbs_attribution_available: true)
        @wall_seconds = wall_seconds
        @peak_rss_bytes = peak_rss_bytes
        @target_files = target_files
        @rbs_classes_total = rbs_classes_total
        @rbs_classes_project_sig = rbs_classes_project_sig
        @rbs_classes_bundled = rbs_classes_bundled
        @gem_walk_classes = gem_walk_classes
        @gem_walk_gems = gem_walk_gems
        @rbs_attribution_available = rbs_attribution_available
        freeze
      end

      # Reports the process's resident set size in bytes. Source
      # ordering: `/proc/self/status` (Linux — reads `VmHWM:`,
      # the peak RSS the kernel records) first; otherwise
      # `ps -o rss= -p <pid>` (macOS / BSD — reports CURRENT
      # RSS, the closest universally-available proxy). Returns
      # nil when neither route works so the formatter can render
      # `unavailable` instead of misleading zero.
      def self.peak_rss_bytes
        from_proc = read_vmhwm_from_proc
        return from_proc unless from_proc.nil?

        from_ps = read_rss_via_ps
        return from_ps unless from_ps.nil?

        nil
      end

      def self.read_vmhwm_from_proc
        return nil unless File.readable?("/proc/self/status")

        File.foreach("/proc/self/status") do |line|
          next unless line.start_with?("VmHWM:")

          kb_token = line.split.find { |token| token.match?(/\A\d+\z/) }
          return Integer(kb_token) * 1024 if kb_token
        end
        nil
      rescue StandardError
        nil
      end

      def self.read_rss_via_ps
        out = `ps -o rss= -p #{Process.pid} 2>/dev/null`.strip
        return nil if out.empty?

        Integer(out) * 1024
      rescue StandardError
        nil
      end

      # Source-attribution sentinel produced by `RBS::Environment`
      # entries restored from a cached blob (Marshal-loaded
      # `RBS::Environment` loses real file-path attribution; every
      # buffer reports `"<cached>"`). When every entry carries
      # this sentinel the partition_classes routine returns
      # `[0, total]` AND `attribution_available: false`, which
      # the format routine consumes to suppress the misleading
      # breakdown row.
      CACHED_SENTINEL = "<cached>"

      # Computes `(project_sig, bundled)` counts from a frozen
      # `Hash<class_name => source_path>` snapshot and the
      # configured `signature_paths`. `project_sig` is the count
      # of classes whose source path begins with any of the
      # signature path prefixes (after expansion to absolute
      # paths); `bundled` is the remainder.
      def self.partition_classes(class_decl_paths:, signature_paths:)
        prefixes = Array(signature_paths).map { |p| File.expand_path(p.to_s) }
        return [0, class_decl_paths.size] if prefixes.empty?

        project = 0
        class_decl_paths.each_value do |path|
          expanded = File.expand_path(path)
          project += 1 if prefixes.any? { |prefix| expanded.start_with?("#{prefix}/") || expanded == prefix }
        end
        [project, class_decl_paths.size - project]
      end

      # True when at least one entry in `class_decl_paths` carries
      # a real source file path (i.e. not the cached-sentinel
      # marker). Used by callers to decide whether the
      # `project_sig` / `bundled` split is meaningful.
      def self.attribution_available?(class_decl_paths:)
        return false if class_decl_paths.empty?

        class_decl_paths.each_value.any? { |path| path != CACHED_SENTINEL }
      end

      # Writes a human-facing rendering of the stats to `out`
      # (typically `$stderr` from the CLI). Format is intentionally
      # plain text — JSON consumers should parse the structured
      # output of `rigor check --format=json` and consult `stats`
      # there.
      def format(out, prefix: "")
        out.puts("#{prefix}Check targets")
        out.puts("#{prefix}  Ruby source files: #{@target_files}")
        out.puts("#{prefix}Type universe (symbol discovery; not analyzed for diagnostics)")
        out.puts("#{prefix}  RBS classes available: #{@rbs_classes_total}")
        if @rbs_attribution_available
          out.puts("#{prefix}    project sig/:        #{@rbs_classes_project_sig}")
          out.puts("#{prefix}    bundled (core+stdlib+gems): #{@rbs_classes_bundled}")
        elsif @rbs_classes_total.positive?
          out.puts("#{prefix}    (source attribution unavailable on cache-hit runs; --no-cache surfaces it)")
        end
        if @gem_walk_gems.positive?
          out.puts("#{prefix}  Gem source-walk classes: #{@gem_walk_classes} " \
                   "(across #{@gem_walk_gems} #{@gem_walk_gems == 1 ? 'gem' : 'gems'} " \
                   "via dependencies.source_inference)")
        end
        out.puts("#{prefix}Process")
        out.puts("#{prefix}  Wall time:   #{Kernel.format('%.2fs', @wall_seconds)}")
        out.puts("#{prefix}  Memory peak: #{format_bytes(@peak_rss_bytes)}")
      end

      def to_h
        {
          target_files: @target_files,
          rbs_classes_total: @rbs_classes_total,
          rbs_classes_project_sig: @rbs_classes_project_sig,
          rbs_classes_bundled: @rbs_classes_bundled,
          rbs_attribution_available: @rbs_attribution_available,
          gem_walk_classes: @gem_walk_classes,
          gem_walk_gems: @gem_walk_gems,
          wall_seconds: @wall_seconds,
          peak_rss_bytes: @peak_rss_bytes
        }
      end

      private

      def format_bytes(bytes)
        return "unavailable" if bytes.nil?

        units = %w[B KB MB GB TB]
        size = bytes.to_f
        index = 0
        while size >= 1024 && index < units.size - 1
          size /= 1024
          index += 1
        end
        Kernel.format("%<size>.1f %<unit>s", size: size, unit: units[index])
      end
    end
  end
end
