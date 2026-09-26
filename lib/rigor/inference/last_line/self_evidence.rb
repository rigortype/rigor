# frozen_string_literal: true

require "prism"

require_relative "../../source/constant_path"
require_relative "../../source/node_children"

module Rigor
  module Inference
    module LastLine
      # Issue #1415 (ADR-117 WD5) — what a file shows about the `self` its implicit-self and `self.` readers run with,
      # read in one walk of the file the first time a reader condition asks ({ImplicitSelf.reader?}), and kept only
      # once complete. The walk runs only for a file that holds such a condition. `Inference::ScopeIndexer` keeps one
      # per file on the discovery index ({Scope::DiscoveryIndex#implicit_self_evidence}), so a callee body another
      # file wrote finds none of its readers here and declines.
      #
      # Each reader is placed in the body whose `self` it runs with: `main` (the script body, a top-level method, a
      # `class << self` at the top level), or a class or module body and its methods. A reader has none, and
      # declines, where the file may give it another `self`:
      #
      # - in a block of `instance_eval`, `instance_exec`, `class_eval`, `module_eval`, `class_exec`, `module_exec`,
      #   `define_method` or `define_singleton_method` (or a `send` that may name one), or of `Class.new`,
      #   `Module.new`, `Struct.new` or `Data.define`, whose block is a class body;
      # - in a method written inside a block, whose owner is the block's `self`, in a module's instance method, whose
      #   `self` is whatever includes the module, and in `class << obj` for any `obj` but `self`.
      #
      # A class or module body is dirty, and its readers decline, when it may gain an ancestor the discovery tables
      # do not record: a superclass that is not a constant (`DelegateClass(File)`, `Struct.new(:a)`), and an
      # `include`, `extend` or `prepend` other than a body statement naming constants (one in a method, a block or
      # `class << self`, `singleton_class.include(M)`, `include(*mods)`).
      #
      # A name is tainted, and every reader of it in the file declines, when the file may change the method that name
      # reaches from `main`, `Object` or an object the analyzer does not follow:
      #
      # - both names: a mixin into `main` (`include`, `extend` or `prepend` on implicit `self` outside a class or
      #   module body, `class << self; include M; end` at the top level, `singleton_class.include(M)`), a mixin on
      #   any explicit receiver (`Object.include(M)`, `TOPLEVEL_BINDING.receiver.extend(M)`, `obj.extend(M)`), any
      #   mixin in an `Object`, `Kernel` or `BasicObject` body, a `send` that may name one, any `using`, a proc
      #   handed to one of the `self`-rebinding calls above (`obj.instance_exec(&blk)`), whose body may be a block
      #   the file wrote anywhere, an eval of a String, whose code may do any of these, and a `const_set`, which may
      #   make a class a `class` body reopens;
      # - one name: a `def` of it anywhere (`def self.gets` at the top level defines it on `main`, which
      #   {BlockCallTiming.project_defines_anywhere?} does not record), and a Symbol or String literal naming it,
      #   which a macro may define it through (`def_delegators :@io, :gets`, `attr_reader :gets`,
      #   `undef_method :gets`), other than `&:gets` and the first argument of a call that only names a method
      #   (`respond_to?(:gets)`, `send(:gets)`).
      class SelfEvidence
        # The context of a reader whose `self` is `main`.
        MAIN = :main
        UNKNOWN = :unknown
        READER_NAMES = Set["gets", "readline"].freeze
        MIXINS = Set[:include, :extend, :prepend].freeze
        SENT_MIXINS = Set["include", "extend", "prepend", "using"].freeze
        SENDS = Set[:send, :__send__, :public_send].freeze
        REBINDERS = Set[
          :instance_eval, :instance_exec, :class_eval, :module_eval, :class_exec, :module_exec, :define_method,
          :define_singleton_method
        ].freeze
        REBINDER_NAMES = REBINDERS.to_set(&:to_s).freeze
        # `using` refines for the rest of the file, and `const_set` may make a class a `class` body then reopens
        # (`Object.const_set(:W, Class.new(CSV))`), whatever the receiver.
        FILE_WIDE = Set[:using, :const_set].freeze
        # The rebinders a proc argument can give a body to (`define_method(:m, blk)`).
        BODY_DEFINERS = Set[:define_method, :define_singleton_method].freeze
        CONSTRUCTORS = { Class: :new, Module: :new, Struct: :new, Data: :define }.freeze
        # Calls whose first argument names a method without putting one in place.
        NAMING_CALLS = Set[:send, :__send__, :public_send, :respond_to?, :method, :public_method].freeze
        ROOTS = Set["Object", "Kernel", "BasicObject"].freeze
        private_constant :UNKNOWN, :READER_NAMES, :MIXINS, :SENT_MIXINS, :SENDS, :REBINDERS, :REBINDER_NAMES,
                         :FILE_WIDE, :BODY_DEFINERS, :CONSTRUCTORS, :NAMING_CALLS, :ROOTS

        def initialize(root)
          @root = root
          @scan = nil
        end

        # {MAIN}, the `Prism::ClassNode` or `Prism::ModuleNode` whose body the implicit-self reader `call_node` runs
        # in, or nil: the file may give it another `self`, or it is not one of this file's readers.
        def context(call_node)
          @scan ||= Scan.new(@root)
          @scan.context(call_node)
        end

        # One walk of the file, whose answers {SelfEvidence} keeps once the walk is complete.
        class Scan
          def initialize(root)
            @contexts = {}.compare_by_identity
            @dirty = {}.compare_by_identity
            @tainted = Set.new
            visit(root, MAIN, false, false, false)
            @contexts.freeze
            @dirty.freeze
            @tainted.freeze
          end

          def context(call_node)
            return nil if @tainted.include?(call_node.name)

            context = @contexts[call_node]
            context unless @dirty.key?(context)
          end

          private

          # `context` is {MAIN}, a declaration node or {UNKNOWN}; `statement` is true for a statement of a class or
          # module body itself; `block` is true inside a block or lambda of the body; `singleton` is true inside a
          # `class << self` body.
          def visit(node, context, statement, block, singleton)
            case node
            when Prism::ClassNode, Prism::ModuleNode then visit_declaration(node, context, block, singleton)
            when Prism::SingletonClassNode then visit_singleton_class(node, context, block)
            when Prism::DefNode then visit_def(node, context, block, singleton)
            when Prism::CallNode then visit_call(node, context, statement, block, singleton)
            when Prism::BlockNode, Prism::LambdaNode then visit_children(node, context, true, singleton)
            when Prism::BlockArgumentNode then visit_block_argument(node, context, block, singleton)
            when Prism::SymbolNode, Prism::StringNode then taint(node.unescaped)
            else visit_children(node, context, block, singleton)
            end
          end

          def visit_children(node, context, block, singleton)
            node.rigor_each_child { |child| visit(child, context, false, block, singleton) }
          end

          def visit_declaration(node, context, block, singleton)
            visit(node.constant_path, context, false, block, singleton)
            superclass = node.is_a?(Prism::ClassNode) ? node.superclass : nil
            if superclass
              visit(superclass, context, false, block, singleton)
              @dirty[node] = true unless constant?(superclass)
            end
            visit_body(node.body, node)
          end

          def visit_body(body, declaration)
            if body.is_a?(Prism::StatementsNode)
              body.body.each { |statement| visit(statement, declaration, true, false, false) }
            elsif body
              visit(body, declaration, false, false, false)
            end
          end

          # `class << self` keeps the body's `self` for the methods it defines; `class << obj` gives them `obj`.
          def visit_singleton_class(node, context, block)
            visit(node.expression, context, false, block, false)
            inner = node.expression.is_a?(Prism::SelfNode) ? context : UNKNOWN
            visit(node.body, inner, false, false, true) if node.body
          end

          def visit_def(node, context, block, singleton)
            taint(node.name.to_s)
            receiver = node.receiver
            visit(receiver, context, false, block, singleton) if receiver
            inner = def_context(receiver, context, block, singleton)
            visit(node.parameters, inner, false, false, false) if node.parameters
            visit(node.body, inner, false, false, false) if node.body
          end

          def def_context(receiver, context, block, singleton)
            return UNKNOWN if block || context == UNKNOWN
            return context if receiver.is_a?(Prism::SelfNode)
            return UNKNOWN unless receiver.nil?

            context.is_a?(Prism::ModuleNode) && !singleton ? UNKNOWN : context
          end

          def visit_call(node, context, statement, block, singleton)
            classify(node, context, statement)
            @contexts[node] = context if implicit_reader?(node) && context != UNKNOWN
            visit(node.receiver, context, false, block, singleton) if node.receiver
            visit_arguments(node, context, block, singleton)
            visit_call_block(node, context, block, singleton)
          end

          def visit_arguments(node, context, block, singleton)
            arguments = node.arguments&.arguments
            return if arguments.nil?

            arguments.each_with_index do |argument, index|
              next if index.zero? && NAMING_CALLS.include?(node.name) && literal?(argument)

              visit(argument, context, false, block, singleton)
            end
          end

          def visit_call_block(node, context, block, singleton)
            call_block = node.block
            case call_block
            when Prism::BlockNode then visit(call_block, rebinder?(node) ? UNKNOWN : context, false, true, singleton)
            when Prism::BlockArgumentNode
              taint_all if rebinder?(node) && !call_block.expression.is_a?(Prism::SymbolNode)
              visit(call_block, context, false, block, singleton)
            end
          end

          # `&:gets` runs the element's own reader.
          def visit_block_argument(node, context, block, singleton)
            expression = node.expression
            return if expression.nil? || expression.is_a?(Prism::SymbolNode)

            visit(expression, context, false, block, singleton)
          end

          # A String eval may run any of the shapes this walk reads.
          def classify(node, context, statement)
            name = node.name
            arguments = node.arguments&.arguments
            if FILE_WIDE.include?(name) || (arguments && (EVALS.include?(name) || proc_body?(name, arguments)))
              taint_all
            elsif SENDS.include?(name) then taint_all if sent_mixin?(arguments)
            elsif MIXINS.include?(name) then mixin(node, context, statement)
            end
          end

          def proc_body?(name, arguments) = BODY_DEFINERS.include?(name) && arguments.size > 1

          def mixin(node, context, statement)
            receiver = node.receiver
            declaration = context.is_a?(Prism::ClassNode) || context.is_a?(Prism::ModuleNode)
            if declaration && !root?(context) && (receiver.nil? || receiver.is_a?(Prism::SelfNode))
              @dirty[context] = true unless statement && constant_arguments?(node)
            elsif declaration && !root?(context) && singleton_class_call?(receiver)
              @dirty[context] = true
            else
              taint_all
            end
          end

          def sent_mixin?(arguments)
            first = arguments&.first
            case first
            when nil then false
            when Prism::SymbolNode, Prism::StringNode then SENT_MIXINS.include?(first.unescaped)
            when Prism::SplatNode then true
            else arguments.size > 1
            end
          end

          # A rebinder, a `send` that may name one (`obj.send(:instance_eval) { … }`), or a metaclass constructor.
          def rebinder?(node)
            name = node.name
            return true if REBINDERS.include?(name)
            return sent_rebinder?(node.arguments&.arguments&.first) if SENDS.include?(name)

            receiver = node.receiver
            constructor =
              case receiver
              when Prism::ConstantReadNode then receiver.name
              when Prism::ConstantPathNode then receiver.name if receiver.parent.nil?
              end
            !constructor.nil? && CONSTRUCTORS[constructor] == name
          end

          def sent_rebinder?(first)
            literal?(first) ? REBINDER_NAMES.include?(first.unescaped) : true
          end

          def implicit_reader?(node)
            LastLine::READERS.include?(node.name) && node.block.nil? &&
              (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
          end

          def singleton_class_call?(receiver)
            receiver.is_a?(Prism::CallNode) && receiver.name == :singleton_class &&
              (receiver.receiver.nil? || receiver.receiver.is_a?(Prism::SelfNode))
          end

          def root?(declaration)
            ROOTS.include?(declaration.constant_path.slice.split("::").last)
          end

          # `extend self` adds the module's own methods, which the program's `def`s already answer for.
          def constant_arguments?(node)
            arguments = node.arguments&.arguments
            !arguments.nil? && !arguments.empty? &&
              arguments.all? { |argument| constant?(argument) || argument.is_a?(Prism::SelfNode) }
          end

          def constant?(node)
            (node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)) &&
              !Source::ConstantPath.qualified_name_or_nil(node).nil?
          end

          def literal?(node) = node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)

          def taint(name)
            @tainted << name.to_sym if READER_NAMES.include?(name)
          end

          def taint_all
            @tainted.merge(LastLine::READERS)
          end
        end
        private_constant :Scan
      end
    end
  end
end
