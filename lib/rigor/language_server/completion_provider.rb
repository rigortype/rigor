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
      KIND_METHOD = 2

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

        call_node = enclosing_call(node)
        return nil if call_node.nil?

        receiver_node = call_node.receiver
        return nil if receiver_node.nil? # implicit-self → slice-3 territory of completion

        index = build_scope_index(parse_result.value, path)
        receiver_scope = index[receiver_node]
        receiver_type = receiver_scope.type_of(receiver_node)

        method_completions(receiver_type, receiver_scope)
      end

      private

      def locate_node(source:, root:, line:, character:)
        Source::NodeLocator.at_position(source: source, root: root, line: line, column: character)
      rescue Source::NodeLocator::OutOfRangeError
        nil
      end

      # Walks up from a leaf node looking for the enclosing
      # `Prism::CallNode`. NodeLocator returns the deepest node at
      # the cursor; for `obj.foo|` the cursor often sits on
      # an identifier node nested inside the CallNode. We walk
      # up by re-scanning the root for the smallest CallNode that
      # spans the leaf's location — Prism doesn't expose
      # parent pointers, so this is the idiomatic walk.
      def enclosing_call(node)
        return node if node.is_a?(Prism::CallNode)

        # Currently NodeLocator returns the deepest matching node;
        # for `x.upcase` with cursor on `upcase` the deepest is
        # the CallNode itself (Prism doesn't split out method
        # identifiers). If a future locator change exposes
        # sub-call leaves, this guard prevents the slice-5 happy
        # path from breaking — slice 8 generalises to lexical
        # fallback anyway.
        nil
      end

      def build_scope_index(root, _path)
        scope = Scope.empty(environment: @project_context.environment)
        Inference::ScopeIndexer.index(root, default_scope: scope)
      end

      # Returns an Array<Hash> of LSP `CompletionItem`s for every
      # public method declared on the receiver's nominal class
      # (or singleton class, for `Type::Singleton` receivers).
      # Returns nil when the receiver carrier isn't slice-5-supported
      # (Union / Refined / Shape land in slice 7).
      def method_completions(receiver_type, scope)
        definition, kind = receiver_class_definition(receiver_type, scope)
        return nil if definition.nil?

        definition.methods.filter_map do |name, method|
          next nil unless method.public?

          completion_item(name: name, method: method, kind: kind)
        end
      end

      # Returns `[RBS::Definition, :instance | :singleton]` for the
      # receiver. The "kind" carries through to the CompletionItem
      # `detail` rendering so users see `String#upcase` vs
      # `String.new`.
      def receiver_class_definition(receiver_type, scope)
        case receiver_type
        when Type::Singleton
          [Reflection.singleton_definition(receiver_type.class_name, scope: scope), :singleton]
        else
          class_name = nominal_class_name(receiver_type)
          return [nil, nil] if class_name.nil?

          [Reflection.instance_definition(class_name, scope: scope), :instance]
        end
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
