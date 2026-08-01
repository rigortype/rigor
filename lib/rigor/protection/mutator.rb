# frozen_string_literal: true

require "prism"

require_relative "../scope"
require_relative "../inference/scope_indexer"
require_relative "../source/node_children"

module Rigor
  # ADR-63 Tier 2 — the productized subset of the dev-only mutation-testing harness (`tool/mutation/`, ADR-62).
  # Only the *per-file effectiveness measurement* lives here — the type-visible {Mutator} and the warm-loop
  # {MutationScanner} kill-rate measurement. The dev sweep / fuzz / survivor clustering stay off the frozen
  # surface in `tool/mutation/mutate.rb` (which now reuses this {Mutator} so there is one source of truth).
  module Protection
    # One concrete edit: replace source bytes [start, stop) with `replacement`. `anchor` is the Prism node whose
    # inferred type decides type-relevance — the call receiver whose contract the mutation could violate, or nil
    # when there is no concrete receiver (implicit-self call, literal outside a call). `anchor_type` (the
    # rendered receiver type) and `method_name` are filled in for reporting a surviving site; both may stay nil.
    Mutation = Struct.new(
      :operator, :expected_rule, :start, :stop, :replacement, :line, :label, :anchor,
      :anchor_type, :method_name,
      keyword_init: true
    ) do
      def apply(source)
        prefix = source.byteslice(0, start)
        suffix = source.byteslice(stop, source.bytesize - stop) || ""
        "#{prefix}#{replacement}#{suffix}"
      end
    end

    # Generates type-visible mutations of a Ruby source string by walking the Prism AST and recording byte-range
    # splices (no unparser needed — Prism hands us exact offsets, and the analyzer re-parses the spliced source).
    #
    # A mutation is "type-visible" when it should trip a diagnostic rule *if* Rigor holds a type at the site: a
    # call-argument literal dropped to `nil` or type-swapped (→ `call.argument-type-mismatch`), or a call site
    # renamed to a missing method (→ `call.undefined-method`). Only call sites and bodies are mutated, never
    # `def` signatures, so a reused project scan stays valid.
    class Mutator
      IDENT = /\A[a-z_][A-Za-z0-9_]*\z/
      QUOTES = ['"', "'"].freeze
      # Mutating an argument to a universal-equality method is always an equivalent mutant: Ruby's `==` / `<=>`
      # family returns false / nil on a type mismatch rather than raising, so the engine exempts them
      # (`UNIVERSAL_EQUALITY_METHODS`). Skip them to keep survivors meaningful.
      UNIVERSAL_EQUALITY = %w[== != eql? equal? <=>].freeze

      # Every operator the mutator knows. Each maps to the diagnostic rule family it is *engineered* to trip when
      # the mutated value/call sits in a context where Rigor has type knowledge.
      ALL_OPERATORS = %i[nil_inject type_swap undefined_method arity_extra].freeze

      # The default set. `arity_extra` is excluded: most Ruby methods accept an extra argument (splat / optional),
      # so appending one is usually an equivalent mutant — it contributes almost only noise. Re-enable it
      # explicitly via `operators:` to measure arity teeth. (A signature-arity guard would make it
      # default-worthy — a follow-up.)
      OPERATORS = %i[nil_inject type_swap undefined_method].freeze

      def initialize(source, operators: OPERATORS)
        @source = source
        @operators = operators
        @parse = Prism.parse(source)
        @anchor_for = {} # literal node -> its enclosing call's receiver node (or nil)
      end

      def mutations
        return [] unless @parse.success?

        index_literal_anchors(@parse.value)
        out = []
        walk(@parse.value) { |node| collect(node, out) }
        out
      end

      # Phase 1.5 — keep only mutations whose anchor types to a concrete, non-Dynamic type, i.e. a site where
      # Rigor actually holds a contract the mutation could violate. Drops implicit-self calls and literals
      # outside a typed call (no contract → guaranteed survival → noise). FP-safe direction: an
      # unresolved/probe-failed type KEEPS the mutation, so the filter never hides a kill it is unsure about — it
      # only removes provably-Dynamic sites. Returns [kept, dropped_count]. Builds the scope index from THIS
      # mutator's parse so anchor node identity matches the keys.
      #
      # @param base_scope [Rigor::Scope, nil] a pre-seeded scope to judge anchors against (see
      #   {#anchor_base_scope}); nil builds the bare empty scope, which is the shipped default.
      def filter_by_type(mutations, environment:, path:, base_scope: nil)
        base = anchor_base_scope(environment, path, base_scope)
        index = Rigor::Inference::ScopeIndexer.index(@parse.value, default_scope: base)
        cache = {}
        kept = mutations.select do |mut|
          keep, type = anchor_decision(mut.anchor, index, cache)
          mut.anchor_type = type if keep
          keep
        end
        [kept, mutations.size - kept.size]
      end

      # ADR-69 Seam 2 (AllSites) — keep every *dispatch-site* mutation (a method call or a call-argument
      # literal), Dynamic receiver included, annotating the anchor type where Rigor holds one. Drops only
      # non-dispatch literals (a literal outside any call — no receiver contract to violate). The biteable
      # {#filter_by_type} hides exactly the Dynamic sites a test-suite consumer most wants to probe: where Rigor
      # cannot bite, a test is the only protection. Use only with a {TestSuiteOracle} — at a Dynamic site the
      # type pass can never kill, so without the test axis these are all noise.
      def dispatch_site_mutations(mutations, environment:, path:, base_scope: nil)
        base = anchor_base_scope(environment, path, base_scope)
        index = Rigor::Inference::ScopeIndexer.index(@parse.value, default_scope: base)
        cache = {}
        mutations.select do |mut|
          next false if mut.method_name.nil?

          _keep, type = anchor_decision(mut.anchor, index, cache)
          mut.anchor_type = type
          true
        end
      end

      private

      # The scope the anchor types are judged against.
      #
      # `base_scope` is nil on the shipped path, and the result is then the bare empty scope this file has always
      # used: a single-file view in which a constant receiver declared in a *sibling* file reads `Dynamic`, so its
      # dispatch site is dropped from the Tier-2 denominator. The caller may instead hand down a scope already
      # carrying the cross-file discovery Tier 1 seeds (`discovered_classes` + `param_inferred_types`), in which
      # case the same site resolves to the type it really has and is measured — `coverage --protection --mutation`
      # does that behind the `discovery-seeded-mutation-sites` bleeding-edge feature (#253).
      #
      # Deliberately a plain parameter: this class knows nothing about {Rigor::Configuration} or feature ids. The
      # gate lives in the CLI layer, which is the only layer that has a Configuration to ask.
      #
      # `source_path` is per-file, so a shared base scope is re-stamped here rather than rebuilt per path.
      def anchor_base_scope(environment, path, base_scope)
        return Rigor::Scope.empty(environment: environment, source_path: path) if base_scope.nil?

        base_scope.with_source_path(path)
      end

      def walk(node, &blk)
        return if node.nil?

        blk.call(node)
        node.rigor_each_child { |child| walk(child, &blk) }
      end

      def collect(node, out)
        case node
        when Prism::IntegerNode, Prism::FloatNode
          literal_mutations(node, out, numeric: true)
        when Prism::StringNode
          literal_mutations(node, out, numeric: false)
        when Prism::CallNode
          call_mutations(node, out)
        end
      end

      # Record, for each literal that is a direct call argument, the receiver of the enclosing call — the anchor
      # whose param contract a literal mutation could violate. Literals elsewhere get a nil anchor (filtered out
      # under the type filter).
      def index_literal_anchors(node)
        return if node.nil?

        if node.is_a?(Prism::CallNode) && node.arguments
          node.arguments.arguments.each do |arg|
            @anchor_for[arg] = [node.receiver, node.name.to_s] if literal?(arg)
          end
        end
        node.rigor_each_child { |child| index_literal_anchors(child) }
      end

      def literal?(node)
        node.is_a?(Prism::IntegerNode) || node.is_a?(Prism::FloatNode) || node.is_a?(Prism::StringNode)
      end

      # Returns [keep?, rendered_type]. Keep when `anchor` is a site where Rigor holds a concrete (non-Dynamic/Top)
      # type. FP-safe: an unresolved or probe-failed type keeps the mutation (with a nil rendered type).
      def anchor_decision(anchor, index, cache)
        return [false, nil] if anchor.nil?
        return cache[anchor] if cache.key?(anchor)

        cache[anchor] = compute_anchor_decision(anchor, index)
      end

      def compute_anchor_decision(anchor, index)
        scope = index[anchor]
        return [true, nil] if scope.nil? # unresolved scope → keep (FP-safe)

        type = scope.type_of(anchor)
        return [true, nil] if type.nil?

        concrete = !non_concrete_type?(type)
        [concrete, concrete ? render_type(type) : nil]
      rescue StandardError
        [true, nil] # never let a probe failure hide a candidate
      end

      # A receiver type Rigor cannot bite on, so a mutation anchored to it would survive as noise: `Dynamic` /
      # `Top` / `bot`, or a union with any such arm (gradually valid — `Array | Dynamic[top]`.whatever never
      # fires). A union of fully-concrete arms (`String | Symbol`) stays concrete — it now has undefined-method
      # teeth.
      def non_concrete_type?(type)
        return true if type.is_a?(Rigor::Type::Dynamic) || type.is_a?(Rigor::Type::Top) ||
                       type.is_a?(Rigor::Type::Bot)
        return type.members.any? { |member| non_concrete_type?(member) } if type.is_a?(Rigor::Type::Union)

        false
      end

      def render_type(type)
        type.respond_to?(:describe) ? type.describe(:short) : type.to_s
      rescue StandardError
        type.class.name
      end

      # Mutate a literal: drop it to nil (possible-nil channel) and swap its type (type-mismatch channel). String
      # literals are only touched when the node is a real quoted string, so we never corrupt `%w[...]` words.
      def literal_mutations(node, out, numeric:)
        return if !numeric && !QUOTES.include?(node.opening_loc&.slice)

        anchor, method = @anchor_for[node]
        return if UNIVERSAL_EQUALITY.include?(method)

        loc = node.location
        add(out, :nil_inject, "call.argument-type-mismatch", loc.start_offset, loc.end_offset,
            "nil", loc.start_line, "literal → nil  (#{snippet(loc)})", anchor, method)
        swap = numeric ? '"rigor_mutant"' : "0"
        add(out, :type_swap, "call.argument-type-mismatch", loc.start_offset, loc.end_offset,
            swap, loc.start_line, "literal type swap  (#{snippet(loc)} → #{swap})", anchor, method)
      end

      def call_mutations(node, out)
        rename_call(node, out)
        extend_arity(node, out)
      end

      # Rename the *call site* (not the def) to a method that cannot exist, so a typed receiver trips
      # call.undefined-method. We leave `def` signatures untouched on purpose: the prebuilt ProjectScan still
      # carries the file's original declarations, so mutating only bodies/call-sites keeps it valid. Anchor is
      # the explicit receiver (nil ⇒ implicit self ⇒ filtered out, as call.self-undefined-method ships `:off`).
      def rename_call(node, out)
        name = node.name.to_s
        mloc = node.message_loc
        return unless mloc && IDENT.match?(name)

        add(out, :undefined_method, "call.undefined-method", mloc.start_offset, mloc.end_offset,
            "#{name}__rigor_absent", mloc.start_line, "call ##{name} → missing method", node.receiver, name)
      end

      # Append a trailing argument inside explicit `(...)` parens to trip an arity diagnostic against a known
      # fixed-arity signature.
      def extend_arity(node, out)
        open = node.opening_loc
        close = node.closing_loc
        return unless close && open&.slice == "("

        args = node.arguments&.arguments
        insertion = args && !args.empty? ? ", nil" : "nil"
        add(out, :arity_extra, "call.wrong-arity", close.start_offset, close.start_offset,
            insertion, node.location.start_line, "call ##{node.name} +1 arg", node.receiver, node.name.to_s)
      end

      def add(out, operator, rule, start, stop, replacement, line, label, anchor, method_name) # rubocop:disable Metrics/ParameterLists
        return unless @operators.include?(operator)

        out << Mutation.new(operator: operator, expected_rule: rule, start: start, stop: stop,
                            replacement: replacement, line: line, label: label, anchor: anchor,
                            method_name: method_name)
      end

      def snippet(loc)
        text = loc.slice.gsub(/\s+/, " ")
        text.length > 30 ? "#{text[0, 27]}..." : text
      end
    end
  end
end
