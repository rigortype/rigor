# frozen_string_literal: true

require "prism"

require_relative "anchor"
require_relative "slot"
require_relative "parameters"
require_relative "../inference/def_return_typer"
require_relative "../inference/origin_lookup"
require_relative "../sig_gen/type_elaborator"

module Rigor
  module Lens
    # Reads one analysed file into sites and omissions (docs/internal-spec/lens.md § Files, § Sites). Runs inside
    # the check run, on the seeded scope index the check rules read, so a body return is the type `check` gives
    # that body.
    class FileReader
      # A site plus what the member pass needs from it: the declaration node and the contract comments above it.
      Site = Data.define(:data, :node, :contract_comments)
      Result = Data.define(:sites, :omissions)

      ATTRIBUTE_CALLS = { attr_reader: "reader", attr_writer: "writer", attr_accessor: "accessor" }.freeze
      OMITTED_CALLS = {
        alias_method: "alias", define_method: "define_method", module_function: "module_function",
        refine: "refine"
      }.freeze
      BLOCK_NODES = [Prism::BlockNode, Prism::LambdaNode].freeze

      # @param path — the file, relative to the project root
      # @param spell — callable `(type, owner) -> String` spelling a type as sig-gen writes it
      def initialize(path:, parse_result:, index:, spell:)
        @path = path
        @root = parse_result.value
        @index = index
        @spell = spell
        @anchor = Anchor.new(parse_result.source.source, parse_result.comments)
        @visibilities, contested = Inference::ScopeIndexer.build_method_visibility_tables(@root)
        @contested_visibility = contested
        @sites = []
        @omissions = []
      end

      def read
        walk(@root, [], singleton: false, in_block: false)
        Result.new(sites: @sites, omissions: @omissions)
      end

      private

      def walk(node, nesting, singleton:, in_block:)
        case node
        when Prism::ClassNode, Prism::ModuleNode then walk_namespace(node, nesting, in_block)
        when Prism::SingletonClassNode then walk_singleton_class(node, nesting, in_block)
        when Prism::DefNode then read_def(node, nesting, singleton, in_block)
        when Prism::StatementsNode then walk_statements(node, nesting, singleton, in_block)
        when Prism::CallNode then walk_call(node, nesting, singleton, in_block)
        when Prism::AliasMethodNode
          omit("alias", node.new_name.slice.delete_prefix(":"), node, owner: nesting.last, scope: singleton)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
             Prism::ConstantPathOrWriteNode
          walk_constant(node, nesting, in_block)
        else walk_children(node, nesting, singleton, in_block)
        end
      end

      def walk_children(node, nesting, singleton, in_block)
        node.compact_child_nodes.each do |child|
          walk(child, nesting, singleton: singleton, in_block: in_block || BLOCK_NODES.include?(child.class))
        end
      end

      def walk_namespace(node, nesting, in_block)
        kind = node.is_a?(Prism::ClassNode) ? "class" : "module"
        name = qualify(nesting, node.constant_path.slice)
        return omit(kind, name, node) if in_block

        add_site(node, { "kind" => kind, "name" => name, "owner" => nil, "scope" => nil, "attribute" => nil,
                         "members" => [], "visibility" => nil, "params" => nil, "block" => nil,
                         "body_return" => nil })
        walk(node.body, nesting + [name], singleton: false, in_block: false) if node.body
      end

      def walk_singleton_class(node, nesting, in_block)
        return omit("singleton_class", nil, node) if in_block || !node.expression.is_a?(Prism::SelfNode)

        walk(node.body, nesting, singleton: true, in_block: false) if node.body
      end

      # A bare `module_function` makes every later `def` of the body a method on both sides: one site, two
      # members, which revision 1 does not model.
      def walk_statements(node, nesting, singleton, in_block)
        module_function_on = false
        node.body.each do |child|
          if module_function_on && child.is_a?(Prism::DefNode)
            omit("module_function", child.name.to_s, child, owner: nesting.last, scope: singleton)
            next
          end
          module_function_on = true if bare_call?(child, :module_function)
          walk(child, nesting, singleton: singleton, in_block: in_block)
        end
      end

      def walk_call(node, nesting, singleton, in_block)
        if node.receiver.nil? && ATTRIBUTE_CALLS.key?(node.name)
          read_attribute(node, nesting, singleton, in_block)
        elsif node.receiver.nil? && OMITTED_CALLS.key?(node.name)
          return if bare_call?(node, :module_function)

          omit(OMITTED_CALLS.fetch(node.name), first_argument_name(node), node,
               owner: node.name == :refine ? nil : nesting.last, scope: singleton)
          walk_children(node, nesting, singleton, true) unless node.name == :refine
        else
          walk_children(node, nesting, singleton, in_block)
        end
      end

      def walk_constant(node, nesting, _in_block)
        name = node.respond_to?(:target) ? node.target.slice : node.name.to_s
        kind = case data_or_struct(node.value)
               when :data then "data_class"
               when :struct then "struct_class"
               else "constant"
               end
        omit(kind, qualify(nesting, name), node)
        walk(node.value, nesting, singleton: false, in_block: true)
      end

      def read_def(node, nesting, singleton, in_block)
        owner = nesting.last || "Object"
        scope = def_scope(node, singleton)
        return omit("method", node.name.to_s, node) if in_block || scope.nil?

        data = { "kind" => "method", "name" => node.name.to_s, "owner" => owner, "scope" => scope.to_s,
                 "attribute" => nil, "members" => [node.name.to_s],
                 "visibility" => visibility(nesting, owner, scope, node.name) }
        params, block, = Parameters.read(node.parameters, yields: Parameters.yields?(node.body))
        shape_params, shape_block = Parameters.shape(params, block)
        data.merge!("params" => shape_params, "block" => shape_block, "body_return" => body_return(node, owner, scope))
        add_site(node, data)
      end

      def read_attribute(node, nesting, singleton, in_block)
        arguments = node.arguments&.arguments || []
        names = arguments.map { |arg| arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode) ? arg.unescaped : nil }
        if in_block || nesting.empty? || names.empty? || names.include?(nil)
          return omit("attribute", names.compact.first, node)
        end

        owner = nesting.last
        names.each_with_index do |name, ordinal|
          scope = singleton ? :singleton : :instance
          attribute = ATTRIBUTE_CALLS.fetch(node.name)
          add_site(node, { "kind" => "attribute", "name" => name, "owner" => owner, "scope" => scope.to_s,
                           "attribute" => attribute, "members" => attribute_members(name, attribute),
                           "visibility" => visibility(nesting, owner, scope, name.to_sym),
                           "params" => nil, "block" => nil, "body_return" => nil }, ordinal: ordinal)
        end
      end

      def add_site(node, data, ordinal: 0)
        location = node.location
        anchor = @anchor.for_span(location.start_offset, location.end_offset, location.start_line,
                                  location.end_line)
        key = "#{@path}:#{location.start_offset}-#{location.end_offset}:#{ordinal}"
        head = { "key" => key }
        tail = { "ordinal" => ordinal, "span" => Lens.span(location),
                 "contract_span" => Lens.contract_span(anchor.contract_comments), "anchor" => anchor.token,
                 "contract" => nil }
        @sites << Site.new(data: head.merge(data).merge(tail), node: node,
                           contract_comments: anchor.contract_comments)
      end

      # `owner` / `scope` name the member the declaration would define, when Rigor can tell.
      def omit(kind, name, node, owner: nil, scope: nil)
        member = owner && name
        @omissions << { "kind" => kind, "owner" => member ? owner : nil,
                        "scope" => if member
                                     scope ? "singleton" : "instance"
                                   end, "name" => name,
                        "span" => Lens.span(node.location), "reason" => "unsupported_kind" }
        nil
      end

      def attribute_members(name, attribute)
        case attribute
        when "reader" then [name]
        when "writer" then ["#{name}="]
        else [name, "#{name}="]
        end
      end

      # Instance-side visibility as the check path's per-file table records it. Rigor does not resolve a
      # singleton method's visibility, and a slot the table marks contested has no single answer: both read nil.
      def visibility(nesting, owner, scope, name)
        return "private" if nesting.empty? && scope == :instance
        return nil if scope == :singleton

        value = @visibilities.dig(owner, name)
        return nil if @contested_visibility.include?([owner, name])

        (value || :public).to_s
      end

      def def_scope(node, singleton)
        return (singleton ? :singleton : :instance) if node.receiver.nil?

        node.receiver.is_a?(Prism::SelfNode) ? :singleton : nil
      end

      # The body's return under the seeded index, with its parameters as declared (§ Sites).
      def body_return(node, owner, scope)
        return Slot.typed("void", "inferred") if scope == :instance && node.name == :initialize
        return Slot.typed("nil", "inferred") if node.body.nil?

        type = Inference::DefReturnTyper.call(node, @index)
        return Slot.unavailable("not_computed") if type.nil?
        return Slot.dynamic("inferred", return_cause(node)) if type.is_a?(Type::Dynamic)

        spelled = @spell.call(type, owner)
        spelled == "untyped" ? Slot.dynamic("inferred", return_cause(node)) : Slot.typed(spelled, "inferred")
      rescue StandardError
        Slot.unavailable("not_computed")
      end

      def return_cause(node)
        last = Inference::DefReturnTyper.body_last_expression(node.body)
        scope = last && (@index[last] || @index[node.body])
        scope && Inference::OriginLookup.origin_for(scope, last)
      end

      def qualify(nesting, slice)
        return slice.delete_prefix("::") if slice.start_with?("::") || nesting.empty?

        "#{nesting.last}::#{slice}"
      end

      def bare_call?(node, name)
        node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == name && node.arguments.nil? &&
          node.block.nil?
      end

      def first_argument_name(node)
        argument = node.arguments&.arguments&.first
        case argument
        when Prism::SymbolNode, Prism::StringNode then argument.unescaped
        when Prism::DefNode then argument.name.to_s
        end
      end

      def data_or_struct(value)
        return nil unless value.is_a?(Prism::CallNode) && value.receiver

        receiver = value.receiver.slice.delete_prefix("::")
        return :data if receiver == "Data" && value.name == :define
        return :struct if receiver == "Struct" && value.name == :new

        nil
      end
    end
  end
end
