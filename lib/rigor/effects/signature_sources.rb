# frozen_string_literal: true

module Rigor
  module Effects
    # Everything an effect envelope may be written in, as `[buffer name, RBS source]` pairs
    # (ADR-103 WD5 / WD6; #383 / #384).
    #
    # Two strata, and the exclusion is the point: the project's own `signature_paths:` tree (or the
    # `sig/` default `Environment.for_project` falls back to) plus the loader's **virtual** entries —
    # which is how rbs-inline's `# @rbs %a{…}` comments and a plugin's `source_rbs` synthesis arrive.
    # Gem-shipped and bundled RBS is deliberately absent: WD6 makes project-authored envelopes the
    # checked stratum, so a `%a{pure}` in rbs core cannot bound a project method that shares its key.
    #
    # Shared by the two passes that read declarations — the envelope check and the
    # annotations-unchecked residual — so the residual can never disagree with the check about what
    # counts as "the project's own signatures".
    module SignatureSources
      # Where `Environment.for_project` looks when no `signature_paths:` is configured. Spelled again
      # here rather than required, because the constant is private to {Rigor::Environment} and a walk
      # over the project's own files has no business reaching into its builder.
      DEFAULT_ROOTS = ["sig"].freeze

      # A cheap text pre-filter for "does this source carry an effect annotation at all". It matches
      # the two payloads the envelope reader honours and nothing else, so a signature tree with no
      # effect annotation is answered by one regex per file and never parsed. It is a ROUTING test,
      # not the grammar — `RbsExtended.parse_effect_annotation` is still what decides meaning.
      #
      # RBS accepts five bracket pairs for an annotation, and the reader sees only the text inside
      # them, so the hint must accept all five too: routing on `%a{` alone made a `%a(pure)` project
      # invisible to the run-cache probe, which then served the fast path while a bound existed —
      # the silent-lane shape the #428 family is about. Over-matching (a mismatched closer) is safe:
      # the cost is one declined fast path or one parsed file, never a missed bound.
      ANNOTATION_BRACKETS = { "{" => "}", "(" => ")", "[" => "]", "|" => "|", "<" => ">" }.freeze
      ANNOTATION_HINT = Regexp.union(
        ANNOTATION_BRACKETS.map do |opener, closer|
          /%a#{Regexp.escape(opener)}\s*(?:pure\s*#{Regexp.escape(closer)}|rigor:v1:effect\b)/
        end
      )

      # A `virtual:<plugin-id>:<source path>` buffer is rbs-inline's (or a plugin's) synthesized RBS for
      # a Ruby file the author actually wrote in. Naming that file is what a reader can act on, so the
      # synthetic prefix comes off before the name is made project-relative.
      VIRTUAL_BUFFER_PATTERN = /\Avirtual:[^:]*:/

      module_function

      # The path a reader can open, for a buffer name from {.collect}: the `.rbs` file as configured,
      # or the `.rb` file behind a `virtual:` buffer, project-relative either way.
      def source_path(name)
        stripped = name.to_s.sub(VIRTUAL_BUFFER_PATTERN, "")
        root = "#{Dir.pwd}#{File::SEPARATOR}"
        stripped.start_with?(root) ? stripped[root.length..] : stripped
      end

      # @param signature_paths [Array<String>, nil] the configured roots; empty / nil takes the default.
      # @param virtual_rbs [Array<Array(String, String)>, nil] the loader's virtual entries.
      def collect(signature_paths:, virtual_rbs: nil)
        files = roots(signature_paths).flat_map { |root| Dir.glob(File.join(root.to_s, "**", "*.rbs")).sort }
        sources = files.filter_map do |path|
          [path, File.read(path)]
        rescue StandardError
          nil
        end
        sources + Array(virtual_rbs).map { |name, content| [name.to_s, content.to_s] }
      end

      def roots(signature_paths)
        signature_paths.nil? || signature_paths.empty? ? DEFAULT_ROOTS : signature_paths
      end

      # The FIRST annotated virtual entry, as a `collect`-shaped one-element array (or an empty one).
      #
      # #441 — the analysis paths use this to hand the annotations-unchecked residual the inline stratum
      # of a run that resolved an environment but never stored it. Reduced to one entry on purpose: the
      # residual reports one annotation per run, so the carrier a run holds past the environment's own
      # lifetime is a single synthesized buffer rather than the project's whole virtual tree.
      #
      # @return [Array<Array(String, String)>] zero or one pair.
      def annotated_carrier(virtual_rbs)
        Array(virtual_rbs).each do |name, content|
          return [[name.to_s, content.to_s]] if ANNOTATION_HINT.match?(content)
        end
        [].freeze
      end

      # The first `[name, content, line]` carrying an effect annotation, or nil. Line numbers are
      # 1-based and count into `content`, which for a `virtual:` buffer is the SYNTHESIZED text — the
      # caller re-anchors it against the Ruby file when that matters.
      def first_annotated(sources)
        sources.each do |name, content|
          content.each_line.with_index(1) do |line, number|
            return [name, content, number] if ANNOTATION_HINT.match?(line)
          end
        end
        nil
      end
    end
  end
end
