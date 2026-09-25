# frozen_string_literal: true

require_relative "../type"
require_relative "../reflection"
require_relative "external_ancestor_resolution"
require_relative "project_method_ownership"

module Rigor
  module Inference
    # Slice 6 phase C sub-phase 3a — closure-escape classification.
    #
    # Given a `(receiver_type, method_name)` pair representing a block-accepting call, this analyzer answers
    # one question: does the receiver's method invoke its block **immediately and synchronously**, without
    # retaining the block past the call?
    #
    # The answer is one of three outcomes:
    #
    # - `:non_escaping` — the block is proven to be invoked immediately, zero or more times, and is NOT
    #   retained past the call. The receiver does not store the block in an instance variable, return it as a
    #   value, or schedule it for later invocation. Outer-local narrowing facts that survive the block body
    #   MAY safely survive the call.
    # - `:escaping` — the block is proven to be retained past the call (stored, returned, or invoked
    #   asynchronously). Outer narrowing facts on locals the block can rebind MUST be dropped at the call
    #   boundary.
    # - `:unknown` — the analyzer cannot prove either edge. Callers MUST treat `:unknown` as conservatively as
    #   `:escaping` for the purposes of fact retention; the distinction exists so diagnostics and later
    #   RBS-Extended effect plumbing can tell "deliberately conservative" apart from "declared escape".
    #
    # ## Catalogue
    #
    # Sub-phase 3a is RBS-blind: it ships a hardcoded catalogue keyed by Ruby class name. A future sub-phase
    # will replace this with an `RBS::Extended` call-timing effect read from method signatures. The catalogue
    # therefore covers ONLY the core-and-stdlib surface where immediate invocation is part of the documented
    # contract:
    #
    # - `Array`, `Hash`, `Range`, `Set`, `Enumerator`, `Enumerator::Lazy` iteration methods (`each`, `map`,
    #   `select`, `reject`, `flat_map`, `find`/`detect`, `any?`, `all?`, `none?`, `one?`, `count`,
    #   `inject`/`reduce`, `each_with_index`, `each_with_object`, `min_by`, `max_by`, `sort_by`, `partition`,
    #   `group_by`, `tally`, `sum`, `take_while`, `drop_while`, `chunk_while`, `slice_when`, `zip`, `collect`,
    #   `collect_concat`, `filter`, `filter_map`).
    # - `Hash`-only iteration: `each_pair`, `each_key`, `each_value`, `transform_keys`, `transform_values`.
    # - `Integer#times`, `Integer#upto`, `Integer#downto`, `Range#each`, `Range#step`.
    # - `IO` / `File` / `StringIO` line iteration (`each`, `each_line`, `each_byte`, `each_char`,
    #   `each_codepoint`, the singleton `foreach`) and the same Enumerable methods minus
    #   {DEFERRED_ENUMERATOR_METHODS}.
    # - `Object#tap`, `Object#then`, `Object#yield_self`. The stronger "yields exactly once, before returning"
    #   fact for these three lives in {BlockCallTiming}; that table is expected to move to the same
    #   `RBS::Extended` call-timing effect as this one.
    # - Tuple/HashShape carriers map to Array/Hash for catalogue lookup so a literal `[1, 2, 3].each { ... }`
    #   is recognised.
    #
    # Anything outside the catalogue resolves to `:unknown`. The catalogue is intentionally narrow: adding
    # entries requires confirming, by reading the method's stdlib documentation, that the block is not
    # retained. False positives in this catalogue would silently weaken the soundness of fact retention in
    # later sub-phases.
    #
    # Issue #1234 — a project class is outside the catalogue by name, yet `class Shelf; include Enumerable`
    # answers `find` with `Enumerable#find` all the same. Given the `scope:` whose discovery tables know the
    # project, a `Nominal` receiver of a project class classifies through its ancestry
    # ({.ancestry_non_escaping?}): the method must be one the project does not define anywhere in that
    # ancestry, and the first ancestor outside the project that declares it must be a catalogued class or
    # `Enumerable` ({MIXIN_NON_ESCAPING}). An ancestor the RBS environment does not know could declare
    # anything, so meeting one first declines.
    #
    # The analyzer is a pure query. It MUST NOT mutate the receiver type or scope, MUST NOT raise on
    # unrecognised inputs, and MUST be deterministic for a given input.
    module ClosureEscapeAnalyzer
      module_function

      # @param environment — reserved for the future sub-phase that consults
      #   `RBS::Extended` call-timing effects; sub-phase 3a ignores it.
      # @param scope — the project's discovery tables, for the ancestry step; without it a project class
      #   stays `:unknown`.
      # @return one of `:non_escaping`, `:escaping`, `:unknown`.
      def classify(receiver_type:, method_name:, environment: nil, scope: nil) # rubocop:disable Lint/UnusedMethodArgument
        return :unknown if receiver_type.nil?

        method_sym = method_name.to_sym
        class_name = receiver_class_name(receiver_type)
        if class_name
          return :non_escaping if non_escaping?(class_name, method_sym)
          return :escaping if escaping?(class_name, method_sym)
        end

        instance_class = instance_carrier_class_name(receiver_type)
        return :unknown if instance_class.nil?

        ancestry_non_escaping?(instance_class, method_sym, scope) ? :non_escaping : :unknown
      end

      # Issue #1234 — whether some catalogue entry lists `method_name` as an iteration method: a name that runs
      # its block once per element wherever the catalogue knows the receiver. `tap` / `then` / `yield_self` are
      # left out, as they run the block exactly once. This is a fact about the NAME, for the one consumer that
      # asks it of an `:unknown` receiver (`ExpressionTyper#block_may_repeat?`); it proves nothing about escape.
      def iterator_name?(method_name)
        ITERATOR_NAMES.include?(method_name)
      end

      # Issue #1234 — whether the NAME of a catalogued iterator is the only thing Rigor knows about the method
      # `receiver_type` answers `method_name` with, so the captured-binding pass may read it as repetition
      # (`ExpressionTyper#block_may_repeat?`, for an `:unknown` receiver). It holds for a receiver Rigor cannot
      # see at all (`Dynamic`, `Top`), and for a class it can see whose method the project does not define.
      #
      # A method the project defines under a catalogued name is the project's, not the iterator, so the name
      # says nothing about how often it yields: `class Vault; def select(key) = yield(key.to_s); end` runs its
      # block once. "Defines" is a `def`, `define_method` or `attr_*` anywhere in a project class's ancestry
      # (instance side, or singleton side for a class-object receiver), or a signature whose declaring owner
      # is a project class or module. A carrier this does not recognise, or one whose class it cannot name
      # (an anonymous `Struct.new` value), answers false: when Rigor cannot tell whether the project owns the
      # method, it does not assume repetition. {ProjectMethodOwnership.targets} carries the carrier audit.
      def repeats_by_name?(receiver_type:, method_name:, scope:)
        method_sym = method_name.to_sym
        return false unless ITERATOR_NAMES.include?(method_sym)

        targets = ProjectMethodOwnership.targets(receiver_type)
        return false if targets.nil?

        targets.none? { |class_name, kind| ProjectMethodOwnership.defines?(class_name, method_sym, kind, scope) }
      end

      class << self
        private

        # The instance-side class a `Nominal` or an ADR-48 member carrier names, for the ancestry step.
        def instance_carrier_class_name(receiver_type)
          case receiver_type
          when Type::Nominal, Type::StructInstance, Type::DataInstance then receiver_type.class_name&.to_s
          end
        end

        # Resolve a single concrete class name for catalogue lookup. Returns `nil` when the receiver carrier
        # does not name a single class (e.g. `Top`, `Dynamic[Top]`, `Union[...]`, `Bot`). `Tuple` projects to
        # `Array`; `HashShape` to `Hash`; `Singleton[C]` to `C` (so `Integer.times` would resolve as a
        # singleton call, but the catalogue today only lists instance-side methods on `Integer`, so a hit
        # there would be unsurprising — kept for forward consistency).
        def receiver_class_name(receiver_type)
          case receiver_type
          when Type::Nominal, Type::Singleton then receiver_type.class_name
          when Type::Tuple then "Array"
          when Type::HashShape then "Hash"
          when Type::Constant then constant_class_name(receiver_type.value)
          end
        end

        # `Rigor::Type::Constant` only carries scalar literals (`Integer`, `Float`, `String`, `Symbol`,
        # `Range`, booleans, `nil`); the carrier explicitly rejects mutable container values, so we only
        # project from those scalar shapes here.
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

        # Issue #1234 — a project class answers `method_sym` through the catalogued ancestor Ruby dispatches it
        # to. The cheap gates come first: the name must be a catalogued iteration method, and the receiver a
        # class the project declares. A definition anywhere in the project ancestry — the class's own `def
        # find`, a project module's, a reopened `Enumerable`'s — is not the catalogued method and declines.
        # A class the project's `sig/` declares asks its RBS definition where the method comes from; one
        # without RBS walks the ancestors outside the project in method-resolution order.
        def ancestry_non_escaping?(class_name, method_sym, scope)
          return false if scope.nil? || !ITERATOR_NAMES.include?(method_sym)
          return false unless scope.known_user_class?(class_name)

          by_method = (ProjectMethodOwnership.memo(scope)[:ancestry][class_name] ||= {})
          return by_method[method_sym] if by_method.key?(method_sym)

          by_method[method_sym] = compute_ancestry_non_escaping?(class_name, method_sym, scope)
        end

        def compute_ancestry_non_escaping?(class_name, method_sym, scope)
          return false if ProjectMethodOwnership.defines?(class_name, method_sym, :instance, scope)

          if Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
            return catalogued_declaration?(method_definition(class_name, method_sym, :instance, scope), method_sym)
          end

          external_ancestry_non_escaping?(class_name, method_sym, scope)
        end

        # The RBS definition, or nil — a malformed signature is a gap, and
        # {ExternalAncestorResolution.method_definition} is the one place that rescues it.
        def method_definition(class_name, method_sym, kind, scope)
          ExternalAncestorResolution.method_definition(class_name, method_sym, kind, scope: scope)
        end

        # The first external ancestor that declares the method decides. One the environment does not know may
        # declare it, so it declines rather than being skipped; one that does not declare it is skipped.
        def external_ancestry_non_escaping?(class_name, method_sym, scope)
          scope.external_ancestor_name_candidates(class_name).each do |candidates|
            known = candidates.find { |candidate| Rigor::Reflection.rbs_class_known?(candidate, scope: scope) }
            return false if known.nil?
            return true if catalogued_owner?(known, method_sym)

            definition = method_definition(known, method_sym, :instance, scope)
            return catalogued_declaration?(definition, method_sym) if definition
          end
          false
        end

        def catalogued_declaration?(definition, method_sym)
          return false if definition.nil? || !definition.respond_to?(:defined_in)

          owner = definition.defined_in
          !owner.nil? && catalogued_owner?(owner.to_s.delete_prefix("::"), method_sym)
        end

        def catalogued_owner?(name, method_sym)
          methods = NON_ESCAPING[name] || MIXIN_NON_ESCAPING[name]
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

      # IO / File / StringIO line- and byte-iteration methods invoke the block immediately, once per line /
      # byte / char, and never retain it — the same immediate-invocation contract as `Array#each`. Both the
      # singleton `File.foreach` / `IO.foreach` (receiver `singleton(File)` → class name "File") and the
      # instance `io.each_line` / `each_char` … forms resolve through the same class-name key. Without these,
      # `File.foreach(path) { case … when … then flag = true when … then return true if flag end }` classifies
      # `:unknown` and misses the loop-body re-narrowing, so a local written in one `when` arm reads its
      # pre-loop value in a sibling arm and a guarding condition folds to a spurious constant.
      #
      # The three are also `Enumerable[String]` over lines (rbs core declares it for `IO`;
      # `data/core_overlay/string_io.rbs` for `StringIO`). An eager Enumerable method runs its block from inside
      # the call, through `each`, so `io.each_with_index { … }` / `io.detect { … }` carry the same contract and
      # take `ENUMERABLE_NON_ESCAPING` — minus {DEFERRED_ENUMERATOR_METHODS}, whose block outlives the call. On
      # the `singleton(File)` / `singleton(IO)` side those names only ever meet `IO.select`, which takes no
      # block and so never retains one. The key is the exact class name: a subclass (`Tempfile`, a user
      # `StringIO` subclass) stays `:unknown`.
      IO_ITERATION = %i[each_line each each_byte each_char each_codepoint].freeze
      IO_SINGLETON_ITERATION = %i[foreach].freeze

      # Enumerable methods that return an Enumerator holding the block and run it only when that Enumerator is
      # consumed, so the block may run after locals it reads or writes have changed. They are NOT
      # non-escaping. `ENUMERABLE_NON_ESCAPING` still lists them for the collection entries — a defect tracked
      # as #1311; the stream entries below leave them out rather than inherit it.
      DEFERRED_ENUMERATOR_METHODS = %i[chunk chunk_while slice_when slice_before slice_after].freeze
      STREAM_ENUMERABLE_NON_ESCAPING = (ENUMERABLE_NON_ESCAPING - DEFERRED_ENUMERATOR_METHODS).freeze

      NON_ESCAPING = {
        "Array" => (ENUMERABLE_NON_ESCAPING + ARRAY_EXTRA).freeze,
        "Hash" => (ENUMERABLE_NON_ESCAPING + HASH_EXTRA).freeze,
        "Range" => (ENUMERABLE_NON_ESCAPING + RANGE_EXTRA).freeze,
        "Set" => ENUMERABLE_NON_ESCAPING,
        "Integer" => INTEGER_EXTRA,
        "Enumerator" => ENUMERABLE_NON_ESCAPING,
        "Enumerator::Lazy" => ENUMERABLE_NON_ESCAPING,
        "IO" => (STREAM_ENUMERABLE_NON_ESCAPING | IO_ITERATION | IO_SINGLETON_ITERATION).freeze,
        "File" => (STREAM_ENUMERABLE_NON_ESCAPING | IO_ITERATION | IO_SINGLETON_ITERATION).freeze,
        "StringIO" => (STREAM_ENUMERABLE_NON_ESCAPING | IO_ITERATION).freeze
      }.freeze

      # Issue #1234 — the catalogued modules a project class reaches only through its ancestry, read only by
      # {.ancestry_non_escaping?} after the project has been ruled out as the method's owner. `Enumerable`'s
      # methods run the block from inside the call, through the includer's `each` — minus
      # {DEFERRED_ENUMERATOR_METHODS}, whose Enumerator outlives it, and minus `each` itself, which
      # `Enumerable` does not declare: the includer supplies it, so nothing here speaks for it. For that
      # reason a receiver typed as the bare module is not a key of {NON_ESCAPING} either.
      MIXIN_NON_ESCAPING = {
        "Enumerable" => (STREAM_ENUMERABLE_NON_ESCAPING - %i[each]).freeze
      }.freeze

      # Every name a {NON_ESCAPING} entry lists as iteration, for {.iterator_name?} and the ancestry gate.
      ITERATOR_NAMES = (NON_ESCAPING.values.flatten.to_set - OBJECT_NON_ESCAPING).freeze

      # Methods that are documented to **retain** the block past the call. The block is stored or scheduled,
      # so outer narrowing facts on writeable captured locals cannot survive.
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
