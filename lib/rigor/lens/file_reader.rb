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
    # that body. Every declaration the walk meets is either a site or an omission; none is dropped.
    class FileReader # rubocop:disable Metrics/ClassLength
      # A site plus what the member pass needs from it: the declaration node and the contract comments above it.
      Site = Data.define(:data, :node, :contract_comments)
      Result = Data.define(:sites, :omissions, :digest)
      # The running visibility of one class body: Ruby's default for its later `def`s, and whether a toggle the
      # walk cannot place (under an `if`, a `begin`, a block) leaves that default unknown.
      # A `detached` body stands for code that is not the class body (a block, a method body, a superclass
      # expression, an omitted class): its toggles and named calls stay local and change no site.
      Body = Struct.new(:current, :uncertain, :detached)

      ATTRIBUTE_CALLS = { attr_reader: "reader", attr_writer: "writer", attr_accessor: "accessor" }.freeze
      OMITTED_CALLS = {
        alias_method: "alias", define_method: "define_method", module_function: "module_function",
        refine: "refine"
      }.freeze
      VISIBILITY_CALLS = %i[private protected public].freeze
      CLASS_VISIBILITY_CALLS = { private_class_method: "private", public_class_method: "public" }.freeze
      BLOCK_NODES = [Prism::BlockNode, Prism::LambdaNode].freeze
      CONSTANT_WRITES = [
        Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
        Prism::ConstantPathOrWriteNode, Prism::ConstantAndWriteNode, Prism::ConstantPathAndWriteNode,
        Prism::ConstantOperatorWriteNode, Prism::ConstantPathOperatorWriteNode
      ].freeze

      # @param path — the file, relative to the project root
      # @param spell — callable `(type, owner) -> String` spelling a type as sig-gen writes it
      def initialize(path:, parse_result:, index:, spell:)
        @path = path
        @root = parse_result.value
        @source = parse_result.source.source
        @index = index
        @spell = spell
        @anchor = Anchor.new(@source, parse_result.comments)
        @bodies = []
        @node_visibility = {}.compare_by_identity
        @sites = []
        @omissions = []
      end

      def read
        walk(@root, [], singleton: false, in_block: false)
        Result.new(sites: @sites, omissions: @omissions, digest: Lens.digest(@source.b))
      end

      private

      def walk(node, nesting, singleton:, in_block:)
        case node
        when Prism::ClassNode, Prism::ModuleNode then walk_namespace(node, nesting, in_block)
        when Prism::SingletonClassNode then walk_singleton_class(node, nesting, singleton, in_block)
        when Prism::DefNode then read_def(node, nesting, singleton, in_block)
        when Prism::CallNode then walk_call(node, nesting, singleton, in_block)
        when Prism::AliasMethodNode
          omit("alias", node.new_name.slice.delete_prefix(":"), node, owner: nesting.last, singleton: singleton)
        when Prism::MultiWriteNode then walk_multi_write(node, nesting, singleton, in_block)
        when *CONSTANT_WRITES then walk_constant(node, nesting)
        else walk_children(node, nesting, singleton, in_block)
        end
      end

      def walk_children(node, nesting, singleton, in_block)
        node.compact_child_nodes.each do |child|
          if BLOCK_NODES.include?(child.class)
            detached { walk(child, nesting, singleton: singleton, in_block: true) }
          else
            walk(child, nesting, singleton: singleton, in_block: in_block)
          end
        end
      end

      def detached
        @bodies.push(Body.new("public", false, true))
        yield
      ensure
        @bodies.pop
      end

      def walk_namespace(node, nesting, in_block)
        kind = node.is_a?(Prism::ClassNode) ? "class" : "module"
        name = qualify(nesting, node.constant_path)
        if node.is_a?(Prism::ClassNode) && node.superclass
          detached { walk(node.superclass, nesting, singleton: false, in_block: true) }
        end
        if in_block || name.nil?
          omit(kind, name || node.constant_path.slice, node)
          detached { walk(node.body, nesting, singleton: false, in_block: true) } if node.body
          return
        end

        add_site(node, { "kind" => kind, "name" => name, "owner" => nil, "scope" => nil, "attribute" => nil,
                         "members" => [], "visibility" => nil, "params" => nil, "block" => nil,
                         "body_return" => nil })
        walk_body(node.body, nesting + [name], singleton: false)
      end

      # `class << self` directly in a class or module body opens its singleton class. Any other `class << x`, one
      # nested in another, or one at the top level (which opens `main`'s) is not modelled.
      def walk_singleton_class(node, nesting, singleton, in_block)
        if in_block || singleton || nesting.empty? || !node.expression.is_a?(Prism::SelfNode)
          omit("singleton_class", nil, node)
          return detached { walk(node.body, nesting, singleton: singleton, in_block: true) } if node.body
        end

        walk_body(node.body, nesting, singleton: true)
      end

      # A class body's statements, tracking the running visibility and `module_function`. A bare `module_function`
      # makes every later `def` of the body a method on both sides: one site, two members, which revision 1 does
      # not model.
      def walk_body(body, nesting, singleton:)
        return if body.nil?

        @bodies.push(Body.new("public", false, false))
        statements = body.is_a?(Prism::StatementsNode) ? body.body : [body]
        module_function_on = false
        statements.each do |child|
          if module_function_on && child.is_a?(Prism::DefNode)
            omit("module_function", child.name.to_s, child, owner: nesting.last, singleton: singleton)
            next
          end
          module_function_on = true if bare_call?(child, :module_function)
          next if toggle_visibility?(child)

          visibility_call(child, nesting, singleton, direct: true) if visibility_call?(child)
          walk(child, nesting, singleton: singleton, in_block: false)
        end
      ensure
        @bodies.pop if body
      end

      # A bare `private` / `protected` / `public` written directly in the body sets the default for later defs.
      def toggle_visibility?(child)
        return false unless VISIBILITY_CALLS.any? { |name| bare_call?(child, name) }

        @bodies.last.current = child.name.to_s
        @bodies.last.uncertain = false
        true
      end

      def walk_call(node, nesting, singleton, in_block)
        if node.receiver.nil? && ATTRIBUTE_CALLS.key?(node.name)
          read_attribute(node, nesting, singleton, in_block)
        elsif node.receiver.nil? && OMITTED_CALLS.key?(node.name)
          return if bare_call?(node, :module_function)

          omit(OMITTED_CALLS.fetch(node.name), first_argument_name(node), node,
               owner: node.name == :refine ? nil : nesting.last, singleton: singleton)
          walk_children(node, nesting, singleton, true) unless node.name == :refine
        else
          @visited_visibility_calls ||= {}.compare_by_identity
          if visibility_call?(node) && !@visited_visibility_calls.key?(node)
            visibility_call(node, nesting, singleton, direct: false)
          end
          walk_children(node, nesting, singleton, in_block)
        end
      end

      def visibility_call?(node)
        node.is_a?(Prism::CallNode) && node.receiver.nil? &&
          (VISIBILITY_CALLS.include?(node.name) || CLASS_VISIBILITY_CALLS.key?(node.name))
      end

      # `private :x`, `private %i[x]`, `private def x`, `private attr_reader :x`, `private_class_method :x`, and a
      # bare toggle the walk cannot place in the body's statement list. A named call changes members only when it
      # is written directly in the body (`direct`); one under an `if`, a block or a method body runs at a time
      # Rigor does not know, so the members it names read unknown.
      def visibility_call(node, nesting, singleton, direct:)
        @visited_visibility_calls ||= {}.compare_by_identity
        @visited_visibility_calls[node] = true
        direct &&= !@bodies.last&.detached
        if VISIBILITY_CALLS.include?(node.name)
          return mark_uncertain if node.arguments.nil?

          apply_visibility(node, node.name.to_s, nesting.last, singleton, direct)
        else
          apply_visibility(node, CLASS_VISIBILITY_CALLS.fetch(node.name), nesting.last, true, direct)
        end
      end

      def mark_uncertain
        @bodies.last&.uncertain = true
      end

      def apply_visibility(node, visibility, owner, singleton, direct)
        scope = singleton ? "singleton" : "instance"
        node.arguments.arguments.each do |argument|
          names = argument_names(argument)
          if wrapped_declaration?(argument, singleton)
            @node_visibility[argument] = visibility
          elsif argument.is_a?(Prism::DefNode)
            # `private def self.x`: Ruby looks `x` up among instance methods and rejects it, so the result is unknown.
            @node_visibility[argument] = nil
          elsif names.nil?
            # `private *NAMES`: which members change is unknown.
            unknown_visibility(owner, scope)
          else
            names.each { |name| name_visibility(owner, scope, name, direct ? visibility : nil) }
          end
        end
      end

      # A `def` or `attr_*` the visibility call wraps. `private def self.x` is not one: `private` looks the
      # name up among instance methods.
      def wrapped_declaration?(argument, singleton)
        case argument
        when Prism::DefNode then argument.receiver.nil? || singleton
        when Prism::CallNode then argument.receiver.nil? && ATTRIBUTE_CALLS.key?(argument.name)
        else false
        end
      end

      # The names a visibility call's argument lists, or nil when it is not a literal list of them.
      def argument_names(argument)
        case argument
        when Prism::SymbolNode, Prism::StringNode then [argument.unescaped]
        when Prism::ArrayNode
          names = argument.elements.map { |element| argument_names(element)&.first }
          names.include?(nil) ? nil : names
        end
      end

      def unknown_visibility(owner, scope)
        @sites.each do |site|
          site.data["visibility"] = nil if site.data["owner"] == owner && site.data["scope"] == scope
        end
        mark_uncertain
      end

      # `private :x` changes the visibility of the members already defined under that name in this file.
      def name_visibility(owner, scope, name, visibility)
        @sites.each do |site|
          data = site.data
          next unless data["owner"] == owner && data["scope"] == scope && data["members"].include?(name)

          data["visibility"] = data["members"] == [name] ? visibility : nil
        end
      end

      def walk_multi_write(node, nesting, singleton, in_block)
        constant_targets(node).each do |target|
          omit("constant", qualify(nesting, target) || target.slice, target)
        end
        walk(node.value, nesting, singleton: singleton, in_block: in_block)
      end

      # The constant targets of a multiple assignment, through nested `(a, B), c` groups and a `*Rest` splat. The
      # rest slot is a `SplatNode` (`a, *B = …`, or a bare `*`) or an `ImplicitRestNode` (the trailing comma of
      # `a, = …`), which names nothing.
      def constant_targets(node)
        rest = node.rest.is_a?(Prism::SplatNode) ? [node.rest.expression].compact : []
        (node.lefts + rest + node.rights).flat_map do |target|
          case target
          when Prism::ConstantTargetNode, Prism::ConstantPathTargetNode then [target]
          when Prism::MultiTargetNode then constant_targets(target)
          else []
          end
        end
      end

      def walk_constant(node, nesting)
        target = node.respond_to?(:target) ? node.target : node
        name = node.respond_to?(:target) ? qualify(nesting, node.target) : qualify_name(nesting, node.name.to_s)
        kind = case data_or_struct(node.value)
               when :data then "data_class"
               when :struct then "struct_class"
               else "constant"
               end
        omit(kind, name || target.slice, node)
        walk(node.value, nesting, singleton: false, in_block: true)
      end

      def read_def(node, nesting, singleton, in_block)
        scope = def_scope(node, nesting, singleton)
        if in_block || scope.nil?
          omit("method", node.name.to_s, node)
        else
          owner = nesting.last || "Object"
          data = { "kind" => "method", "name" => node.name.to_s, "owner" => owner, "scope" => scope.to_s,
                   "attribute" => nil, "members" => [node.name.to_s],
                   "visibility" => visibility(node, nesting, scope) }
          params, block, = Parameters.read(node.parameters, yields: Parameters.yields?(node.body))
          shape_params, shape_block = Parameters.shape(params, block)
          data.merge!("params" => shape_params, "block" => shape_block,
                      "body_return" => body_return(node, owner, scope))
          add_site(node, data)
        end
        # A declaration inside a method body runs only when the method does: not modelled.
        detached { walk(node.body, nesting, singleton: singleton, in_block: true) } if node.body
      end

      def read_attribute(node, nesting, singleton, in_block)
        arguments = node.arguments&.arguments || []
        names = arguments.map { |arg| arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode) ? arg.unescaped : nil }
        if in_block || nesting.empty? || names.empty? || names.include?(nil)
          return omit("attribute", names.compact.first, node)
        end

        owner = nesting.last
        scope = singleton ? :singleton : :instance
        attribute = ATTRIBUTE_CALLS.fetch(node.name)
        names.each_with_index do |name, ordinal|
          add_site(node, { "kind" => "attribute", "name" => name, "owner" => owner, "scope" => scope.to_s,
                           "attribute" => attribute, "members" => attribute_members(name, attribute),
                           "visibility" => visibility(node, nesting, scope),
                           "params" => nil, "block" => nil, "body_return" => nil }, ordinal: ordinal)
        end
      end

      def add_site(node, data, ordinal: 0)
        location = node.location
        anchor = @anchor.for_span(location.start_offset, location.end_offset, location.start_line,
                                  location.end_line)
        key = "#{@path}:#{location.start_offset}-#{location.end_offset}:#{ordinal}"
        tail = { "ordinal" => ordinal, "span" => Lens.span(location),
                 "contract_span" => Lens.contract_span(anchor.contract_comments), "anchor" => anchor.token,
                 "contract" => nil }
        @sites << Site.new(data: { "key" => key }.merge(data).merge(tail), node: node,
                           contract_comments: anchor.contract_comments)
      end

      # `owner` / `singleton` name the member the declaration would define, when Rigor can tell.
      def omit(kind, name, node, owner: nil, singleton: false)
        member = owner && name
        @omissions << { "kind" => kind, "owner" => member ? owner : nil,
                        "scope" => member ? scope_name(singleton) : nil, "name" => name,
                        "span" => Lens.span(node.location), "reason" => "unsupported_kind" }
        nil
      end

      def scope_name(singleton)
        singleton ? "singleton" : "instance"
      end

      def attribute_members(name, attribute)
        case attribute
        when "reader" then [name]
        when "writer" then ["#{name}="]
        else [name, "#{name}="]
        end
      end

      # The member's visibility as Ruby gives it: a `private def` / `private attr_reader` wrapper, else the running
      # default of the body (unknown after a toggle the walk could not place). A class body's toggles do not reach
      # a `def self.x`. A later `private :x` revises it ({#name_visibility}). A top-level `def` is private.
      def visibility(node, nesting, scope)
        return "private" if nesting.empty?
        return @node_visibility[node] if @node_visibility.key?(node)
        return "public" if scope == :singleton && node.is_a?(Prism::DefNode) && node.receiver

        body = @bodies.last
        return nil if body.nil? || body.uncertain

        body.current
      end

      # `def x` in a class body is an instance method, in `class << self` a singleton one; `def self.x` is a
      # singleton method of a class body. A `def self.x` inside `class << self`, a top-level `def self.x`, and any
      # other receiver define methods revision 1 does not model.
      def def_scope(node, nesting, singleton)
        return (singleton ? :singleton : :instance) if node.receiver.nil?
        return nil unless node.receiver.is_a?(Prism::SelfNode)
        return nil if singleton || nesting.empty?

        :singleton
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

      # The qualified name a constant path declares under `nesting`, or nil when it is not a plain constant path
      # (`self::Foo`, `expr::Foo`).
      def qualify(nesting, path)
        case path
        when Prism::ConstantReadNode, Prism::ConstantTargetNode then qualify_name(nesting, path.name.to_s)
        when Prism::ConstantPathNode, Prism::ConstantPathTargetNode
          return path.name.to_s if path.parent.nil?

          parent = qualify(nesting, path.parent)
          parent && "#{parent}::#{path.name}"
        end
      end

      def qualify_name(nesting, name)
        nesting.empty? ? name : "#{nesting.last}::#{name}"
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
