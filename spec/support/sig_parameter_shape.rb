# frozen_string_literal: true

require "prism"
require "rbs"

# Issue #3335 — does each `sig/` overload's parameter list fit the `def` it declares?
#
# The provenance gate ({SigProvenanceAuditor}) reads a declaration's RETURN against what sig-gen proves, and
# nothing read its parameter LIST: `(untyped x, untyped y, key: String) -> untyped` over `def n(x, y, &blk)`
# classified without complaint, and no CI job runs Steep. A parameter TYPE is authored intent (ADR-5 clause 2)
# and stays unchecked here; its SHAPE is not a matter of intent, so it is compared with the Prism parameters of
# every `def` sig-gen's walk records for the declaration's `[class, method, kind]`, in any file and whether or not
# sig-gen made a candidate of it (a parameterless `initialize`, a slot contested between `if` / `else` branches).
# The overload fits when ANY of those defs accepts it: which one runs is not known statically.
#
# == The rule
#
# An overload fits when every call it admits is one the `def` accepts:
#
# - positional count: the overload's least (`required + trailing`) is at least the def's least, and its most is
#   at most the def's most (`*rest` on either side makes the most unbounded). An overload may therefore omit
#   optional positionals, or make one required, but may not demand fewer than the def does or offer more.
# - keywords: every keyword the overload names, required or optional, is one the def takes, unless the def has
#   `**rest`; every keyword the def requires is required in the overload. An overload may omit optional keywords.
#   An overload `**rest` needs a def `**rest`. A def with no keyword parameter at all (and no `**nil`) takes
#   keywords as a positional Hash, so there they fit when the overload leaves a free optional or rest slot.
# - block: an overload that declares a block, required or optional, needs a def that takes one: `&blk`, `&`, or a
#   body that yields (a `yield` inside a block in the body included), asks `block_given?` or `iterator?` (bare, on
#   `self` or on `Kernel`), or calls `super` (which passes the block on). A def that takes a block
#   may be declared without one; the overload is then narrower than the def, as with an omitted optional.
#
# `...` accepts anything past the positionals written before it. `(?)` overloads are exempt. A declaration
# with no recorded `def` (an `attr_*`, an `alias`, a `define_method`, a `Data`/`Struct` member, a delegated or
# inherited method) has no ordinary parameter list to read and is counted as exempt, by reason, never dropped.
# That count is the check's own bookkeeping: it proves every method row was compared or bucketed, not that a
# bucketed row had no `def` to compare.
module SigParameterShape
  # Why a method declaration was not compared. Each row lands in exactly one, or is compared.
  # sig-gen has no candidate and its walk records no `def` of that `[class, method, kind]` in any file: attr, alias,
  # define_method, a Data/Struct member, an inherited or runtime-defined method.
  EXEMPT_NO_DEF = :no_def
  EXEMPT_ATTRIBUTE = :attribute # an `attr_*` member: RBS spells no parameter list
  # sig-gen has a candidate but no `def` is recorded: the candidate is a Data/Struct member or an `attr_*`.
  EXEMPT_CANDIDATE_WITHOUT_DEF = :candidate_without_def
  EXEMPT_UNTYPED_FUNCTION = :untyped_function # every overload is `(?)`
  EXEMPT_REASONS = [EXEMPT_NO_DEF, EXEMPT_ATTRIBUTE, EXEMPT_CANDIDATE_WITHOUT_DEF, EXEMPT_UNTYPED_FUNCTION].freeze

  Result = Struct.new(:compared, :exempt, :mismatches, keyword_init: true) do
    def summary
      by_reason = SigParameterShape::EXEMPT_REASONS.map { |reason| "#{reason} #{exempt.fetch(reason, 0)}" }
      "#{compared} compared, #{exempt.values.sum} exempt (#{by_reason.join(', ')}), #{mismatches.size} mismatched"
    end
  end

  Mismatch = Struct.new(:declaration, :declared, :defined, :reason, keyword_init: true) do
    def path = declaration.path

    # A singleton declaration reads `Class.name`, as Ruby spells the call.
    def to_s
      separator = declaration.kind == :singleton ? "." : "#"
      "#{declaration.path}:#{declaration.line}: #{declaration.class_name}#{separator}#{declaration.method_name} — " \
        "declared `#{declared}`, def `#{defined}`: #{reason}"
    end
  end

  # What a `def`'s parameter list accepts. `rest` / `keyrest` mean an unbounded positional / keyword tail; `nokey` is
  # `**nil`, which refuses keywords outright instead of collecting them into a positional Hash.
  DefShape = Data.define(:required, :optional, :trailing, :rest, :required_keywords, :optional_keywords,
                         :keyrest, :block, :nokey) do
    def least = required + trailing
    def most = rest ? Float::INFINITY : required + optional + trailing
    def keywords = required_keywords + optional_keywords

    # Ruby passes keywords to a def with no keyword parameter as one positional Hash.
    def keywords_as_hash? = keywords.empty? && !keyrest && !nokey
  end

  class << self
    # @param rows — {SigProvenanceAuditor::Row}s; every method row is compared or counted as exempt.
    def check(rows)
      exempt = Hash.new(0)
      mismatches = []
      compared = 0
      rows.each do |row|
        next if row.declaration.kind.nil?

        reason = exempt_reason(row)
        next exempt[reason] += 1 if reason

        compared += 1
        mismatches.concat(row_mismatches(row))
      end
      Result.new(compared: compared, exempt: exempt, mismatches: mismatches)
    end

    # The def's parameters as Ruby spells them, for a failure message.
    def def_spelling(def_node)
      receiver = def_node.receiver ? "#{def_node.receiver.slice}." : ""
      "def #{receiver}#{def_node.name}(#{def_node.parameters&.slice})"
    end

    def def_shape(def_node)
      params = def_node.parameters
      return DefShape.new(0, 0, 0, false, [], [], false, yields?(def_node.body), false) if params.nil?

      forwarding = params.keyword_rest.is_a?(Prism::ForwardingParameterNode)
      DefShape.new(
        required: params.requireds.size, optional: params.optionals.size, trailing: params.posts.size,
        rest: forwarding || params.rest.is_a?(Prism::RestParameterNode),
        required_keywords: keyword_names(params, Prism::RequiredKeywordParameterNode),
        optional_keywords: keyword_names(params, Prism::OptionalKeywordParameterNode),
        keyrest: forwarding || params.keyword_rest.is_a?(Prism::KeywordRestParameterNode),
        block: forwarding || !params.block.nil? || yields?(def_node.body),
        nokey: params.keyword_rest.is_a?(Prism::NoKeywordsParameterNode)
      )
    end

    # Why `overload` (an `RBS::MethodType`) does not fit `shape`, or nil when it does.
    def misfit(method_type, shape)
      function = method_type.type
      positional_misfit(function, shape) || keyword_misfit(function, shape) || block_misfit(method_type, shape)
    end

    private

    def exempt_reason(row)
      return EXEMPT_ATTRIBUTE if row.declaration.overloads.nil?
      return EXEMPT_UNTYPED_FUNCTION if row.declaration.overloads.all? { |o| untyped_function?(o) }
      return nil if row.source_defs&.any?

      row.paired ? EXEMPT_CANDIDATE_WITHOUT_DEF : EXEMPT_NO_DEF
    end

    def untyped_function?(overload) = overload.method_type.type.is_a?(RBS::Types::UntypedFunction)

    # An overload fits when any recorded def of the slot accepts it; a misfit reports the first def's reason.
    def row_mismatches(row)
      shapes = row.source_defs.map { |def_node| def_shape(def_node) }
      row.declaration.overloads.filter_map do |overload|
        next if untyped_function?(overload)

        reasons = shapes.map { |shape| misfit(overload.method_type, shape) }
        next if reasons.any?(&:nil?)

        Mismatch.new(declaration: row.declaration, declared: overload.method_type.to_s,
                     defined: row.source_defs.map { |d| def_spelling(d) }.join("` | `"), reason: reasons.first)
      end
    end

    def positional_least(function) = function.required_positionals.size + function.trailing_positionals.size

    def positional_most(function)
      function.rest_positionals ? Float::INFINITY : positional_least(function) + function.optional_positionals.size
    end

    def positional_misfit(function, shape)
      least = positional_least(function)
      most = positional_most(function)
      if least < shape.least
        "admits #{least} positional argument(s), the def requires #{shape.least}"
      elsif most > shape.most
        "admits #{most == Float::INFINITY ? 'any number of' : most} positional argument(s), " \
          "the def takes at most #{shape.most}"
      end
    end

    def keyword_misfit(function, shape)
      required = function.required_keywords.keys
      named = required + function.optional_keywords.keys
      return nil if hash_slot_free?(function, named, shape)

      unknown = shape.keyrest ? [] : named - shape.keywords
      return "names keyword(s) the def does not take: #{unknown.join(', ')}" if unknown.any?

      missing = shape.required_keywords - required
      return "does not require keyword(s) the def requires: #{missing.join(', ')}" if missing.any?
      return "declares **rest, the def takes no keyword rest" if function.rest_keywords && !shape.keyrest

      nil
    end

    # Keywords on a def without keyword parameters arrive as one positional Hash: they fit when a free optional or
    # rest slot remains past every positional the overload admits.
    def hash_slot_free?(function, named, shape)
      shape.keywords_as_hash? && (named.any? || function.rest_keywords) && positional_most(function) + 1 <= shape.most
    end

    def block_misfit(method_type, shape)
      return nil if method_type.block.nil? || shape.block

      "declares a block, the def neither takes nor yields one"
    end

    def keyword_names(params, node_class)
      params.keywords.grep(node_class).map(&:name)
    end

    # Whether the body uses the block it was called with without naming it: `yield` (inside a block of the body too,
    # the enumerator shape `each { |e| yield e }`), `block_given?` / `iterator?` bare, on `self` or on `Kernel`, or
    # a `super` (bare or with arguments), which passes the block on. A nested `def` or class is its own scope and is
    # not read.
    def yields?(node)
      return false if node.nil?

      case node
      when Prism::YieldNode, Prism::ForwardingSuperNode, Prism::SuperNode then true
      when Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode then false
      when Prism::CallNode
        (block_query_receiver?(node.receiver) && %i[block_given? iterator?].include?(node.name)) ||
          node.compact_child_nodes.any? { |child| yields?(child) }
      else node.compact_child_nodes.any? { |child| yields?(child) }
      end
    end

    def block_query_receiver?(receiver)
      receiver.nil? || receiver.is_a?(Prism::SelfNode) ||
        (receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :Kernel) ||
        (receiver.is_a?(Prism::ConstantPathNode) && receiver.parent.nil? && receiver.name == :Kernel)
    end
  end
end
