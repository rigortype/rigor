# frozen_string_literal: true

require_relative "../type"

module Rigor
  module Inference
    # Slice 6 phase C sub-phase 3a — closure-escape classification.
    #
    # Given a `(receiver_type, method_name)` pair representing a
    # block-accepting call, this analyzer answers one question:
    # does the receiver's method invoke its block **immediately and
    # synchronously**, without retaining the block past the call?
    #
    # The answer is one of three outcomes:
    #
    # - `:non_escaping` — the block is proven to be invoked
    #   immediately, zero or more times, and is NOT retained past
    #   the call. The receiver does not store the block in an
    #   instance variable, return it as a value, or schedule it for
    #   later invocation. Outer-local narrowing facts that survive
    #   the block body MAY safely survive the call.
    # - `:escaping` — the block is proven to be retained past the
    #   call (stored, returned, or invoked asynchronously). Outer
    #   narrowing facts on locals the block can rebind MUST be
    #   dropped at the call boundary.
    # - `:unknown` — the analyzer cannot prove either edge. Callers
    #   MUST treat `:unknown` as conservatively as `:escaping` for
    #   the purposes of fact retention; the distinction exists so
    #   diagnostics and later RBS-Extended effect plumbing can
    #   tell "deliberately conservative" apart from "declared
    #   escape".
    #
    # ## Catalogue
    #
    # Sub-phase 3a is RBS-blind: it ships a hardcoded catalogue
    # keyed by Ruby class name. A future sub-phase will replace
    # this with an `RBS::Extended` call-timing effect read from
    # method signatures. The catalogue therefore covers ONLY the
    # core-and-stdlib surface where immediate invocation is part of
    # the documented contract:
    #
    # - `Array`, `Hash`, `Range`, `Integer`, `Enumerator::Lazy`
    #   iteration methods (`each`, `map`, `select`, `reject`,
    #   `flat_map`, `find`/`detect`, `any?`, `all?`, `none?`,
    #   `one?`, `count`, `inject`/`reduce`, `each_with_index`,
    #   `each_with_object`, `min_by`, `max_by`, `sort_by`,
    #   `partition`, `group_by`, `tally`, `sum`, `take_while`,
    #   `drop_while`, `chunk_while`, `slice_when`, `zip`,
    #   `collect`, `collect_concat`, `filter`, `filter_map`).
    # - `Hash`-only iteration: `each_pair`, `each_key`, `each_value`,
    #   `transform_keys`, `transform_values`.
    # - `Integer#times`, `Integer#upto`, `Integer#downto`,
    #   `Range#each`, `Range#step`.
    # - `Object#tap`, `Object#then`, `Object#yield_self`.
    # - Tuple/HashShape carriers map to Array/Hash for catalogue
    #   lookup so a literal `[1, 2, 3].each { ... }` is recognised.
    #
    # Anything outside the catalogue resolves to `:unknown`. The
    # catalogue is intentionally narrow: adding entries requires
    # confirming, by reading the method's stdlib documentation,
    # that the block is not retained. False positives in this
    # catalogue would silently weaken the soundness of fact
    # retention in later sub-phases.
    #
    # The analyzer is a pure query. It MUST NOT mutate the
    # receiver type or scope, MUST NOT raise on unrecognised
    # inputs, and MUST be deterministic for a given input.
    module ClosureEscapeAnalyzer
      module_function

      # @param receiver_type [Rigor::Type, nil]
      # @param method_name [Symbol]
      # @param environment [Rigor::Environment, nil] reserved for the
      #   future sub-phase that consults `RBS::Extended` call-timing
      #   effects; sub-phase 3a ignores it.
      # @return [Symbol] one of `:non_escaping`, `:escaping`, `:unknown`.
      def classify(receiver_type:, method_name:, environment: nil) # rubocop:disable Lint/UnusedMethodArgument
        return :unknown if receiver_type.nil?

        class_name = receiver_class_name(receiver_type)
        return :unknown if class_name.nil?

        method_sym = method_name.to_sym
        return :non_escaping if non_escaping?(class_name, method_sym)
        return :escaping if escaping?(class_name, method_sym)

        :unknown
      end

      class << self
        private

        # Resolve a single concrete class name for catalogue lookup.
        # Returns `nil` when the receiver carrier does not name a
        # single class (e.g. `Top`, `Dynamic[Top]`, `Union[...]`,
        # `Bot`). `Tuple` projects to `Array`; `HashShape` to `Hash`;
        # `Singleton[C]` to `C` (so `Integer.times` would resolve as
        # a singleton call, but the catalogue today only lists
        # instance-side methods on `Integer`, so a hit there would
        # be unsurprising — kept for forward consistency).
        def receiver_class_name(receiver_type)
          case receiver_type
          when Type::Nominal, Type::Singleton then receiver_type.class_name
          when Type::Tuple then "Array"
          when Type::HashShape then "Hash"
          when Type::Constant then constant_class_name(receiver_type.value)
          end
        end

        # `Rigor::Type::Constant` only carries scalar literals
        # (`Integer`, `Float`, `String`, `Symbol`, `Range`, booleans,
        # `nil`); the carrier explicitly rejects mutable container
        # values, so we only project from those scalar shapes here.
        CONSTANT_CLASS_NAMES = {
          Integer => "Integer",
          String => "String",
          Symbol => "Symbol",
          Range => "Range",
          TrueClass => "TrueClass",
          FalseClass => "FalseClass",
          NilClass => "NilClass"
        }.freeze
        private_constant :CONSTANT_CLASS_NAMES

        def constant_class_name(value)
          CONSTANT_CLASS_NAMES.each { |klass, name| return name if value.is_a?(klass) }
          nil
        end

        def non_escaping?(class_name, method_sym)
          methods = NON_ESCAPING[class_name]
          return true if methods&.include?(method_sym)

          # Object#tap/then/yield_self are inherited by every class.
          OBJECT_NON_ESCAPING.include?(method_sym)
        end

        def escaping?(class_name, method_sym)
          methods = ESCAPING[class_name]
          methods ? methods.include?(method_sym) : false
        end
      end

      OBJECT_NON_ESCAPING = %i[tap then yield_self].freeze

      ENUMERABLE_NON_ESCAPING = %i[
        each map collect flat_map collect_concat
        select filter reject filter_map
        find detect find_index find_all
        any? all? none? one? count tally sum
        inject reduce
        each_with_index each_with_object
        min_by max_by sort_by minmax_by
        partition group_by chunk chunk_while slice_when slice_before slice_after
        take_while drop_while
        zip
      ].freeze

      ARRAY_EXTRA = %i[each_index].freeze
      HASH_EXTRA = %i[
        each_pair each_key each_value
        transform_keys transform_values
        delete_if keep_if
        any? all? none? one?
      ].freeze
      RANGE_EXTRA = %i[step].freeze
      INTEGER_EXTRA = %i[times upto downto].freeze

      NON_ESCAPING = {
        "Array" => (ENUMERABLE_NON_ESCAPING + ARRAY_EXTRA).freeze,
        "Hash" => (ENUMERABLE_NON_ESCAPING + HASH_EXTRA).freeze,
        "Range" => (ENUMERABLE_NON_ESCAPING + RANGE_EXTRA).freeze,
        "Set" => ENUMERABLE_NON_ESCAPING,
        "Integer" => INTEGER_EXTRA,
        "Enumerator" => ENUMERABLE_NON_ESCAPING,
        "Enumerator::Lazy" => ENUMERABLE_NON_ESCAPING
      }.freeze

      # Methods that are documented to **retain** the block past the
      # call. The block is stored or scheduled, so outer narrowing
      # facts on writeable captured locals cannot survive.
      ESCAPING = {
        "Module" => %i[define_method].freeze,
        "Class" => %i[define_method].freeze,
        "Thread" => %i[new start fork].freeze,
        "Fiber" => %i[new].freeze,
        "Proc" => %i[new].freeze
      }.freeze
    end
  end
end
