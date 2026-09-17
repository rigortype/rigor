# frozen_string_literal: true

require "prism"

require_relative "../source/constant_path"
require_relative "file_collection"

module Rigor
  module Effects
    # The ancestry half of a file's {FileCollection}: what each class declares above itself, what it
    # includes, and where the scan has to admit it could not read the ancestry at all.
    #
    # Split out of {Scanner} because the three questions are one subject with one invariant — a name goes
    # in **as written**, and the propagator, which is the only place the whole project is in view, decides
    # which constant it meant. The scanner owns unit identity and delegates this; the two tables are handed
    # back by {#superclasses} / {#includes} and go into the collection unchanged.
    class AncestryRecorder
      attr_reader :superclasses, :includes

      def initialize
        @superclasses = {}
        @includes = {}
      end

      # `class Loud < Base` inside `module Tracer` names `Base`, so the candidates go in and the propagator
      # picks the one the merged project defines.
      #
      # A superclass expression that is **not** a constant path — `class K < Struct.new(:a)`,
      # `< Data.define(:a)`, `< DelegateClass(X)`, `< Sequel::Model(:t)` — records
      # {FileCollection::OPAQUE_ANCESTOR} rather than nothing (#1039). Recording nothing made it
      # indistinguishable from a class with no `<` at all, which is the one reading the constructor rule
      # turns into an answer; such a class inherits a constructor built at load time, which is the
      # opposite of an absent one.
      def record_superclass(full_name, node, prefix)
        return if node.superclass.nil?

        superclass = Source::ConstantPath.qualified_name(node.superclass)
        @superclasses[full_name] =
          superclass ? lexical_candidates(superclass, prefix) : [FileCollection::OPAQUE_ANCESTOR]
      end

      # @param names — the constant paths an `include` / `prepend` named, as written
      def record_includes(class_name, names, prefix)
        candidates = names.flat_map { |name| lexical_candidates(name, prefix) }
        (@includes[class_name] ||= []).concat(candidates) unless candidates.empty?
      end

      # `alias initialize setup` / `alias_method :initialize, :setup` makes the constructor another
      # method's body, and the scan models no aliases at all (#1039). The opaque sentinel is the minimal
      # honest answer: the ancestry stops being readable, the constructor rule declines, and this class's
      # callers stay exactly as unclaimed as they were before that rule existed.
      def record_initialize_alias(class_name)
        (@includes[class_name] ||= []) << FileCollection::OPAQUE_ANCESTOR
      end

      # Whether this node aliases `initialize`, in either spelling. A `CallNode` qualifies only as a
      # receiver-less `alias_method` whose first symbol argument is the new name.
      def alias_to_initialize?(node)
        case node
        when Prism::AliasMethodNode then symbol_name(node.new_name) == "initialize"
        when Prism::CallNode
          node.receiver.nil? && node.name == :alias_method && symbol_name(first_argument(node)) == "initialize"
        else false
        end
      end

      # An ancestry name is recorded AS WRITTEN — a single file cannot say which constant it resolves to.
      # So the candidates Ruby's own lexical lookup would try go in, most-qualified first, and the
      # propagator picks the one the merged project actually defines. Same shape as `ScopeIndexer`'s
      # as-written superclass table, resolved at the same point: when the whole project is in view.
      def lexical_candidates(name, prefix)
        return [name] if prefix.empty? || name.start_with?("#{prefix.join('::')}::")

        prefix.length.downto(1).map { |depth| "#{prefix.first(depth).join('::')}::#{name}" } + [name]
      end

      private

      def symbol_name(node)
        node.unescaped if node.is_a?(Prism::SymbolNode)
      end

      def first_argument(node)
        node.arguments&.arguments&.first
      end
    end
  end
end
