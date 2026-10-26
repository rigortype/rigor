# frozen_string_literal: true

require "prism"

require_relative "../analysis/dependency_recorder"
require_relative "../source/node_children"
require_relative "../type"
require_relative "guard_rebinding"
require_relative "project_method_ownership"

module Rigor
  module Inference
    # Issue #2314 — whether running a node may reach a project method that writes a given global. Both places that
    # end a global's binding at a call ask it: the statement walk past a statement call
    # (`StatementEvaluator#forget_reached_globals`), and a `case` whose global subject a `when` test may rebind
    # (`StatementEvaluator#when_test_rebinds_subject?`, issue #2211), so the two read a global alike.
    #
    # The writers come from {GlobalWriteCensus}: a `[:global_writer, name, method]` entry for each write of `name`
    # inside a method body (`method` is the `def`'s name, or the literal name a `define_method` block defines), and
    # `[:global_writer, name, nil]` for one inside a lambda or a block a call keeps to run later
    # ({StoredBlockCall}), which any call may run. A write at the top level or in a class body runs where it is
    # written, so no call reaches it.
    #
    # {.may_write?} answers true when the global has a writer and:
    #
    # - the node may run code other than Ruby core and the standard library ({GuardRebinding.may_rebind?}, the
    #   question #2260 asked of a `when` test), and
    # - some writer is anonymous, or the node's own call has a receiver no target resolves (a `Dynamic` value), or a
    #   search by method name reaches a writer ({Search}).
    #
    # The search reads method names, not receivers: from the node it follows every call, by name, into every project
    # `def` of that name on any class, transitively, and reaches a writer when it meets a call named after one. A
    # call naming its method by a computed value (`send(name)`, `eval(code)`) reaches. A name no project `def` defines
    # follows `method_missing`, `new` follows `initialize`, and an alias name (`alias`, `alias_method`, a
    # `def_delegator` alias) follows the name it stands for. A nested `def` is not read, since defining a method runs
    # nothing. Past {Search::DEF_BUDGET} bodies the search answers that it reaches. A `define_method` method that calls
    # a writer is not followed (only its own writes count), and a method core code calls back without the program
    # spelling it (`puts obj` runs `obj.to_s`) is read as the core method alone, as {GuardRebinding} reads it.
    module GlobalWriterReach
      EMPTY = Set.new.freeze

      module_function

      # The globals `scope` binds that some project method may write, other than one already `Dynamic[top]`. Each
      # bound global's census key is recorded whatever the answer, so a file that starts writing one re-checks.
      def candidates(scope)
        table = writer_table(scope)
        globals = scope.globals
        if Analysis::DependencyRecorder.active?
          globals.each_key { |name| record_writers(name) }
        end
        return EMPTY if table.empty? || globals.empty?

        table.each_key.select do |name|
          type = globals[name]
          !type.nil? && !type.is_a?(Type::Dynamic)
        end
      end

      # True when running `node`, typed in `scope`, may reach a project method that writes `name` (see the module
      # comment).
      def may_write?(node, name, scope)
        writers = writers(scope, name)
        return false if writers.empty?
        return false unless GuardRebinding.may_rebind?(node, scope)
        return true if writers.include?(nil) || unresolved_call?(node, scope)

        Search.new(scope, writers).reaches?(node)
      end

      # The method names that write `name` (nil for an anonymous writer). Records the census key, so a file that
      # starts or stops writing the global re-checks the reader. A guard on the `case` site: every `when` test built so
      # far also records the key through a statement call's {.candidates} or a callee's method edge.
      def writers(scope, name)
        record_writers(name) if Analysis::DependencyRecorder.active?
        writer_table(scope)[name] || EMPTY
      end

      def record_writers(name)
        Analysis::DependencyRecorder.read_name(:global_census, "global_writer:#{name}")
      end

      # `{ global => Set[method name or nil] }` over the project's census and the `pre_eval:` files' own.
      def writer_table(scope) = census_tables(scope).first

      # `{ alias name => Set[the method names it stands for] }`: an `alias`, an `alias_method` or a `def_delegator`
      # with a literal alias name, from the same census.
      def alias_table(scope) = census_tables(scope).last

      # The two tables above, kept for the census objects they were built from.
      def census_tables(scope)
        census = scope.discovered_global_write_census
        pre_eval = scope.environment&.project_patched_methods&.write_census
        cached = @census_tables
        return cached[2] if cached && cached[0].equal?(census) && cached[1].equal?(pre_eval)

        tables = [{}, {}]
        [census, pre_eval].each do |entries|
          entries&.each do |kind, key, value|
            case kind
            when :global_writer then (tables[0][key] ||= Set.new) << value
            when :method_alias then (tables[1][key] ||= Set.new) << value
            end
          end
        end
        tables.each { |table| table.each_value(&:freeze).freeze }
        @census_tables = [census, pre_eval, tables.freeze]
        tables
      end

      # True when `node` is a call whose receiver no target resolves: the method it runs may be any.
      def unresolved_call?(node, scope)
        return false unless node.is_a?(Prism::CallNode)

        receiver = node.receiver
        return false if receiver.nil? || receiver.is_a?(Prism::SelfNode)

        targets = ProjectMethodOwnership.targets(GuardRebinding::ScanScope.dispatch_type(receiver, scope))
        targets.nil? || targets.empty?
      rescue StandardError
        true
      end

      # `{ method name => [[class name, kind], …] }` over the project's `def` tables, kept for the tables it was
      # built from.
      def def_index(scope)
        instance = scope.discovered_def_nodes
        singleton = scope.discovered_singleton_def_nodes
        cached = @def_index
        return cached[2] if cached && cached[0].equal?(instance) && cached[1].equal?(singleton)

        index = {}
        { instance: instance, singleton: singleton }.each do |kind, table|
          table.each do |class_name, methods|
            methods.each_key { |method_name| (index[method_name] ||= []) << [class_name, kind] }
          end
        end
        @def_index = [instance, singleton, index.freeze]
        index
      end

      # A breadth-first search by method name from a node to a writer's name.
      class Search
        # The most `def` bodies one search reads before it answers that it reaches.
        DEF_BUDGET = 64
        SEND_CALLS = %i[send __send__ public_send method public_method instance_method].to_set.freeze
        CODE_CALLS = %i[eval instance_eval instance_exec class_eval class_exec module_eval module_exec].to_set.freeze

        class Reached < StandardError
        end

        def initialize(scope, writers)
          @scope = scope
          @writers = writers
          @aliases = GlobalWriterReach.alias_table(scope)
          @recording = Analysis::DependencyRecorder.active?
          @seen = Set.new
          @queue = []
          @read = 0
        end

        def reaches?(node)
          scan(node)
          until @queue.empty?
            name = @queue.shift
            definitions = definitions_of(name)
            enqueue(:method_missing) if definitions.empty?
            definitions.each { |definition| read_def(definition) }
          end
          false
        rescue Reached
          true
        end

        private

        def read_def(definition)
          @read += 1
          reached! if @read > DEF_BUDGET
          scan(definition.parameters)
          scan(definition.body)
        end

        def definitions_of(name)
          Analysis::DependencyRecorder.read_name(:defines, name) if Analysis::DependencyRecorder.active?
          targets = GlobalWriterReach.def_index(@scope)[name] || []
          targets.filter_map do |class_name, kind|
            kind == :singleton ? @scope.singleton_def_for(class_name, name) : @scope.user_def_for(class_name, name)
          end
        end

        def scan(node)
          return unless node.is_a?(Prism::Node)
          # A nested `def` defines a method; it runs nothing here, and its name is followed where it is called.
          return if node.is_a?(Prism::DefNode)

          case node
          when Prism::CallNode then scan_call(node)
          when Prism::BlockArgumentNode then scan_block_argument(node)
          when Prism::ForNode then enqueue(:each)
          end
          implicit_names(node).each { |name| enqueue(name) }
          node.rigor_each_child { |child| scan(child) }
        end

        def scan_call(node)
          enqueue(node.name)
          # `new` runs the class's `initialize`.
          enqueue(:initialize) if node.name == :new
          arguments = node.arguments&.arguments || []
          if SEND_CALLS.include?(node.name)
            name = literal_name(arguments.first)
            name ? enqueue(name) : reached!
          elsif CODE_CALLS.include?(node.name) && !(arguments.empty? && node.block.is_a?(Prism::BlockNode))
            reached!
          end
        end

        def scan_block_argument(node)
          name = literal_name(node.expression)
          enqueue(name) if name
        end

        # The methods an operator or compound write calls without spelling them.
        def implicit_names(node)
          names = []
          names << node.binary_operator if node.respond_to?(:binary_operator)
          names.push(node.read_name, node.write_name) if node.respond_to?(:read_name) && node.respond_to?(:write_name)
          names
        end

        def enqueue(name)
          return if name.nil? || @seen.include?(name)

          reached! if @writers.include?(name)
          @seen << name
          @queue << name
          # An alias runs the method it names.
          Analysis::DependencyRecorder.read_name(:global_census, "method_alias:#{name}") if @recording
          @aliases[name]&.each { |original| enqueue(original) }
        end

        def literal_name(node)
          return unless node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)

          text = node.unescaped
          text.to_sym if text.valid_encoding?
        end

        def reached!
          raise Reached
        end
      end
      private_constant :Search
    end
  end
end
