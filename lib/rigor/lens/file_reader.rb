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
      # `kind` is :module, :class or :singleton. `module_function` is :off, :on (a bare `module_function` written
      # directly in a module body covers the later direct defs) or :unknown (the reading Ruby gives and the one
      # `check`'s tables give could differ, so the later defs are omissions).
      Body = Struct.new(:current, :uncertain, :detached, :kind, :module_function)

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
        when Prism::ForNode then walk_assigning(node, node.index, nesting, singleton, in_block)
        when Prism::RescueNode then walk_assigning(node, node.reference, nesting, singleton, in_block)
        when *CONSTANT_WRITES then walk_constant(node, nesting, in_block)
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
        @bodies.push(Body.new("public", false, true, :detached, :off))
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
                         "members" => [], "module_function" => false, "visibility" => nil, "params" => nil,
                         "block" => nil, "body_return" => nil })
        walk_body(node.body, nesting + [name], singleton: false, kind: kind.to_sym)
      end

      # `class << self` directly in a class or module body opens its singleton class. Any other `class << x`, one
      # nested in another, or one at the top level (which opens `main`'s) is not modelled.
      def walk_singleton_class(node, nesting, singleton, in_block)
        if in_block || singleton || nesting.empty? || !node.expression.is_a?(Prism::SelfNode)
          omit("singleton_class", nil, node)
          return detached { walk(node.body, nesting, singleton: singleton, in_block: true) } if node.body
        end

        walk_body(node.body, nesting, singleton: true, kind: :singleton)
      end

      # A class body's statements, tracking the running visibility and `module_function`.
      def walk_body(body, nesting, singleton:, kind:)
        return if body.nil?

        @bodies.push(Body.new("public", false, false, kind, :off))
        statements = body.is_a?(Prism::StatementsNode) ? body.body : [body]
        statements.each { |child| walk_body_statement(child, nesting, singleton) }
      ensure
        @bodies.pop if body
      end

      def walk_body_statement(child, nesting, singleton)
        return bare_module_function if bare_call?(child, :module_function)
        return end_module_function if toggle_visibility?(child)
        return named_module_function(child, nesting, singleton) if named_module_function?(child)

        visibility_call(child, nesting, singleton, direct: true) if visibility_call?(child)
        @direct_statement = child
        walk(child, nesting, singleton: singleton, in_block: false)
      ensure
        @direct_statement = nil
      end

      # A bare `module_function` directly in a module body turns the mode on for the later direct defs. In a class
      # (where Ruby raises) or after the mode was left unknown, the later defs stay omissions. A second bare call
      # after a toggle also stays unknown, though Ruby turns the mode on again: the safe side.
      def bare_module_function
        body = @bodies.last
        body.module_function = body.kind == :module && body.module_function != :unknown ? :on : :unknown
      end

      # A bare `private` / `public` / `protected` ends the mode in Ruby, but `check`'s tables keep it on. The two
      # readings differ for the later defs, so they are left as omissions.
      def end_module_function
        body = @bodies.last
        body.module_function = :unknown if body.module_function == :on
      end

      def named_module_function?(child)
        child.is_a?(Prism::CallNode) && child.receiver.nil? && child.name == :module_function && child.arguments
      end

      # A named `module_function` (`module_function :a`, `module_function %i[a]`, `module_function def a`) is an
      # omission: `check`'s singleton table reads it differently from Ruby (a def nested in the body, a reopened
      # module, a redefinition after the call, a wrapped def). The instance methods it names turn private in Ruby,
      # so their visibility reads unknown, and the omission makes each named member contested.
      def named_module_function(node, nesting, singleton)
        owner = nesting.last
        node.arguments.arguments.each do |argument|
          # The copy replaces any `def self.x` already there, so the singleton side is contested as well.
          names = argument.is_a?(Prism::DefNode) ? [argument.name.to_s] : argument_names(argument)
          if names.nil?
            [false, true].each do |side|
              unknown_visibility(owner, scope_name(side), default_too: false)
              omit("module_function", nil, argument, owner: owner, singleton: side, any_member: true)
            end
          else
            names.product([false, true]).each do |name, side|
              name_visibility(owner, scope_name(side), name, nil)
              omit("module_function", name, argument.is_a?(Prism::DefNode) ? argument : node, owner: owner,
                                                                                              singleton: side)
            end
          end
          if argument.is_a?(Prism::DefNode) && argument.body
            detached { walk(argument.body, nesting, singleton: singleton, in_block: true) }
          end
        end
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
          return unplaced_module_function if bare_call?(node, :module_function)

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

      # `default_too: false` leaves the body's running default alone: `module_function(*NAMES)` changes only the
      # members it names, while `private *NAMES` is read as making the default unknown too, the safe side.
      def unknown_visibility(owner, scope, default_too: true)
        @sites.each do |site|
          data = site.data
          next unless data["owner"] == owner

          data["visibility"] = nil if data["scope"] == scope
          data["singleton_visibility"] = nil if scope == "singleton" && data["module_function"]
        end
        mark_uncertain if default_too
      end

      # `private :x` changes the visibility of the members already defined under that name in this file.
      def name_visibility(owner, scope, name, visibility)
        @sites.each do |site|
          data = site.data
          next unless data["owner"] == owner && data["members"].include?(name)

          if data["scope"] == scope
            data["visibility"] = data["members"] == [name] ? visibility : nil
          elsif scope == "singleton" && data["module_function"]
            # `private_class_method :x` reaches a module function's singleton copy.
            data["singleton_visibility"] = visibility
          end
        end
      end

      # `a, B = …`: each constant target is an omission. The targets are walked too, since an index or call target
      # (`a[expr], b = …`) or a constant path's parent can hold a declaration; the value is walked last.
      def walk_multi_write(node, nesting, singleton, in_block)
        omit_constant_targets(node, nesting)
        targets_of(node).each { |target| walk(target, nesting, singleton: singleton, in_block: in_block) }
        walk(node.value, nesting, singleton: singleton, in_block: in_block)
      end

      # A `for A in …` index or a `rescue => E` reference assigns the constants it names, like a multiple
      # assignment does.
      def walk_assigning(node, target, nesting, singleton, in_block)
        omit_constant_targets(target, nesting) if target
        walk_children(node, nesting, singleton, in_block)
      end

      def omit_constant_targets(target, nesting)
        constant_targets(target).each do |constant|
          omit("constant", qualify(nesting, constant) || constant.slice, constant)
        end
      end

      # The constants a target assigns: itself when it is one, and those inside a nested `(a, B)` group or a
      # `*Rest` splat. A group's rest slot is a `SplatNode` (`a, *B = …`, or a bare `*`) or an `ImplicitRestNode`
      # (the trailing comma of `a, = …`), which names nothing.
      def constant_targets(target)
        case target
        when Prism::ConstantTargetNode, Prism::ConstantPathTargetNode then [target]
        when Prism::MultiWriteNode, Prism::MultiTargetNode then targets_of(target).flat_map { |t| constant_targets(t) }
        when Prism::SplatNode then target.expression ? constant_targets(target.expression) : []
        else []
        end
      end

      def targets_of(node)
        node.lefts + [node.rest].compact + node.rights
      end

      def walk_constant(node, nesting, in_block)
        target = node.respond_to?(:target) ? node.target : node
        name = node.respond_to?(:target) ? qualify(nesting, node.target) : qualify_name(nesting, node.name.to_s)
        builder = data_or_struct(node.value)
        fields = builder && builder_fields(node.value, builder)
        if fields && name && !in_block && plain_write?(node)
          return read_builder_class(node, name, nesting, builder, fields)
        end

        kind = { data: "data_class", struct: "struct_class" }.fetch(builder, "constant")
        omit(kind, name || target.slice, node)
        walk(node.value, nesting, singleton: false, in_block: true)
      end

      # `Foo = Data.define(:a, :b) do … end` and `Foo = Struct.new(:a, keyword_init: true) do … end`: a class site
      # with `builder` set, an attribute site per field (a reader for `Data`, an accessor for `Struct`), and the block
      # read as the class body, which Ruby `class_eval`s on the new class. `check`'s discovery keys the block's defs
      # and the fields under the same constant name.
      def read_builder_class(node, name, nesting, builder, fields)
        add_site(node, { "kind" => "class", "name" => name, "owner" => nil, "scope" => nil, "attribute" => nil,
                         "members" => [], "module_function" => false, "builder" => builder.to_s,
                         "visibility" => nil, "params" => nil, "block" => nil, "body_return" => nil })
        attribute = builder == :data ? "reader" : "accessor"
        fields.each do |field, field_node|
          add_site(field_node, { "kind" => "attribute", "name" => field, "owner" => name, "scope" => "instance",
                                 "attribute" => attribute, "members" => attribute_members(field, attribute),
                                 "module_function" => false, "visibility" => "public", "params" => nil,
                                 "block" => nil, "body_return" => nil })
        end
        block = node.value.block
        walk_body(block.body, nesting + [name], singleton: false, kind: :class) if block&.body
      end

      def plain_write?(node)
        node.is_a?(Prism::ConstantWriteNode) || node.is_a?(Prism::ConstantPathWriteNode)
      end

      # `[[name, node], …]` for a builder call whose fields are all literal, or nil. `Struct.new` may end with
      # `keyword_init:`; a leading string (`Struct.new("Name", …)`, which defines `Struct::Name`) or a `&block`
      # argument is not modelled.
      def builder_fields(call, builder)
        return nil if call.block.is_a?(Prism::BlockArgumentNode)

        arguments = call.arguments&.arguments || []
        arguments = arguments[0...-1] if builder == :struct && arguments.last.is_a?(Prism::KeywordHashNode)
        return nil if builder == :struct && arguments.first.is_a?(Prism::StringNode)
        unless arguments.all? { |argument| argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode) }
          return nil
        end

        arguments.map { |argument| [argument.unescaped, argument] }
      end

      # A bare `module_function` the walk cannot place in the body's statement list (under an `if`, say) leaves the
      # mode unknown for the body's later defs.
      def unplaced_module_function
        body = @bodies.last
        body.module_function = :unknown if body && !body.detached
      end

      def read_def(node, nesting, singleton, in_block, module_function: false)
        scope = def_scope(node, nesting, singleton)
        module_function ||= module_function_state(node, singleton)
        if in_block || scope.nil?
          omit("method", node.name.to_s, node)
        elsif module_function.nil?
          omit("module_function", node.name.to_s, node, owner: nesting.last, singleton: singleton)
        else
          add_site(node, method_site(node, nesting, scope, module_function))
        end
        # A declaration inside a method body runs only when the method does: not modelled.
        detached { walk(node.body, nesting, singleton: singleton, in_block: true) } if node.body
      end

      def method_site(node, nesting, scope, module_function)
        owner = nesting.last || "Object"
        params, block, = Parameters.read(node.parameters, yields: Parameters.yields?(node.body))
        shape_params, shape_block = Parameters.shape(params, block)
        returns = body_return(node, owner, scope)
        data = { "kind" => "method", "name" => node.name.to_s, "owner" => owner, "scope" => scope.to_s,
                 "attribute" => nil, "members" => [node.name.to_s], "module_function" => module_function,
                 "visibility" => module_function ? "private" : visibility(node, nesting, scope),
                 "params" => shape_params, "block" => shape_block, "body_return" => returns }
        return data unless module_function

        # Internal to the member pass: the singleton copy is public until `private_class_method` says otherwise,
        # and its body runs with the module as `self`. The instance-scope typing read `self` as an instance of the
        # owner, so a return that may depend on `self` is not the copy's.
        copy = self_dependent?(node.body, returns, owner) ? Slot.unavailable("not_computed") : returns
        data.merge("singleton_visibility" => "public", "singleton_body_return" => copy)
      end

      # Whether the instance-scope return may differ from the singleton copy's: the body reads `self`, instance or
      # class state, or `super` (nested defs excluded, blocks included, which over-declines safely), or the return
      # names the owner's type, which is where a `self` that flowed through `itself`, `tap` or another module
      # function shows up.
      def self_dependent?(body, returns, owner)
        instance_state?(body) || names_owner?(returns, owner)
      end

      def instance_state?(node)
        return false if node.nil?
        if node.is_a?(Prism::SelfNode) || node.is_a?(Prism::SuperNode) || node.is_a?(Prism::ForwardingSuperNode)
          return true
        end
        return true if node.type.to_s.start_with?("instance_variable_", "class_variable_")
        return false if node.is_a?(Prism::DefNode)

        node.compact_child_nodes.any? { |child| instance_state?(child) }
      end

      # Whether a spelled type mentions the owner, by its qualified name or its last segment. A heuristic, not a proof:
      # a self-dependent body whose instance-scope type folds to something that names no owner slips through.
      def names_owner?(slot, owner)
        type = slot["type"]
        return false unless type

        [owner, owner.split("::").last].uniq.any? do |name|
          type.match?(/(?<![\w:])(?:::)?#{Regexp.escape(name)}(?!\w)/)
        end
      end

      # Whether a receiverless instance `def` is a module function: true when the body's mode is on and the def is
      # one of the body's direct statements, nil when the mode is on or unknown but Rigor cannot say (a def nested
      # in the body, or after the mode became unknown), false otherwise.
      def module_function_state(node, singleton)
        body = @bodies.last
        return false if body.nil? || body.detached || singleton || node.receiver
        return false if body.module_function == :off

        body.module_function == :on && node.equal?(@direct_statement) ? true : nil
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
                           "module_function" => false,
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
        @sites << Site.new(data: { "key" => key, "builder" => nil }.merge(data).merge(tail), node: node,
                           contract_comments: anchor.contract_comments)
      end

      # `owner` / `singleton` name the member the declaration would define, when Rigor can tell. `any_member` keeps
      # them with a null name: the declaration may define any member of that owner and scope.
      def omit(kind, name, node, owner: nil, singleton: false, any_member: false)
        member = owner && (name || any_member)
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
