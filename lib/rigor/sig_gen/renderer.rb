# frozen_string_literal: true

require "json"

require_relative "classification"
require_relative "superclass_spelling"
require_relative "write_reporter"

module Rigor
  module SigGen
    # Output formatter for `rigor sig-gen`.
    #
    # Supports three modes:
    # - `:print` (default) — RBS skeletons grouped by source file and class declaration, ready for the user to
    #   paste into `sig/<path>.rbs`.
    # - `:diff` — a unified-style diff comparing the existing RBS spelling (if any) against the inferred
    #   spelling, as a minimal "- declared / + inferred" block.
    # - `:json` — machine-readable payload with the same classification table as `:print`, plus every `skipped`
    #   row with its `skip_reason` (#778).
    class Renderer
      def initialize(out:)
        @out = out
      end

      # @param format — "text" or "json"
      # @param selection — subset of
      #   {Classification} constants to include; an empty
      #   array means "all emittable classifications".
      # @param observation — `{ paths:, missing: }` under `--params=observed`, else `nil`; JSON carries it
      #   as the top-level `observation` key (#1398).
      # @param diagnostics — the path errors `rigor check` would report for the arguments (#1991); JSON carries
      #   them as the top-level `diagnostics` key, and only when there are some.
      def render(candidates:, mode:, format:, selection:, observation: nil, diagnostics: [])
        case format
        when "json" then render_json(filter(candidates, selection, with_skipped: true), observation, diagnostics)
        when "text"
          filtered = filter(candidates, selection)
          mode == :diff ? render_diff(filtered) : render_print(filtered)
        else
          raise ArgumentError, "unsupported format: #{format}"
        end
      end

      private

      # The emittable rows the selection asks for. JSON also carries every `skipped` row whatever the selection:
      # ADR-14 makes the JSON payload the surface where `sig.skipped.*` is reported, and a consumer asking why a
      # method is missing from its `sig/` needs the reason next to the rows that did emit (#778 — the rows were
      # built with their `skip_reason` and then dropped here). `equivalent` rows stay out: nothing to do,
      # nothing to explain.
      def filter(candidates, selection, with_skipped: false)
        active = selection.empty? ? Classification::EMITTABLE : selection
        candidates.select do |c|
          active.include?(c.classification) || (with_skipped && c.classification == Classification::SKIPPED)
        end
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
          @out.puts(declaration_header(methods.first, class_name))
          methods.each do |candidate|
            tag = case candidate.classification
                  when Classification::NEW_METHOD then "[new]"
                  when Classification::NEW_FILE then "[new-file]"
                  when Classification::TIGHTER_RETURN
                    "[tighter, was: #{candidate.declared_return_rbs}]"
                  when Classification::INLINE_OVERWRITE
                    "[inline-overwrite, was: #{candidate.declared_rbs}]"
                  end
            @out.puts("  # #{tag}")
            # Annotations first: an RBS annotation binds the declaration BELOW it, so `%a{pure}` printed
            # after the `def` line would bind the next member — or nothing at all at the end of a class.
            candidate.rbs_lines.each { |line| @out.puts("  #{line}") }
          end
          @out.puts("end")
        end
      end

      # The keyword and ancestry for a printed group, from the same per-file maps the `--write` path reads. Print
      # mode used to hard-code `class`, which turned a module into a class the moment it held an emittable method —
      # output that raises `RBS::DuplicatedDeclarationError` on load if the real `module` is declared anywhere else
      # (#227). Defaulting to `class` when the map has no entry keeps the pre-existing spelling for a leaf class.
      def declaration_header(candidate, class_name)
        return "module #{class_name}" if candidate.namespace_kinds[class_name] == :module

        superclass = candidate.class_superclasses[class_name]
        superclass ? "class #{class_name} < #{SuperclassSpelling.absolute(superclass)}" : "class #{class_name}"
      end

      def render_diff(candidates)
        if candidates.empty?
          @out.puts("No candidates")
          return
        end

        candidates.each do |candidate|
          @out.puts("--- #{candidate.path}: #{candidate.class_name}##{candidate.method_name}")
          render_removed_line(candidate)
          candidate.rbs_lines.each { |line| @out.puts("+ #{line}") }
          @out.puts
        end
      end

      # A tighter return or an inline update replaces a whole `sig/` line, which it carries; any other row
      # knows only the declared return.
      def render_removed_line(candidate)
        if candidate.declared_rbs
          @out.puts("- #{candidate.declared_rbs}")
        elsif candidate.declared_return_rbs
          @out.puts("- def #{candidate.method_name}: () -> #{candidate.declared_return_rbs}")
        end
      end

      def render_json(candidates, observation = nil, diagnostics = [])
        payload = { candidates: candidates.map(&:to_h) }
        payload[:observation] = observation if observation
        payload[:diagnostics] = diagnostics.map(&:to_h) if diagnostics.any?
        @out.puts(JSON.pretty_generate(payload))
      end

      public

      # The per-source-file outcomes of a `--write` run, and the `--check` verdict, are reported by
      # {WriteReporter}; these delegate so the command keeps one renderer.
      def render_write(results:, format:, refused: [])
        WriteReporter.new(out: @out).render_write(results: results, format: format, refused: refused)
      end

      def render_check(results:, format:, refused: [])
        WriteReporter.new(out: @out).render_check(results: results, format: format, refused: refused)
      end

      def self.refusal_lines(refused)
        WriteReporter.refusal_lines(refused)
      end

      def self.out_of_date(results)
        WriteReporter.out_of_date(results)
      end
    end
  end
end
