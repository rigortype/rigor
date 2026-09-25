# frozen_string_literal: true

require_relative "classification"
require_relative "effect_annotation"

module Rigor
  module SigGen
    # Per-method record produced by the generator.
    #
    # `classification` is one of the {Classification} constants; the remaining fields are populated only when
    # applicable to that classification.
    #
    # - `path` — the source `.rb` file the def came from.
    # - `class_name` — qualified receiver class name (e.g. `"Foo::Bar"`). `nil` for top-level / DSL-block defs
    #   the MVP skips.
    # - `method_name` — the def's `Symbol` name.
    # - `kind` — `:instance` or `:singleton`.
    # - `inferred_return` — `Rigor::Type` instance (or `nil` when the inference pass disqualified the def).
    # - `declared_return_rbs` — the existing RBS-declared return spelling, or `nil` when no RBS declares the
    #   method.
    # - `declared_rbs` — for an `inline_update`, the whole `sig/` line the inline declaration replaces, so
    #   `--diff` can show both; `nil` otherwise.
    # - `declared_annotations` — for a member declared inline, the annotations the author wrote on it
    #   (`%a{deprecated}`), rendered above `rbs` like `annotations`. Empty otherwise.
    # - `rbs` — the rendered RBS one-liner the generator would emit (`nil` for skipped / equivalent rows).
    # - `skip_reason` — one of {Classification::SKIP_DIAGNOSTIC_IDS} keys when classification is `:skipped`,
    #   else `nil`.
    # - `annotations` — RBS annotation lines to render ABOVE `rbs` (`%a{pure}` /
    #   `%a{rigor:v1:effect …}`, ADR-103 WD9). Empty unless the effects opt-in is on and the method's
    #   summary earned one; see {EffectAnnotation}.
    # - `effect_reason` — one of {EffectAnnotation::DIAGNOSTIC_IDS} keys saying why `annotations` is what
    #   it is, or `nil` when the run had nothing to say about this method's effects.
    class MethodCandidate
      attr_reader :path, :class_name, :method_name, :kind, :classification,
                  :inferred_return, :declared_return_rbs, :rbs, :skip_reason,
                  :namespace_kinds, :class_shells, :class_superclasses,
                  :annotations, :effect_reason, :declared_rbs, :declared_annotations

      def initialize(path:, class_name:, method_name:, kind:, classification:, # rubocop:disable Metrics/ParameterLists
                     inferred_return: nil, declared_return_rbs: nil, rbs: nil, skip_reason: nil,
                     namespace_kinds: {}, class_shells: [], class_superclasses: {},
                     annotations: [], effect_reason: nil, declared_rbs: nil, declared_annotations: [])
        @path = path
        @class_name = class_name
        @method_name = method_name
        @kind = kind
        @classification = classification
        @inferred_return = inferred_return
        @declared_return_rbs = declared_return_rbs
        @rbs = rbs
        @skip_reason = skip_reason
        @namespace_kinds = namespace_kinds.freeze
        @class_shells = class_shells.freeze
        # Qualified-class-name => superclass source token (e.g. `{ "Foo::Bar" => "Base" }`). Only plain-constant
        # superclasses appear; computed ones are absent. The Writer emits `class Bar < Base` for the leaf when
        # present.
        @class_superclasses = class_superclasses.freeze
        @annotations = annotations.freeze
        @effect_reason = effect_reason
        @declared_rbs = declared_rbs
        @declared_annotations = declared_annotations.freeze
        freeze
      end

      # Every line this candidate contributes to a declaration body, annotations first. The single place
      # the renderer and the writer agree that an annotation precedes the `def` line it binds.
      def rbs_lines
        @declared_annotations + @annotations + [@rbs].compact
      end

      # A copy carrying a different annotation decision. The generator's effect pass rebuilds rather than
      # mutates, because a candidate is frozen the moment it is built.
      def with_effect_annotation(annotations, reason)
        self.class.new(
          path: @path, class_name: @class_name, method_name: @method_name, kind: @kind,
          classification: @classification, inferred_return: @inferred_return,
          declared_return_rbs: @declared_return_rbs, rbs: @rbs, skip_reason: @skip_reason,
          namespace_kinds: @namespace_kinds, class_shells: @class_shells,
          class_superclasses: @class_superclasses, annotations: annotations, effect_reason: reason,
          declared_rbs: @declared_rbs, declared_annotations: @declared_annotations
        )
      end

      def to_h
        {
          file: path,
          class: class_name,
          method: method_name.to_s,
          kind: kind.to_s,
          classification: classification.to_s,
          rbs: rbs,
          inferred_return: inferred_return&.erase_to_rbs,
          declared_return_rbs: declared_return_rbs,
          declared_rbs: declared_rbs,
          declared_annotations: declared_annotations.empty? ? nil : declared_annotations,
          skip_reason: skip_reason ? Classification::SKIP_DIAGNOSTIC_IDS.fetch(skip_reason) : nil,
          # Named fields rather than a merge into `rbs`: a consumer routing on the annotation has to be
          # able to find it without re-lexing the rendered line. Both are absent (not empty / null) when
          # the run had no effect answer, so an effects-off payload is byte-identical to a pre-#391 one.
          effect_annotations: annotations.empty? ? nil : annotations,
          effect_reason: effect_reason ? EffectAnnotation::DIAGNOSTIC_IDS.fetch(effect_reason) : nil
        }.compact
      end
    end
  end
end
