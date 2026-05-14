# frozen_string_literal: true

require "json"

require_relative "classification"

module Rigor
  module SigGen
    # Output formatter for `rigor sig-gen`.
    #
    # Supports three modes:
    # - `:print` (default) — RBS skeletons grouped by source
    #   file and class declaration, ready for the user to
    #   paste into `sig/<path>.rbs`.
    # - `:diff` — a unified-style diff comparing the existing
    #   RBS spelling (if any) against the inferred spelling.
    #   The MVP renders a minimal "- declared / + inferred"
    #   block; full per-file diffing arrives with slice 2's
    #   `--write` merge.
    # - `:json` — machine-readable payload with the same
    #   classification table as `:print`.
    class Renderer
      def initialize(out:)
        @out = out
      end

      # @param candidates [Array<MethodCandidate>]
      # @param mode [:print, :diff]
      # @param format [String] "text" or "json"
      # @param selection [Array<Symbol>] subset of
      #   {Classification} constants to include; an empty
      #   array means "all emittable classifications".
      def render(candidates:, mode:, format:, selection:)
        filtered = filter(candidates, selection)

        case format
        when "json" then render_json(filtered)
        when "text"
          mode == :diff ? render_diff(filtered) : render_print(filtered)
        else
          raise ArgumentError, "unsupported format: #{format}"
        end
      end

      private

      EMITTABLE = [Classification::NEW_FILE,
                   Classification::NEW_METHOD,
                   Classification::TIGHTER_RETURN].freeze
      private_constant :EMITTABLE

      def filter(candidates, selection)
        active = selection.empty? ? EMITTABLE : selection
        candidates.select { |c| active.include?(c.classification) }
      end

      def render_print(candidates)
        if candidates.empty?
          @out.puts("No candidates")
          return
        end

        grouped = candidates.group_by(&:path)
        grouped.each do |path, items|
          @out.puts("# #{path}")
          render_classes(items)
          @out.puts
        end
      end

      def render_classes(items)
        items.group_by(&:class_name).each do |class_name, methods|
          @out.puts("class #{class_name}")
          methods.each do |candidate|
            tag = case candidate.classification
                  when Classification::NEW_METHOD then "[new]"
                  when Classification::NEW_FILE then "[new-file]"
                  when Classification::TIGHTER_RETURN
                    "[tighter, was: #{candidate.declared_return_rbs}]"
                  end
            @out.puts("  # #{tag}")
            @out.puts("  #{candidate.rbs}")
          end
          @out.puts("end")
        end
      end

      def render_diff(candidates)
        if candidates.empty?
          @out.puts("No candidates")
          return
        end

        candidates.each do |candidate|
          @out.puts("--- #{candidate.path}: #{candidate.class_name}##{candidate.method_name}")
          declared = candidate.declared_return_rbs
          @out.puts("- def #{candidate.method_name}: () -> #{declared}") if declared
          @out.puts("+ #{candidate.rbs}")
          @out.puts
        end
      end

      def render_json(candidates)
        payload = { candidates: candidates.map(&:to_h) }
        @out.puts(JSON.pretty_generate(payload))
      end

      public

      # Renders the per-source-file outcomes of a `--write`
      # run. Distinct from {#render} because the write
      # path's reporting surface is action-oriented (created
      # / updated / skipped) rather than candidate-oriented.
      def render_write(results:, format:)
        case format
        when "json" then render_write_json(results)
        when "text" then render_write_text(results)
        else raise ArgumentError, "unsupported format: #{format}"
        end
      end

      private

      def render_write_text(results)
        if results.all? { |r| r.action == :noop }
          @out.puts("No changes")
          return
        end

        results.each do |result|
          case result.action
          when :created then render_write_created(result)
          when :updated then render_write_updated(result)
          when :skipped_outside_sig_root then render_write_skipped(result)
          end
        end
      end

      def render_write_created(result)
        @out.puts("created #{result.target_path} (#{result.applied.size} method(s))")
      end

      def render_write_updated(result)
        @out.puts("updated #{result.target_path} (+#{result.applied.size}, " \
                  "skipped #{result.skipped.size} user-authored)")
      end

      def render_write_skipped(result)
        @out.puts("skipped #{result.source_path} -> #{result.target_path} (outside sig root)")
      end

      def render_write_json(results)
        @out.puts(JSON.pretty_generate({ results: results.map(&:to_h) }))
      end
    end
  end
end
