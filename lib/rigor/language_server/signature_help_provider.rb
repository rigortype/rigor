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
require_relative "../type/refined"
require_relative "../type/difference"
require_relative "../type/tuple"
require_relative "../type/hash_shape"

module Rigor
  module LanguageServer
    # Answers `textDocument/signatureHelp` requests. When the user
    # types `(` inside a method call (`obj.foo(|`) editors fire
    # `signatureHelp` to show the method's parameter signature
    # inline. The provider parses the buffer, locates the enclosing
    # `CallNode`, infers the receiver's type, and returns the
    # method's first overload as a `SignatureInformation`.
    #
    # Slice C1 (this commit) ships:
    # - Sentinel patching for `obj.foo(|` so Prism's parse
    #   succeeds (mirrors `CompletionProvider`'s slice B4 pattern).
    # - First-overload signature only.
    # - Active parameter = comma count before cursor.
    #
    # Multi-overload presentation + `documentation` field +
    # active-parameter override per overload land in follow-up
    # slices (queued in the design doc § "Out of scope for v2").
    class SignatureHelpProvider
      ARG_SENTINEL = "__rigor_lsp_arg_sentinel__"
      private_constant :ARG_SENTINEL

      def initialize(buffer_table:, project_context:)
        @buffer_table = buffer_table
        @project_context = project_context
      end

      # @return [Hash, nil] LSP `SignatureHelp` payload or nil
      #   when the cursor isn't inside a resolvable method call.
      def provide(uri:, line:, character:, context: nil)
        _ = context # Trigger info accepted but not routed in v1.
        path = Uri.to_path(uri)
        return nil if path.nil?

        entry = @buffer_table[uri]
        return nil if entry.nil?

        bytes, locate_at = parse_attempt_bytes(entry.bytes, line, character)
        parse_result = Prism.parse(bytes, filepath: path,
                                          version: @project_context.configuration.target_ruby)
        return nil unless parse_result.errors.empty?

        cursor_offset = byte_offset_for(bytes, locate_at[0], locate_at[1])
        return nil if cursor_offset.nil?

        call_node = enclosing_call_for_offset(parse_result.value, cursor_offset)
        return nil if call_node.nil?

        build_signature(call_node, parse_result.value, path, bytes, locate_at[0], locate_at[1])
      end

      private

      def parse_attempt_bytes(original_bytes, line, character)
        return [original_bytes, [line, character]] if Prism.parse(original_bytes).errors.empty?

        patch_with_arg_sentinel(original_bytes, line, character)
      end

      # Mid-edit buffer at `obj.foo(|` or `obj.foo(1,|`: truncate
      # everything from the cursor onwards and append `SENTINEL)`
      # so the call is syntactically complete. The truncation is
      # aggressive — signatureHelp only cares about the enclosing
      # call's signature; downstream content (closing parens,
      # subsequent statements) is irrelevant.
      def patch_with_arg_sentinel(original_bytes, line, character)
        prefix_offset = byte_offset_for(original_bytes, line, character)
        return [original_bytes, [line, character]] if prefix_offset.nil?

        prefix = original_bytes.byteslice(0, prefix_offset)
        stripped = prefix.rstrip
        return [original_bytes, [line, character]] unless stripped.end_with?("(") || stripped.end_with?(",")

        patched = "#{prefix}#{ARG_SENTINEL})\n"
        [patched, [line, character]]
      end

      # Walks the AST for the smallest CallNode whose `arguments`
      # location encloses the cursor offset. Prism doesn't expose
      # parent pointers, so NodeLocator's leaf-returning shape
      # isn't enough; we re-walk. For LSP usage this is cheap —
      # the buffer is parsed once per request.
      def enclosing_call_for_offset(root, cursor_offset)
        result = nil
        walk = lambda do |n|
          next unless n.is_a?(Prism::Node)

          if n.is_a?(Prism::CallNode) && n.arguments && offset_in?(n.arguments.location, cursor_offset)
            result = n # Innermost-wins because we keep walking children.
          end
          n.compact_child_nodes.each(&walk)
        end
        walk.call(root)
        result
      end

      def offset_in?(location, offset)
        offset.between?(location.start_offset, location.end_offset)
      end

      def build_signature(call_node, root, path, bytes, line, character)
        scope_index = build_scope_index(root, path)
        receiver_node = call_node.receiver
        return nil if receiver_node.nil?

        receiver_type = scope_index[receiver_node].type_of(receiver_node)
        definition = lookup_method(receiver_type, call_node.name, scope_index[receiver_node])
        return nil if definition.nil? || definition.method_types.empty?

        active_param = active_parameter_index(call_node, bytes, line, character)
        doc = rbs_documentation(definition)
        signatures = definition.method_types.map do |method_type|
          info = { label: "#{call_node.name}#{method_type}", parameters: [] }
          info[:documentation] = { kind: "markdown", value: doc } if doc
          info
        end
        {
          signatures: signatures,
          # `activeSignature` is the index editors highlight by
          # default. Slice C2 picks the first overload uniformly;
          # a future slice could choose the overload that best
          # matches the current argument shape.
          activeSignature: 0,
          activeParameter: active_param
        }
      end

      # Identical contract to HoverRenderer#rbs_documentation —
      # surfaces the method's RBS comment text or nil. Kept inline
      # rather than extracted to a shared mixin because the two
      # call sites are small and the shape may diverge (signatureHelp
      # might want per-parameter docs split out; hover wants the
      # full paragraph).
      def rbs_documentation(definition)
        comments = definition.respond_to?(:comments) ? definition.comments : nil
        return nil if comments.nil? || comments.empty?

        text = comments.map(&:string).join("\n\n").strip
        text.empty? ? nil : text
      end

      def lookup_method(receiver_type, method_name, scope)
        case receiver_type
        when Type::Singleton
          Reflection.singleton_method_definition(receiver_type.class_name, method_name, scope: scope)
        when Type::Refined, Type::Difference
          lookup_method(receiver_type.base, method_name, scope)
        else
          class_name = nominal_class_name(receiver_type)
          return nil if class_name.nil?

          Reflection.instance_method_definition(class_name, method_name, scope: scope)
        end
      end

      # Mirrors CompletionProvider's receiver-type mapping. Tuple →
      # Array, HashShape → Hash, Refined / Difference unwrap to
      # their base (handled in `lookup_method` above for clarity).
      def nominal_class_name(type)
        case type
        when Type::Nominal then type.class_name
        when Type::Constant then type.value.class.name
        when Type::Tuple then "Array"
        when Type::HashShape then "Hash"
        end
      end

      def build_scope_index(root, _path)
        scope = Scope.empty(environment: @project_context.environment)
        Inference::ScopeIndexer.index(root, default_scope: scope)
      end

      # Counts commas in the buffer between the call's opening `(`
      # and the cursor position. Cursor on the first argument → 0;
      # after one comma → 1; etc. Bounded by the call's arguments
      # location so commas in nested expressions don't bleed in.
      def active_parameter_index(call_node, bytes, line, character)
        return 0 if call_node.arguments.nil?

        cursor_offset = byte_offset_for(bytes, line, character)
        args_loc = call_node.arguments.location
        return 0 if args_loc.nil? || cursor_offset.nil?

        scan_start = args_loc.start_offset
        scan_end = [cursor_offset, args_loc.end_offset].min
        return 0 if scan_end <= scan_start

        bytes.byteslice(scan_start, scan_end - scan_start).count(",")
      end

      def byte_offset_for(bytes, line, character)
        offset = 0
        bytes.each_line.with_index do |line_bytes, idx|
          return offset + character if idx == line

          offset += line_bytes.bytesize
        end
        nil
      end
    end
  end
end
