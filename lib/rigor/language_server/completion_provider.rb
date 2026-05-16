# frozen_string_literal: true

require "prism"

require_relative "uri"
require_relative "../environment"
require_relative "../reflection"
require_relative "../scope"
require_relative "../source/node_locator"
require_relative "../inference/scope_indexer"
require_relative "../type/nominal"
require_relative "../type/singleton"
require_relative "../type/constant"
require_relative "../type/union"
require_relative "../type/intersection"
require_relative "../type/refined"
require_relative "../type/difference"
require_relative "../type/tuple"
require_relative "../type/hash_shape"

module Rigor
  module LanguageServer
    # Answers `textDocument/completion` requests. v1 (slice 5)
    # ships method completion for `obj.|`: when the cursor sits on
    # a `CallNode` with a known-type receiver, the provider
    # enumerates the receiver's RBS-known methods and returns each
    # as an LSP `CompletionItem`.
    #
    # Constant-path completion (slice 6), Union / Intersection /
    # Refined / Shape receiver handling (slice 7), and parse-recovery
    # fallback for malformed buffers (slice 8) extend this v1 floor.
    #
    # LSP `CompletionItemKind` values used:
    # - 2 = Method
    #
    # Slice 6 will add 7 (Class), 9 (Module), 21 (Constant).
    class CompletionProvider
      KIND_METHOD   = 2
      KIND_CLASS    = 7
      KIND_MODULE   = 9
      KIND_CONSTANT = 21

      def initialize(buffer_table:, project_context:)
        @buffer_table = buffer_table
        @project_context = project_context
      end

      # @return [Array<Hash>, nil] LSP `CompletionItem[]` or nil
      #   when the cursor isn't at a position the provider can
      #   enumerate completions for. Returning nil maps to
      #   `result: null` per the LSP spec — clients treat it as
      #   "no completions available," distinct from `[]` which
      #   means "we tried and got nothing".
      def provide(uri:, line:, character:, trigger_character: nil)
        _ = trigger_character # Slice 6+ will route on trigger.
        path = Uri.to_path(uri)
        return nil if path.nil?

        entry = @buffer_table[uri]
        return nil if entry.nil?

        parse_result = Prism.parse(entry.bytes, filepath: path,
                                   version: @project_context.configuration.target_ruby)
        # Slice 5 requires the buffer to parse cleanly. Slice 8
        # adds the lexical-fallback path for mid-edit buffers
        # Prism can't recover.
        return nil unless parse_result.errors.empty?

        # Rigor's NodeLocator uses 1-based line / column; LSP uses 0-based.
        node = locate_node(source: entry.bytes, root: parse_result.value,
                           line: line + 1, character: character + 1)
        return nil if node.nil?

        case node
        when Prism::CallNode
          method_completion_for(node, parse_result.value, path)
        when Prism::ConstantPathNode
          constant_path_completion_for(node, path)
        end
      end

      private

      def method_completion_for(call_node, root, path)
        receiver_node = call_node.receiver
        return nil if receiver_node.nil? # implicit-self — slice-3 territory of completion

        index = build_scope_index(root, path)
        receiver_scope = index[receiver_node]
        receiver_type = receiver_scope.type_of(receiver_node)
        method_completions(receiver_type, receiver_scope)
      end

      # Slice B2 — `Foo::|` constant-path completion. The cursor
      # sits on a `ConstantPathNode` whose `parent` resolves to a
      # class / module FQN; we enumerate every known class whose
      # name is an immediate child of that parent. Top-level
      # constants (`::Foo`) and parent-less paths are not yet
      # supported (queued for slice 6 follow-up).
      def constant_path_completion_for(const_path_node, path)
        parent_fqn = parent_fqn_of(const_path_node)
        return nil if parent_fqn.nil?

        scope = base_scope(path)
        children = enumerate_constant_children(parent_fqn, scope)
        return nil if children.empty?

        children.map { |child| constant_completion_item(parent_fqn, child) }
      end

      def parent_fqn_of(const_path_node)
        # ConstantPathNode#parent is the LHS of the `::`. For
        # `Foo::Bar` it's the ConstantReadNode for `Foo`; for
        # `Foo::Bar::Baz` it's a ConstantPathNode. We render
        # either to the dotted FQN string.
        parent = const_path_node.parent
        return nil if parent.nil?

        qualified_name_of(parent)
      end

      def qualified_name_of(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          parent = qualified_name_of(node.parent) if node.parent
          parent.nil? ? node.name.to_s : "#{parent}::#{node.name}"
        end
      end

      # Walks `RbsLoader#known_class_names_set` for entries whose
      # FQN is `parent_fqn::<one segment>` — the immediate children.
      # Deeper descendants are filtered out so the popup shows
      # only the next-level constants the user can directly write.
      # `known_class_names_set` is private on RbsLoader per the
      # type-system's internal API discipline; the LSP layer is a
      # trusted internal consumer and `send` is the documented
      # escape hatch (same pattern as `Type::Refined#canonical_name`
      # in slice A4).
      def enumerate_constant_children(parent_fqn, scope)
        loader = scope.environment.rbs_loader
        return [] if loader.nil?

        names = loader.send(:known_class_names_set)
        # RBS canonical names carry a leading `::` (so the table
        # holds `::Process::Status` etc.). Match against both
        # forms so the prefix walk works regardless of which form
        # the caller passes.
        prefix = "::#{parent_fqn}::"
        names.filter_map do |fqn|
          next nil unless fqn.start_with?(prefix)

          tail = fqn.delete_prefix(prefix)
          # Only immediate children — no `::` in the tail.
          next nil if tail.empty? || tail.include?("::")

          tail
        end.uniq.sort
      end

      def constant_completion_item(parent_fqn, child_name)
        {
          label: child_name,
          kind: KIND_CLASS, # heuristic; slice-7 follow-up may distinguish Module / Constant
          detail: "#{parent_fqn}::#{child_name}",
          insertText: child_name,
          filterText: child_name,
          sortText: "0_#{child_name}"
        }
      end

      def base_scope(_path)
        Scope.empty(environment: @project_context.environment)
      end

      def locate_node(source:, root:, line:, character:)
        Source::NodeLocator.at_position(source: source, root: root, line: line, column: character)
      rescue Source::NodeLocator::OutOfRangeError
        nil
      end

      def build_scope_index(root, _path)
        scope = Scope.empty(environment: @project_context.environment)
        Inference::ScopeIndexer.index(root, default_scope: scope)
      end

      # Returns an Array<Hash> of LSP `CompletionItem`s for every
      # public method callable on the receiver. Slice B3 extends
      # the slice-B1 floor with:
      # - `Type::Refined` / `Type::Difference` — enumerate the
      #   underlying nominal (refinement narrows the value set,
      #   not the method set).
      # - `Type::Tuple` / `Type::HashShape` — enumerate the
      #   nominal ancestor (`Array` / `Hash`); element-type-aware
      #   completion is queued.
      # - `Type::Union` — intersection of methods on each member
      #   (only methods guaranteed to dispatch on every union case).
      #   Conservative default per design doc § "Union receiver
      #   completion".
      # - `Type::Intersection` — union of methods on each member
      #   (anything callable on at least one member).
      def method_completions(receiver_type, scope)
        method_set, kind = enumerate_method_set(receiver_type, scope)
        return nil if method_set.nil? || method_set.empty?

        method_set.filter_map do |name, method|
          next nil unless method.public?

          completion_item(name: name, method: method, kind: kind)
        end
      end

      # Returns `[{Symbol => RBS::Definition::Method}, :instance | :singleton]`
      # for the receiver. Composite carriers (Union / Intersection /
      # Refined / shape carriers) reduce to instance-method
      # enumeration; the receiver-class label that lands in each
      # CompletionItem's `detail` still comes from each method's
      # own `defs.first.implemented_in`, so the rendered prefix
      # stays accurate per-method.
      def enumerate_method_set(receiver_type, scope)
        case receiver_type
        when Type::Singleton
          [Reflection.singleton_definition(receiver_type.class_name, scope: scope)&.methods, :singleton]
        when Type::Union
          [intersect_member_methods(receiver_type.members, scope), :instance]
        when Type::Intersection
          [union_member_methods(receiver_type.members, scope), :instance]
        when Type::Refined, Type::Difference
          enumerate_method_set(receiver_type.base, scope)
        when Type::Tuple
          [Reflection.instance_definition("Array", scope: scope)&.methods, :instance]
        when Type::HashShape
          [Reflection.instance_definition("Hash", scope: scope)&.methods, :instance]
        else
          class_name = nominal_class_name(receiver_type)
          return [nil, nil] if class_name.nil?

          [Reflection.instance_definition(class_name, scope: scope)&.methods, :instance]
        end
      end

      # Union receiver — keep only methods present in EVERY
      # member's set. Conservative semantically (every method
      # returned is callable on every member) and prevents
      # `obj.upcase` from appearing on a `String | Integer`
      # union where only one side answers `upcase`.
      def intersect_member_methods(members, scope)
        member_sets = members.filter_map { |m| enumerate_method_set(m, scope).first }
        return nil if member_sets.empty?

        common_names = member_sets.map(&:keys).reduce(:&)
        member_sets.first.select { |name, _| common_names.include?(name) }
      end

      # Intersection receiver — accumulate every method declared on
      # ANY member. A value of type `A & B` is callable through both
      # interfaces; the completion popup MAY show either's methods.
      def union_member_methods(members, scope)
        members.filter_map { |m| enumerate_method_set(m, scope).first }.reduce({}, :merge)
      end

      def nominal_class_name(type)
        case type
        when Type::Nominal then type.class_name
        when Type::Constant then type.value.class.name
        end
      end

      def completion_item(name:, method:, kind:)
        label = name.to_s
        method_type = method.method_types.first
        signature = method_type ? method_type.to_s : "(unknown)"
        sep = kind == :singleton ? "." : "#"
        receiver_name = method.defs.first&.implemented_in&.to_s || ""
        detail = receiver_name.empty? ? signature : "#{receiver_name}#{sep}#{label}: #{signature}"

        {
          label: label,
          kind: KIND_METHOD,
          detail: detail,
          insertText: label,
          filterText: label,
          # Inherited methods rank below own-class methods; the
          # `defs.first.implemented_in` carries the declaring
          # class. Inheritance-distance ranking is queued (design
          # doc § "sortText").
          sortText: "1_#{label}"
        }
      end
    end
  end
end
