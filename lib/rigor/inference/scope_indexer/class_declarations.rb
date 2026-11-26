# frozen_string_literal: true

require "prism"

require_relative "../../source/constant_path"
require_relative "../../source/node_children"
require_relative "../../type"
require_relative "../declaration_walk/rules"

module Rigor
  module Inference
    module ScopeIndexer
      # The cross-file class-declaration walk, moved out of `scope_indexer.rb` whole (ADR-116 WD9, U1).
      # {.collect_class_decls} registers each `class` / `module` declaration of a file, and each constant write
      # that creates a class, under its qualified name; every other function here is an arm or a step of that walk.
      # It asks {DeclarationWalk::Rules} for each declaration context and calls nothing left in `scope_indexer.rb`,
      # which requires this file; this file does not require it back. It reads two of the indexer's constants
      # lexically, `ScopeIndexer::EMPTY_PREFIX` and `ScopeIndexer::RECEIVER_EVAL_CALLS`, so the file loads alone but
      # answers only once `scope_indexer.rb` has loaded: walking a `class <<` body or a call with a block is a
      # `NameError` until then, as the indexer's constants are for {NodePropagation}, which reads them the same way.
      module ClassDeclarations
        module_function

        # Cross-file counterpart of `DeclarationArtifacts.record_declarations` — registers every `class` / `module`
        # declaration under its qualified name and descends into the body (so `module Foo; class Bar` registers both
        # `Foo` and `Foo::Bar`). `self_prefix` names a REBOUND self for `self::`-anchored declarations — see
        # {DeclarationArtifacts.record_declarations}.
        def collect_class_decls(node, qualified_prefix, accumulator, compacts = nil,
                                self_prefix = nil, singleton_cref: false)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ClassNode, Prism::ModuleNode
            return if collect_decl_body?(node, qualified_prefix, accumulator, compacts,
                                         self_prefix, singleton_cref)
          when Prism::SingletonClassNode
            # The expression evaluates in the ENCLOSING cref — `class << (class D; self; end)`
            # still names `C::D` — while the body's cref is the unnameable singleton.
            collect_class_decls(node.expression, qualified_prefix, accumulator, compacts,
                                self_prefix, singleton_cref: singleton_cref)
            if node.body
              collect_class_decls(node.body, qualified_prefix, accumulator, compacts,
                                  EMPTY_PREFIX, singleton_cref: true)
            end
            return
          when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode,
               Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode
            # `K = Class.new` under an unnameable cref lands on the singleton's own table;
            # a path write resolves its base lexically and stays nameable.
            record_class_new_constant_decl(node, qualified_prefix, accumulator,
                                           self_prefix: self_prefix, singleton_cref: singleton_cref)
            return if collect_meta_new_constant_decls?(node, qualified_prefix, accumulator, compacts,
                                                       self_prefix, singleton_cref)
          when Prism::CallNode
            return if collect_eval_class_decls?(node, qualified_prefix, accumulator, compacts,
                                                self_prefix, singleton_cref)
          end

          node.rigor_each_child do |child|
            collect_class_decls(child, qualified_prefix, accumulator, compacts,
                                self_prefix, singleton_cref: singleton_cref)
          end
        end

        # The class/module arm of {#collect_class_decls}. Under an unnameable cref a bare/`self::`
        # header opens `#<singleton>::Name` — a real class nothing can name — so it is declined
        # rather than published as `C::Name`; the body still walks (rooted headers below it
        # re-anchor). Returns whether the declaration was consumed.
        def collect_decl_body?(node, qualified_prefix, accumulator, compacts, self_prefix,
                               singleton_cref)
          self_decl = DeclarationWalk::Rules.self_anchored_decl_prefix(node.constant_path, self_prefix)
          child_prefix = self_decl ||
                         Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
          return false unless child_prefix

          child_cref = DeclarationWalk::Rules.unnameable_decl?(node, self_decl, singleton_cref)
          unless child_cref
            full = child_prefix.join("::")
            accumulator[full] = Type::Combinator.singleton_of(full)
            record_compact_header(compacts, qualified_prefix, node.constant_path, full) if compacts
          end
          return true unless node.body

          collect_class_decls(node.body, child_cref ? [] : child_prefix, accumulator, compacts,
                              nil, singleton_cref: child_cref)
          true
        end

        # The eval-family arm of {#collect_class_decls}: same dual context as
        # {DeclarationArtifacts.record_eval_declarations?} — `self::` headers anchor on the receiver, bare
        # headers stay lexical.
        def collect_eval_class_decls?(node, qualified_prefix, accumulator, compacts, self_prefix,
                                      singleton_cref)
          return false unless node.block.is_a?(Prism::BlockNode) &&
                              RECEIVER_EVAL_CALLS.include?(node.name)

          [node.receiver, *node.arguments&.arguments.to_a].compact.each do |part|
            collect_class_decls(part, qualified_prefix, accumulator, compacts, self_prefix,
                                singleton_cref: singleton_cref)
          end
          unnameable =
            DeclarationWalk::Rules.unnameable_eval_self?(false, self_prefix, qualified_prefix, singleton_cref)
          eval_self = DeclarationWalk::Rules.eval_receiver_prefix(
            node, self_prefix || qualified_prefix, qualified_prefix, unnameable_self: unnameable
          ) || []
          if (body = node.block.body)
            collect_class_decls(body, qualified_prefix, accumulator, compacts, eval_self,
                                singleton_cref: singleton_cref)
          end
          true
        end

        # The meta-new arm of {#collect_class_decls}: the factory call's receiver and
        # arguments evaluate in the enclosing context; the block's `self` is the class the
        # write names (`[]` when it names nothing) while the cref stays lexical.
        def collect_meta_new_constant_decls?(node, qualified_prefix, accumulator, compacts,
                                             self_prefix, singleton_cref)
          call = DeclarationWalk::Rules.meta_new_block_call(node)
          return false unless call

          child_prefix = DeclarationWalk::Rules.meta_new_child_prefix(node, qualified_prefix, self_prefix)
          meta_self =
            if singleton_cref && !DeclarationWalk::Rules.meta_new_path_target_nameable?(node, self_prefix)
              []
            else
              child_prefix || []
            end
          [call.receiver, *call.arguments&.arguments.to_a].compact.each do |part|
            collect_class_decls(part, qualified_prefix, accumulator, compacts,
                                self_prefix, singleton_cref: singleton_cref)
          end
          if (body = DeclarationWalk::Rules.meta_new_block_body(node))
            collect_class_decls(body, qualified_prefix, accumulator, compacts,
                                meta_self, singleton_cref: singleton_cref)
          end
          true
        end

        # Issue [#722](https://github.com/rigortype/rigor/issues/722) residue 2 — records what a COMPACT header
        # written inside an enclosing namespace would name if its leading segment fell through to the top level.
        # `class Outer::Leaf` inside `module Wrap` is keyed `Wrap::Outer::Leaf` by the per-node
        # {Source::ConstantPath.declaration_prefix}, but Ruby resolves the leading `Outer` by ORDINARY constant
        # lookup: it reopens `::Outer::Leaf` unless `Wrap::Outer` exists. Whether it exists is a whole-project
        # fact, so the candidate is recorded here and adjudicated once the fold knows every declared name
        # ({ScopeIndexer#compact_header_renames}).
        #
        # @param compacts — `{recorded name => [namespace the header needs, name it falls through to]}`.
        def record_compact_header(compacts, qualified_prefix, constant_path, full)
          return if qualified_prefix.empty?
          return unless constant_path.is_a?(Prism::ConstantPathNode)
          return if Source::ConstantPath.rooted?(constant_path)

          rendered = Source::ConstantPath.qualified_name(constant_path)
          return unless rendered&.include?("::")

          compacts[full] = [(qualified_prefix + [rendered.split("::").first]).join("::"), rendered]
        end

        # T1 (template-corpora survey) — record a class-creating constant write (`Const = Class.new(Super)`, the bare
        # `Class.new` / `Module.new`, and the `Data.define(*sym)` / `Struct.new(*sym)` forms, each with or without a
        # block) in the cross-file discovery table so a reference to `Const` from ANOTHER file under the same namespace
        # resolves to the project class instead of falling through to a same-named class elsewhere
        # (`Liquid::SyntaxError = Class.new(Error)` referenced in a sibling file's `rescue SyntaxError => e`, which
        # otherwise resolved to core `::SyntaxError`). Mirrors the single-file `in_source_constants` answer, which types
        # `Class.new(Super)` as `Singleton[Super]` (the constructed class answers method lookups through Super's chain)
        # and every other recognised form as `Singleton[Const]`.
        #
        # #271 — the Data/Struct forms are here because their absence was an ACTIVE false positive, not merely a missed
        # resolution: a nested `Const = Data.define(...)` invisible cross-file lets Ruby's lexical walk continue to the
        # PARENT namespace's same-named sibling, so `Analysis::PluginFactFingerprint.from_registry(...).opaque?` typed
        # its receiver as the unrelated `Rigor::Analysis::Result` and reported `call.undefined-method` on correct code.
        # Nested `Result` / `Entry` / `Config` Data constants shadowing a sibling are ordinary Ruby, and only the
        # DEFINING file's `in_source_constants` (never part of the project seed) knew about them.
        def record_class_new_constant_decl(node, qualified_prefix, accumulator, self_prefix: nil,
                                           singleton_cref: false)
          rvalue = DeclarationWalk::Rules.meta_new_rvalue(node)
          return unless rvalue && DeclarationWalk::Rules.meta_new_constant_rvalue?(rvalue)
          return if singleton_cref && !DeclarationWalk::Rules.meta_new_path_target_nameable?(node, self_prefix)

          child_prefix = DeclarationWalk::Rules.meta_new_child_prefix(node, qualified_prefix, self_prefix)
          return if child_prefix.nil? || child_prefix.empty?

          full = child_prefix.join("::")
          accumulator[full] = Type::Combinator.singleton_of(
            meta_new_constant_decl_name(rvalue, full, qualified_prefix, accumulator)
          )
        end

        # The name the constant's `Singleton[...]` carries. Only a block-less `Class.new(Super)` borrows its
        # superclass's name (the constructed class answers lookups through `Super`'s chain and declares nothing of its
        # own); every other form — Data/Struct members, any block body — owns methods under its OWN qualified name,
        # which is exactly what the per-file `ConstantTables.meta_new_constant_type` answers.
        def meta_new_constant_decl_name(rvalue, full, qualified_prefix, accumulator)
          return full if rvalue.block || DeclarationWalk::Rules.data_define_call?(rvalue) ||
                         DeclarationWalk::Rules.struct_new_call?(rvalue)

          class_new_superclass_name(rvalue, qualified_prefix, accumulator) || full
        end

        # Lexically-qualified name of a `Class.new(Super)` superclass argument, or nil when there is no positional
        # superclass (a bare `Class.new` / `Module.new`). When the unqualified super name is a class already discovered
        # under an enclosing-prefix segment, the qualified form is returned (so `Class.new(Error)` inside `module M`
        # resolves to `M::Error`); otherwise the literal name is returned (covering a core / RBS-known superclass
        # spelled bare).
        def class_new_superclass_name(call_node, qualified_prefix, accumulator)
          arg = call_node.arguments&.arguments&.first
          return nil if arg.nil?

          raw = Source::ConstantPath.qualified_name(arg)
          return nil if raw.nil?

          prefix = qualified_prefix.dup
          until prefix.empty?
            candidate = (prefix + [raw]).join("::")
            return candidate if accumulator.key?(candidate)

            prefix.pop
          end
          raw
        end

        private_class_method :collect_decl_body?, :collect_eval_class_decls?, :collect_meta_new_constant_decls?,
                             :record_compact_header, :record_class_new_constant_decl, :meta_new_constant_decl_name,
                             :class_new_superclass_name
      end
    end
  end
end
