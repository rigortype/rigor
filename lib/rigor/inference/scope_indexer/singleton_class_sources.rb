# frozen_string_literal: true

require "prism"

require_relative "../../source/constant_path"
require_relative "../../source/node_children"
require_relative "../declaration_walk/rules"

module Rigor
  module Inference
    module ScopeIndexer
      # The constants whose singleton side a file writes to without declaring them (#1752, #1941), moved out of
      # `scope_indexer.rb` whole (ADR-116 WD9, #3400). {.record_singleton_class_sources} is the entry the cross-file
      # fold's per-file build calls (`ScopeIndexer.record_file_positions`): it files each such constant under the
      # file's path in the `singleton_class_sources` table, which only the incremental class-declaration diff reads.
      # The other three functions are private: the walk and its two steps.
      #
      # It asks {DeclarationWalk::Rules} for the name a constant receiver resolves to and calls two functions left in
      # `scope_indexer.rb`, at three sites: `ScopeIndexer.singleton_receiver_constant_name` (the constant a
      # `class <<` operand or a receiver names) and `ScopeIndexer.surface_rewriting_call?` (whether a call may
      # rewrite its receiver's singleton side), two recognisers the other walkers ask too. It reads none of the
      # indexer's constants. `scope_indexer.rb` requires this file, and this file does not require it back. So the
      # file loads alone, and until `scope_indexer.rb` has loaded the entry answers only for a program with no
      # `class <<` body, no call and no `def` on a constant: each of those is a `NoMethodError`.
      module SingletonClassSources
        module_function

        # Issue #1752 — the constants a `class << Const` body opens in this file, and those whose singleton side a call
        # there may rewrite ({.singleton_side_call?}). Such a body records facts about
        # `Const`'s singleton class (a `remove_method`, a `def`) without declaring `Const`, so it stays out of
        # `class_sources` (whose readers take a name there as one the project declares) and joins only the per-file
        # class-declaration sets the incremental `class:` edges diff (`Runner#class_declarations`).
        #
        # Issue #1941 — so does a `def Const.x` (`def D.own`, or `def E.x` inside `module M`, resolved as a `class << E`
        # receiver is): it adds to `Const`'s singleton side from a file the reader's class edge need not name. In the
        # set, the declaration diff fires `class:` when the file gains or loses one, and
        # `IncrementalSession#singleton_rewrite_affected` fires it when one is renamed. `def (M::E).x` records no
        # singleton `def` at all, so it joins nothing.
        def record_singleton_class_sources(sources, path, root)
          collect_singleton_class_targets(root, []) { |name| (sources[name] ||= Set.new) << path }
        end

        def collect_singleton_class_targets(node, lexical_prefix, &)
          case node
          when Prism::ClassNode, Prism::ModuleNode
            prefix = Source::ConstantPath.declaration_prefix(lexical_prefix, node.constant_path)
            node.body && prefix && collect_singleton_class_targets(node.body, prefix, &)
            return
          when Prism::SingletonClassNode
            rendered = ScopeIndexer.singleton_receiver_constant_name(node.expression)
            if rendered
              yield DeclarationWalk::Rules.eval_constant_receiver_prefix(node, node.expression, rendered,
                                                                         lexical_prefix).join("::")
            end
          when Prism::CallNode
            yield_singleton_side_constant(node, node.receiver, lexical_prefix, &) if singleton_side_call?(node)
          when Prism::DefNode
            yield_singleton_side_constant(node, node.receiver, lexical_prefix, &)
          end
          node.rigor_each_child { |child| collect_singleton_class_targets(child, lexical_prefix, &) }
        end

        # A call on a constant that may rewrite its singleton side (`Const.singleton_class`,
        # `Const.define_singleton_method`, `Const.extend(M)`, `Const.instance_eval { … }`) records facts about `Const`'s
        # singleton methods the refinement walk reads from a file that need not declare `Const`, so the file joins the
        # constant's set too. Written inside `Const`'s own body, the name is in the file's set already.
        def singleton_side_call?(node)
          node.name == :singleton_class || ScopeIndexer.surface_rewriting_call?(node)
        end

        def yield_singleton_side_constant(node, receiver, lexical_prefix)
          return unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)

          rendered = ScopeIndexer.singleton_receiver_constant_name(receiver)
          return unless rendered

          yield DeclarationWalk::Rules.eval_constant_receiver_prefix(node, receiver, rendered,
                                                                     lexical_prefix).join("::")
        end

        private_class_method :collect_singleton_class_targets, :singleton_side_call?, :yield_singleton_side_constant
      end
    end
  end
end
