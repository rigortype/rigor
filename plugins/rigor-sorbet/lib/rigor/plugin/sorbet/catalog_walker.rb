# frozen_string_literal: true

require "rigor/source/node_children"

require "prism"

require_relative "method_signature"
require_relative "sig_parser"

module Rigor
  module Plugin
    class Sorbet < Rigor::Plugin::Base
      # Walks a parsed Prism program looking for `sig { ... }` / `sig do ... end` calls that immediately
      # precede a `def` (or a `def self.foo` / `class << self; def foo; end`). Each recognised pair is
      # parsed by {SigParser} and recorded in the {Catalog} under its qualified `(class_name, method_name,
      # kind)` key.
      #
      # Anything we don't recognise (a stray `sig { ... }` not followed by a `def`, a `def` with no
      # preceding `sig`, malformed sig blocks, etc.) is reported back to the caller through
      # `parse_errors:` so the plugin can emit a `plugin.sorbet.parse-error` diagnostic. Walking is
      # otherwise infallible — a bad sig block does not abort the catalog build for the rest of the file.
      module CatalogWalker
        # Detected error during walking. `kind` is one of: `:no_block` / `:empty_block` /
        # `:missing_returns_or_void` / `:duplicate_sig` / `:dangling_sig`.
        ParseError = Data.define(:kind, :node, :path)

        module_function

        # @param root — the file's program node.
        # @param catalog — mutable; signatures are recorded into it.
        # @param path — file path used for diagnostic provenance.
        # @param struct_catalog — where the `T::Struct`-family accessors, superclasses, and own `def`s are
        #   recorded (issue #2541). Defaults to `catalog`; the plugin passes the per-run catalog here even
        #   when `catalog` is the discard catalog of an unenforced-sigil file, because sorbet-runtime defines
        #   a struct's accessors whatever the file's `# typed:` level.
        # @return errors observed during the walk; empty when the file is sig-clean.
        def walk(root:, catalog:, path:, struct_catalog: catalog)
          state = State.new(catalog: catalog, path: path, struct_catalog: struct_catalog)
          walk_node(root, state, lexical_path: [], in_singleton_class: false)
          state.errors
        end

        State = Struct.new(:catalog, :path, :errors, :struct_catalog, keyword_init: true) do
          def initialize(catalog:, path:, struct_catalog: catalog)
            super(catalog: catalog, path: path, errors: [], struct_catalog: struct_catalog)
          end

          def record_error(kind, node)
            errors << ParseError.new(kind: kind, node: node, path: path)
          end
        end

        def walk_node(node, state, lexical_path:, in_singleton_class:)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ClassNode
            descend_class(node, state, lexical_path)
          when Prism::ModuleNode
            descend_class_or_module(node, state, lexical_path)
          when Prism::SingletonClassNode
            descend_singleton_class(node, state, lexical_path)
          when Prism::StatementsNode
            walk_statements(node, state, lexical_path: lexical_path, in_singleton_class: in_singleton_class)
          when Prism::DefNode
            # A `def` not preceded by a `sig` is fine; we just don't record anything for it. The
            # interesting case is in `walk_statements`, which pairs sig+def.
          when Prism::CallNode
            # Issue #2541 — any `include` / `prepend` in a class (whatever its arguments) opens the class's
            # ancestry, so a struct accessor's constant is no longer answered from the top level.
            if node.receiver.nil? && %i[include prepend].include?(node.name) && !lexical_path.empty?
              state.struct_catalog.record_mixes_in(lexical_path.join("::"))
            end
            node.rigor_each_child do |child|
              walk_node(child, state, lexical_path: lexical_path, in_singleton_class: in_singleton_class)
            end
          when Prism::ConstantWriteNode
            # Issue #2541 — `Thing = Other` makes `Thing` a constant that is not a class declaration, so a
            # struct accessor's type naming it is not read as any class.
            state.struct_catalog.record_constant((lexical_path + [node.name.to_s]).join("::"))
            walk_node(node.value, state, lexical_path: lexical_path, in_singleton_class: in_singleton_class)
          else
            node.rigor_each_child do |child|
              walk_node(child, state, lexical_path: lexical_path, in_singleton_class: in_singleton_class)
            end
          end
        end

        # Issue #2541 — a `class` records its superclass, and only its body's own top-level statements,
        # which certainly run at class definition, may declare `prop` / `const` accessors.
        def descend_class(node, state, lexical_path)
          name = qualified_name_for(node.constant_path)
          return descend_class_or_module(node, state, lexical_path) unless name

          record_superclass(node, name, state, lexical_path)
          state.struct_catalog.record_namespace((lexical_path + [name]).join("::"))
          if node.body.is_a?(Prism::StatementsNode)
            walk_statements(node.body, state, lexical_path: lexical_path + [name], in_singleton_class: false,
                                              class_body: true)
          else
            descend_class_or_module(node, state, lexical_path)
          end
        end

        def descend_class_or_module(node, state, lexical_path)
          name = qualified_name_for(node.constant_path)
          state.struct_catalog.record_namespace((lexical_path + [name]).join("::")) if name
          if name && node.body
            child_prefix = lexical_path + [name]
            walk_node(node.body, state, lexical_path: child_prefix, in_singleton_class: false)
          elsif node.body
            walk_node(node.body, state, lexical_path: lexical_path, in_singleton_class: false)
          end
        end

        def descend_singleton_class(node, state, lexical_path)
          if node.expression.is_a?(Prism::SelfNode) && node.body
            walk_node(node.body, state, lexical_path: lexical_path, in_singleton_class: true)
          elsif node.body
            walk_node(node.body, state, lexical_path: lexical_path, in_singleton_class: false)
          end
        end

        # The pair-finding loop. Walks a `StatementsNode`'s children left-to-right; when it encounters a
        # `sig` call, it remembers it and consumes the very next `def` / `def self.foo` as the target.
        # Anything between a sig and its def (a comment is fine — comments aren't AST nodes — but a
        # method call would be a problem) leaves the sig dangling.
        def walk_statements(statements, state, lexical_path:, in_singleton_class:, class_body: false)
          pending_sig = nil

          statements.body.each do |child|
            record_defined_method(child, state, lexical_path) unless in_singleton_class
            record_struct_prop_call(child, state, lexical_path, certain: class_body) unless in_singleton_class

            if pending_sig && def_node?(child)
              record_def_with_sig(child, pending_sig, state, lexical_path, in_singleton_class)
              pending_sig = nil
            elsif pending_sig && attr_macro_call?(child)
              # `sig { returns(T) }` above `attr_reader :name` / `attr_accessor` / `attr_writer` types
              # the generated accessor(s). This is a first-class Sorbet idiom — not a dangling sig — so
              # record the accessor signature(s) instead of warning.
              record_attr_with_sig(child, pending_sig, state, lexical_path, in_singleton_class)
              pending_sig = nil
            elsif pending_sig && (inner_def = visibility_wrapped_def(child))
              # `sig { ... }` above `private def foo` / `private_class_method def self.foo` /
              # `module_function def bar` — a visibility macro wrapping the very def the sig types.
              # Record the inner def, not a dangling sig.
              record_def_with_sig(inner_def, pending_sig, state, lexical_path, in_singleton_class)
              pending_sig = nil
            elsif sig_call?(child)
              state.record_error(:duplicate_sig, pending_sig) if pending_sig
              pending_sig = child
            else
              if pending_sig
                state.record_error(:dangling_sig, pending_sig)
                pending_sig = nil
              end
              # ADR-11 slice 8 — record `include` / `extend` declarations alongside the regular walk so
              # the plugin's chain lookup can lift sigs declared on a mixed-in module to the host class.
              record_mixin_call(child, state, lexical_path) if mixin_call?(child) && !in_singleton_class
              walk_node(child, state, lexical_path: lexical_path, in_singleton_class: in_singleton_class)
            end
          end

          state.record_error(:dangling_sig, pending_sig) if pending_sig
        end

        # `include Foo` / `extend Foo` / `include Foo, Bar` — the `include` and `extend` mixin macros that
        # Tapioca-generated DSL RBIs depend on. Recognised when the call has no explicit receiver
        # (top-level inside a class body) and every argument is a constant reference.
        def mixin_call?(node)
          return false unless node.is_a?(Prism::CallNode)
          return false unless %i[include extend].include?(node.name)
          return false unless node.receiver.nil?

          args = node.arguments&.arguments
          return false if args.nil? || args.empty?

          args.all? do |arg|
            arg.is_a?(Prism::ConstantReadNode) || arg.is_a?(Prism::ConstantPathNode)
          end
        end

        def record_mixin_call(node, state, lexical_path)
          return if lexical_path.empty?

          class_name = lexical_path.join("::")
          kind = node.name == :include ? :include : :extend
          (node.arguments&.arguments || []).each do |arg|
            module_name = qualified_name_for(arg)
            next if module_name.nil?

            state.catalog.record_mixin(
              class_name: class_name, kind: kind, module_name: module_name
            )
            # Issue #2541 — an included module's constants shadow a top-level one for the class body.
            state.struct_catalog.record_struct_include(class_name, module_name) if kind == :include
          end
        end

        # Issue #2541 — `class X < Y`: the superclass as written plus the enclosing namespaces, so the
        # catalog can follow `X`'s chain to a `T::Struct`-family root. `lexical_path` holds the enclosing
        # names (a nested `class A::B` element counts as one namespace step, as Ruby's cref does).
        def record_superclass(node, name, state, lexical_path)
          written = qualified_name_for(node.superclass)
          return if written.nil?

          state.struct_catalog.record_superclass(
            class_name: (lexical_path + [name]).join("::"), written: written, lexical_prefix: lexical_path
          )
        end

        # The instance methods a class body defines itself — `def foo`, `private def foo`, `attr_reader :foo` /
        # `attr_writer` / `attr_accessor` — so a struct accessor of the same name yields to them.
        def record_defined_method(node, state, lexical_path)
          return if lexical_path.empty?

          class_name = lexical_path.join("::")
          defined_method_names(node).each do |method_name|
            state.struct_catalog.record_defined_method(class_name: class_name, method_name: method_name)
          end
        end

        def defined_method_names(node)
          target = visibility_wrapped_def(node) || node
          if def_node?(target)
            target.receiver.nil? ? [target.name] : []
          elsif attr_macro_call?(target)
            attr_method_names(target)
          else
            []
          end
        end

        def attr_method_names(attr_node)
          attr_node.arguments.arguments.flat_map do |arg|
            name = arg.unescaped
            case attr_node.name
            when :attr_reader then [name.to_sym]
            when :attr_writer then [:"#{name}="]
            else [name.to_sym, :"#{name}="]
            end
          end
        end

        STRUCT_PROP_MACROS = %i[prop const].freeze

        # Issue #2541 — `prop :name, Type, **rules` / `const :name, Type, **rules` in a class body. Records
        # the reader (both macros) and the writer (`prop` only); the catalog decides at lookup whether the
        # class is a `T::Struct`-family class at all. At the body's top level (`certain:`) the accessor is
        # typed by the translated `Type`. Nested under an `if`, a `begin`, or a block in the body, the call
        # may not run, so the accessor is recorded as possible: typed `Dynamic[top]`, which keeps a call
        # to it quiet without claiming its type. A name that is not a literal Symbol records nothing
        # (`T::Props` takes a Symbol).
        def record_struct_prop_call(node, state, lexical_path, certain:)
          return if lexical_path.empty?
          return unless node.is_a?(Prism::CallNode) && node.receiver.nil?
          return unless STRUCT_PROP_MACROS.include?(node.name)

          args = node.arguments&.arguments
          return if args.nil? || args.empty?

          return unless args.first.is_a?(Prism::SymbolNode)

          name = args.first.unescaped

          type_node = args[1] unless args[1].is_a?(Prism::KeywordHashNode)
          # The constants in the type resolve at lookup, against the classes every file declares, so only
          # the source text is kept; the signature's own type is the placeholder until then.
          type_source = type_node&.slice if certain
          class_name = lexical_path.join("::")
          record_struct_accessor(state, class_name, name.to_sym, type_source, lexical_path, certain)
          return unless node.name == :prop && !immutable_rule?(args)

          record_struct_accessor(state, class_name, :"#{name}=", type_source, lexical_path, certain)
        end

        # `prop :x, T, immutable: true` is the long form of `const`: no writer.
        def immutable_rule?(args)
          args.any? do |arg|
            arg.is_a?(Prism::KeywordHashNode) && arg.elements.any? do |element|
              element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode) &&
                element.key.unescaped == "immutable" && element.value.is_a?(Prism::TrueNode)
            end
          end
        end

        def record_struct_accessor(state, class_name, method_name, type_source, nesting, certain)
          state.struct_catalog.record_struct_prop(
            MethodSignature.new(
              class_name: class_name, method_name: method_name, kind: :instance,
              params: {}, return_type: Rigor::Type::Combinator.untyped, modifiers: []
            ),
            certain: certain, type_source: type_source, nesting: nesting
          )
        end

        def sig_call?(node)
          node.is_a?(Prism::CallNode) &&
            node.name == :sig &&
            node.receiver.nil? &&
            !node.block.nil?
        end

        def def_node?(node)
          node.is_a?(Prism::DefNode)
        end

        VISIBILITY_MACROS = %i[
          private public protected
          private_class_method public_class_method module_function
        ].freeze

        # `private def foo` / `private_class_method def self.bar` / `module_function def baz` — a
        # receiverless visibility macro whose single argument is the `def` it wraps. Returns the inner
        # `Prism::DefNode` (so a preceding sig types it), or nil. The def's own receiver still drives
        # instance-vs-singleton, so `private_class_method def self.bar` records as singleton.
        def visibility_wrapped_def(node)
          return nil unless node.is_a?(Prism::CallNode) && node.receiver.nil?
          return nil unless VISIBILITY_MACROS.include?(node.name)

          args = node.arguments&.arguments || []
          return nil unless args.size == 1 && args.first.is_a?(Prism::DefNode)

          args.first
        end

        ATTR_MACROS = %i[attr_reader attr_writer attr_accessor].freeze

        # `attr_reader :a, :b` / `attr_writer` / `attr_accessor` — a receiverless attribute macro whose
        # arguments are all symbol literals (the only shape a preceding `sig` types).
        def attr_macro_call?(node)
          return false unless node.is_a?(Prism::CallNode) && node.receiver.nil?
          return false unless ATTR_MACROS.include?(node.name)

          args = node.arguments&.arguments
          !args.nil? && !args.empty? && args.all?(Prism::SymbolNode)
        end

        # Records the method signature(s) a `sig` contributes to the accessor(s) it precedes: the reader
        # `name` and/or the writer `name=`, each carrying the sig's `returns(...)` type. `attr_reader`
        # emits the reader, `attr_writer` the writer, `attr_accessor` both — for every symbol argument.
        def record_attr_with_sig(attr_node, sig_call, state, lexical_path, in_singleton_class)
          parsed = SigParser.parse(sig_call)
          if parsed.is_a?(SigParser::ParseError)
            state.record_error(parsed.reason, sig_call)
            return
          end

          class_name = lexical_path.empty? ? "Object" : lexical_path.join("::")
          kind = in_singleton_class ? :singleton : :instance
          reader = attr_node.name != :attr_writer
          writer = attr_node.name != :attr_reader

          attr_node.arguments.arguments.each do |arg|
            name = arg.unescaped
            catalog_record(state.catalog, class_name, name.to_sym, kind, parsed) if reader
            catalog_record(state.catalog, class_name, :"#{name}=", kind, parsed) if writer
          end
        end

        def record_def_with_sig(def_node, sig_call, state, lexical_path, in_singleton_class)
          parsed = SigParser.parse(sig_call)
          if parsed.is_a?(SigParser::ParseError)
            state.record_error(parsed.reason, sig_call)
            return
          end

          class_name = lexical_path.empty? ? "Object" : lexical_path.join("::")
          kind = singleton_method?(def_node, in_singleton_class) ? :singleton : :instance
          catalog_record(state.catalog, class_name, def_node.name, kind, parsed)
        end

        def catalog_record(catalog, class_name, method_name, kind, parsed)
          catalog.record(
            MethodSignature.new(
              class_name: class_name,
              method_name: method_name,
              kind: kind,
              params: parsed.params,
              return_type: parsed.return_type,
              modifiers: parsed.modifiers
            )
          )
        end

        def singleton_method?(def_node, in_singleton_class)
          in_singleton_class || def_node.receiver.is_a?(Prism::SelfNode)
        end

        # Resolves a constant-path node (`Foo::Bar`, `::Foo::Bar`) to its dot-separated name. Returns nil
        # for the rare dynamic-prefix shape so the walker doesn't guess a qualified name in that case.
        def qualified_name_for(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode
            parts = []
            current = node
            while current.is_a?(Prism::ConstantPathNode)
              parts.unshift(current.name.to_s)
              current = current.parent
            end
            case current
            when nil then "::#{parts.join('::')}"
            when Prism::ConstantReadNode then "#{current.name}::#{parts.join('::')}"
            end
          end
        end
      end
    end
  end
end
