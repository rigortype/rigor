# frozen_string_literal: true

require "prism"

require_relative "../source/alias_names"
require_relative "../source/node_children"

module Rigor
  module Inference
    # ADR-121 WD7 (issues #1796, #1799) — what a `refine` body tells the refinement table, read the one way the project
    # walk (`ScopeIndexer#record_refinement_defs`) and the gem source walker
    # (`Analysis::DependencySourceInference::Walker#walk_refine_body`) both use, so the two cannot drift. The table is
    # `{refined class => {method => [refining modules]}}`; `Scope::DiscoveryIndex::REFINEMENT_WILDCARD` stands for
    # what could not be read.
    #
    # A body is fully read when every call on its own `self` (the refinement module) is one that defines a name the
    # walk can spell, or one that defines nothing: a `def`, an `alias` or `alias_method` of two literal names, a
    # `define_method` of a literal name, an `attr_*` of literal names, an `undef`, a visibility call, or
    # `Refinement#target`. Anything
    # else (`import_methods`, `send`, a computed `define_method`, `include`, a nested `refine`, any other call on
    # `self`) may define a name the walk cannot spell, so the body's names are incomplete and the table gets a
    # names-wildcard row for each target. A call on another receiver cannot define a method on the refinement, and
    # a call inside a `def` or `define_method` body runs on an instance of the refined class, so neither counts.
    module RefineCensus
      # `names`, every name the body is read to define, in textual order; `complete`, whether those are all of them;
      # `defs`, the typed refined arm's bodies in textual order: `[name, Prism::DefNode]` for a `def` or an alias of
      # an earlier `def`, and `[name, nil]` for any other definer (`define_method`, `attr_*`, `undef`, an alias of a
      # name the body did not define earlier). A later definer replaces an earlier one, as Ruby's method table
      # keeps the last, so a name whose last definer has no `DefNode` types as `Dynamic[top]`.
      BodyReading = Struct.new(:names, :complete, :defs)

      # Calls on the refinement that define nothing: visibility, with no argument, literal names, a `def`, or an
      # allowlisted definer call.
      VISIBILITY_CALLS = Set[:private, :public, :protected, :module_function, :private_constant].freeze
      # `Refinement#target`, a reader of the refined class (the other `Refinement` method on Ruby 4.0.5 is
      # `import_methods`).
      READER_CALLS = Set[:target].freeze
      # `attr_*` and whether each defines the reader and the writer.
      ATTR_CALLS = {
        attr_reader: [true, false].freeze, attr_writer: [false, true].freeze, attr_accessor: [true, true].freeze,
        attr: [true, false].freeze
      }.freeze

      # A3 — the calls whose String argument may hold `refine` as code or as a method name, and the two families
      # whose `self` is their receiver (so `M.send(:refine, …)` runs `refine` on `M`).
      SEND_CALLS = Set[:send, :__send__, :public_send].freeze
      SELF_EVAL_CALLS = Set[:instance_eval, :class_eval, :module_eval, :instance_exec, :class_exec, :module_exec].freeze
      NAMING_CALLS = Set[
        :method, :public_method, :singleton_method, :instance_method, :public_instance_method, :define_method,
        :define_singleton_method, :alias_method
      ].freeze
      REFINE_WORD = /\brefine\b/

      private_constant :VISIBILITY_CALLS, :READER_CALLS, :ATTR_CALLS, :REFINE_WORD

      module_function

      def wildcard = Scope::DiscoveryIndex::REFINEMENT_WILDCARD

      # §2.2 — what `body` (a refine block's body, or nil) defines on the refined class.
      def read_body(body)
        reading = BodyReading.new([], true, [])
        scan_body(body, reading, {}, true) if body
        reading.names.uniq!
        reading
      end

      # Records `reading`'s names for each of `targets` under `refining` into `table` (nil starts one), plus a
      # names-wildcard row per target when the body's names are incomplete. Returns the table.
      def record_rows(table, targets, reading, refining)
        table ||= {}
        targets.each do |class_name|
          reading.names.each { |name| add_row(table, class_name, name, refining) }
          add_row(table, class_name, wildcard, refining) unless reading.complete
        end
        table
      end

      # One `{class_name => {method_key => [refining]}}` entry, `refining` once.
      def add_row(table, class_name, method_key, refining)
        modules = ((table[class_name] ||= {})[method_key] ||= [])
        modules << refining unless modules.include?(refining)
        table
      end

      # A3 — a `:refine` Symbol literal: it may name `Module#refine` for `send`, `alias_method`, `method`, ….
      def refine_symbol?(node) = node.is_a?(Prism::SymbolNode) && node.unescaped == "refine"

      # A3 — a String literal (or a heredoc's literal part) holding the word `refine`, as code an eval runs or as a
      # method name.
      def refine_string?(node)
        case node
        when Prism::StringNode then REFINE_WORD.match?(node.unescaped)
        when Prism::InterpolatedStringNode then node.parts.any? { |part| refine_string?(part) }
        else false
        end
      end

      # A3 — does a String argument of `call` count: an eval, `send` or method-naming call?
      def string_literal_call?(call)
        name = call.name
        name == :eval || SELF_EVAL_CALLS.include?(name) || SEND_CALLS.include?(name) || NAMING_CALLS.include?(name)
      end

      # A3 — the `self` a refine literal argument of `call` runs `refine` on: `:receiver` for a `send` or `*_eval`
      # / `*_exec` call (the receiver, or the caller's `self` when it has none or it is `self`), `:unknown` for an
      # `eval` on a binding, `:self` for everything else (the caller's `self`).
      def literal_target(call)
        receiver = call.receiver
        self_receiver = receiver.nil? || receiver.is_a?(Prism::SelfNode)
        if SEND_CALLS.include?(call.name) || SELF_EVAL_CALLS.include?(call.name)
          self_receiver ? :self : :receiver
        elsif call.name == :eval
          self_receiver ? :self : :unknown
        else
          :self
        end
      end

      # An implicit- or `self`-receiver call: one whose `self` is the walk's `self`.
      def self_call?(node) = node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)

      # `classify` is false inside a `define_method` block or its arguments, whose calls run on an instance of the
      # refined class (or before the method exists), so they define nothing on the refinement. `latest` maps each
      # name to the last `def` the body wrote for it so far, which an alias copies.
      def scan_body(node, reading, latest, classify)
        case node
        when Prism::DefNode
          record_def(node, reading, latest) if node.receiver.nil?
          return
        when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
          return
        when Prism::AliasMethodNode
          return record_alias(Source::AliasNames.keyword_names(node), reading, latest)
        when Prism::UndefNode
          return record_undef(node, reading, latest)
        when Prism::CallNode
          if classify && self_call?(node)
            classify_call(node, reading, latest)
            classify = node.name != :define_method
          end
        end

        node.rigor_each_child { |child| scan_body(child, reading, latest, classify) }
      end

      def record_def(node, reading, latest)
        reading.names << node.name
        reading.defs << [node.name, node]
        latest[node.name] = node
      end

      # `alias new old` / `alias_method :new, :old`: `new` is defined; it copies `old`'s body when the refine body
      # wrote `old` earlier (Ruby copies at the alias, so a later `def old` does not move it), and otherwise it
      # copies the refined class's own method, whose body the walk does not hold.
      def record_alias(pair, reading, latest)
        return reading.complete = false if pair.nil?

        new_name, old_name = pair
        reading.names << new_name
        def_node = latest[old_name]
        return record_bodiless(new_name, reading, latest) if def_node.nil?

        reading.defs << [new_name, def_node]
        latest[new_name] = def_node
      end

      # A name a definer with no `DefNode` defines: it replaces any earlier `def` of the name, so the typed arm
      # finds no body for it (`refine(String) { def center(a) = 1; define_method(:center) { |a| "dm" } }` answers
      # `"dm"` on Ruby 4.0.5), and an alias of it copies no body either.
      def record_bodiless(name, reading, latest)
        reading.names << name
        reading.defs << [name, nil]
        latest.delete(name)
      end

      def record_undef(node, reading, latest)
        node.names.each do |name|
          if name.is_a?(Prism::SymbolNode)
            record_bodiless(name.unescaped.to_sym, reading, latest)
          else
            reading.complete = false
          end
        end
      end

      # Classifies a call on the refinement.
      def classify_call(node, reading, latest)
        name = node.name
        arguments = node.arguments&.arguments || []
        if (attr = ATTR_CALLS[name])
          record_attr(arguments, attr, reading, latest)
        elsif name == :define_method
          record_define_method(arguments, reading, latest)
        elsif name == :alias_method
          record_alias(Source::AliasNames.alias_method_call_names(node), reading, latest)
        else
          reading.complete = false unless defines_nothing?(node, arguments)
        end
      end

      # A visibility call with no argument, literal names, a `def` or a call; `Refinement#target` with none.
      def defines_nothing?(node, arguments)
        return arguments.all? { |argument| visibility_argument?(argument) } if VISIBILITY_CALLS.include?(node.name)

        READER_CALLS.include?(node.name) && arguments.empty? && node.block.nil?
      end

      def record_attr(arguments, (reader, writer), reading, latest)
        arguments.each do |argument|
          name = literal_name(argument)
          next reading.complete = false if name.nil?

          record_bodiless(name, reading, latest) if reader
          record_bodiless(:"#{name}=", reading, latest) if writer
        end
      end

      def record_define_method(arguments, reading, latest)
        name = arguments.first && literal_name(arguments.first)
        name ? record_bodiless(name, reading, latest) : reading.complete = false
      end

      # `private`, `private :a, "b"`, `private def x`, `private attr_reader :x`: the nested call is classified on
      # its own when the walk descends into it.
      def visibility_argument?(argument)
        argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode) || argument.is_a?(Prism::DefNode) ||
          argument.is_a?(Prism::CallNode)
      end

      def literal_name(node)
        node.unescaped&.to_sym if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
      end
    end
  end
end
