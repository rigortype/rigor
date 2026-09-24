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
        return if node.superclass.nil? || opaque?(full_name)

        superclass = Source::ConstantPath.qualified_name(node.superclass)
        @superclasses[full_name] =
          superclass ? lexical_candidates(superclass, prefix) : [FileCollection::OPAQUE_ANCESTOR]
      end

      # A class BUILT AT LOAD TIME and assigned to a constant — `Anon = Class.new(Base)`,
      # `Point = Struct.new(:x)`, `Rec = Data.define(:x)`, `Dele = DelegateClass(X)` — records the opaque
      # sentinel (#1039). Without it a later `class Point; def more; end; end` reopening is the only thing
      # the scan sees: the class becomes project-known, nothing says what is above it, and the constructor
      # rule would read that silence as "no constructor anywhere" when the constructor is precisely what
      # the load-time call built. It is the `class K < Struct.new(:a)` case in its other spelling.
      #
      # Only a **call**-valued assignment qualifies. A literal cannot be a class, and a constant-path value
      # (`Alias = Real`) is a second name for a class whose own ancestry the scan already recorded.
      #
      # The sentinel is **sticky**: it overwrites a spelled `< Base` and no later one displaces it, here or
      # in {FileCollection.merge_all}. A reopening's `class Anon < Base` is not more than this says but
      # less — `Anon = Class.new(Base) { def initialize; … end }` puts a constructor in the block, which the
      # scan files under the enclosing namespace and cannot attribute to `Anon` at all, and the spelled
      # superclass says nothing about it. Sticky is also what makes the answer independent of which file a
      # run reads first.
      #
      # `Class.new(Base)` additionally keeps `Base` beside the sentinel. The sentinel still declines
      # `Anon.new` itself, and the parent link is what files `Anon` under `Base` in the subclass index, so
      # a `self.class.new` in `Base` — which the closed-world join says may construct `Anon` — sees an
      # unreadable constructor below it and declines too.
      def record_constant_class(node, prefix)
        value = node.value
        return unless value.is_a?(Prism::CallNode)

        name = constant_write_name(node, prefix)
        return if name.nil?

        @superclasses[name] = [FileCollection::OPAQUE_ANCESTOR, *load_time_parent(value, prefix)]
      end

      # A receiver-less `include` / `prepend` in `class_name`'s body, its constant arguments recorded as
      # written.
      #
      # Both are calls on `self`, like `define_method`. Where `self` is the singleton class — inside
      # `class << self`, or `singleton_class.class_eval` — they mix the module into the singleton class,
      # which is what `extend` does. The include table is the instance ancestry that `super` and the
      # constructor rule walk, so such a call records nothing, and the collection is as blind to it as it
      # is to `extend`.
      #
      # @param context — the {DefinitionContext} of the class-body position the call sits at
      def record_includes(class_name, node, prefix, context)
        return if context.self_singleton_class?

        names = node.arguments&.arguments&.filter_map { |argument| Source::ConstantPath.qualified_name(argument) }
        candidates = (names || []).flat_map { |name| lexical_candidates(name, prefix) }
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
        when Prism::AliasMethodNode then literal_name(node.new_name) == "initialize"
        when Prism::CallNode
          node.receiver.nil? && node.name == :alias_method && literal_name(first_argument(node)) == "initialize"
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

      def opaque?(full_name)
        @superclasses.fetch(full_name, []).include?(FileCollection::OPAQUE_ANCESTOR)
      end

      # The superclass a `Class.new(Base)` names, as candidates. Read from `Class.new` alone: it is the one
      # load-time builder whose first argument IS the superclass, and inventing an ancestry edge from any
      # other call's first constant argument would let an unrelated class's methods resolve through it.
      def load_time_parent(value, prefix)
        return [] unless value.name == :new && constant_receiver_name(value.receiver) == "Class"

        argument = value.arguments&.arguments&.first
        name = argument && Source::ConstantPath.qualified_name(argument)
        name ? lexical_candidates(name, prefix) : []
      end

      def constant_receiver_name(receiver)
        Source::ConstantPath.qualified_name(receiver) if receiver.is_a?(Prism::ConstantReadNode)
      end

      # `alias_method :initialize, :setup` and `alias_method "initialize", "setup"` are the same
      # declaration; only an interpolated name is beyond the scan.
      def literal_name(node)
        node.unescaped if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
      end

      # The key a constant assignment declares, qualified by the nesting it is written in.
      def constant_write_name(node, prefix)
        case node
        when Prism::ConstantWriteNode then [*prefix, node.name.to_s].join("::")
        when Prism::ConstantPathWriteNode then qualified_write_name(node, prefix)
        end
      end

      def qualified_write_name(node, prefix)
        target = Source::ConstantPath.qualified_name(node.target)
        return nil if target.nil?
        return target if prefix.empty? || target.start_with?("#{prefix.join('::')}::")

        [*prefix, target].join("::")
      end

      def first_argument(node)
        node.arguments&.arguments&.first
      end
    end
  end
end
