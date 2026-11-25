# frozen_string_literal: true

require "digest"
require "prism"

module Rigor
  module Inference
    module ScopeIndexer
      # ADR-89 WD1's declaration signature of one file, moved out of `scope_indexer.rb` whole (ADR-116 WD9, L1).
      # {.declaration_signature} renders the cross-file declaration surfaces of a single file's index into parts
      # and digests them; every other function here is one of its parts. It reads the index it is handed and,
      # lexically, `ScopeIndexer::CONSTANT_MEMO`, and calls nothing else of the indexer: `scope_indexer.rb` requires
      # this file, and this file does not require it back. So the file loads alone but answers only once
      # `scope_indexer.rb` has loaded: rendering a constant write that publishes no literal reads `CONSTANT_MEMO`, a
      # `NameError` until then, as the indexer's constants are for {NodePropagation}, which reads them the same way.
      module DeclarationSignature
        module_function

        # ADR-89 WD1 — a per-file digest of every cross-file DECLARATION surface an ancestry / file-level
        # dependent consumes, EXCLUDING method bodies (which only symbol dependents consume, via the ADR-46
        # symbol edges the change-detection already fingerprints per method). A body edit that touches no
        # signature leaves this equal, so the session drops the file's ancestry / file-level dependents; an
        # arity / visibility / added-or-removed-method / ancestry / member-layout edit moves it. Deliberately
        # SYNTACTIC (parameter structure from the def node, not inferred types).
        #
        # It captures, from a single file's live def-index: declared class/module names, superclass + include
        # ancestry, Data/Struct member layouts, the accessor/alias/define_method existence table, per-method
        # visibilities, and per method (instance + singleton) its name, parameter signature, AND def-start LINE.
        # The line is load-bearing for soundness: a body edit that SHIFTS a later def's line moves the ADR-17
        # `project_definition_site` a `call.undefined-method` consumer embeds, so a line shift must invalidate
        # the declaration (the file's dependents re-check) — this is why the signature is a superset of B1's
        # comment-stripped code fingerprint on line-moving edits, and strictly more permissive only on
        # same-line body edits (a local rename, an internal literal), which is the collapse WD1 exists for.
        def declaration_signature(file_index)
          parts = []
          append_ancestry_signature(parts, file_index)
          append_constant_signature(parts, file_index)
          append_declaration_tables(parts, file_index)
          append_def_signatures(parts, file_index[:def_nodes], "#")
          append_def_signatures(parts, file_index[:singleton_def_nodes], ".")
          append_envelope_signature(parts, file_index[:parameter_envelopes] || {})
          append_certainty_signature(parts, file_index[:siblings] || {})
          Digest::SHA256.hexdigest(parts.join("\x00"))
        end

        # ADR-119 WD3 — which of the file's contributions are possible is a declaration surface too: a `… end if X`
        # modifier, or moving a `def` into a block, keeps every def line and envelope and moves only this, while a
        # dependent's candidate-set read now declines where it answered.
        def append_certainty_signature(parts, siblings)
          certainty = []
          siblings.each do |name, table|
            next if table.empty?

            if name == :possible_discovered_methods
              table.each do |class_name, row|
                row.each { |method_name, kind| certainty << "P:#{class_name}##{method_name}=#{kind}" }
              end
            else
              table.each { |path| certainty << "C:#{name}:#{path.inspect}" }
            end
          end
          parts.concat(certainty.sort)
        end

        # Issue #992 — the joined envelope table is a declaration surface the per-def signatures above cannot
        # reconstruct: they keep the LAST `def` of a name, and they see neither a second `def` with another
        # shape nor a `memoize :f` beside it, either of which moves a dependent's `call.wrong-arity` verdict.
        def append_envelope_signature(parts, envelopes)
          envelopes.sort_by { |cn, _| cn.to_s }.each do |class_name, entries|
            entries.map { |key, envelope| "a:#{class_name}#{key.inspect}=#{envelope.inspect}" }.sort.each do |part|
              parts << part
            end
          end
        end

        # Issue #644 — the cross-file VALUE-constant surface. Load-bearing for soundness, not precision: a
        # file's published constants are a declaration-level fact its file-level dependents consume, so
        # `FOO = :sym` becoming `FOO = :other` MUST move this signature or the reader would be declaration-
        # stable, dropped from the closure, and served the pre-edit `:sym`. Both halves are here: the write
        # NAMES (an added / removed / renamed assignment) and the published VALUES (a same-name value edit).
        def append_constant_signature(parts, file_index)
          parts.concat((file_index[:constant_writes] || {}).sort.map do |name, by_path|
            "k:#{name}=#{constant_descriptor_signature(by_path.values.first)}"
          end)
        end

        # `[literal]` renders its value, a `||=`-only name `||`, and an unpublishable write `?`. All three halves
        # matter: a write appearing or vanishing moves the signature, and so does the same name's value or
        # memo status changing.
        def constant_descriptor_signature(descriptor)
          return descriptor.first.inspect if descriptor.is_a?(Array)

          descriptor == CONSTANT_MEMO ? "||" : "?"
        end

        # The class-declaration + ancestry + member-layout surface of the declaration signature (declared class
        # names, superclass / include ancestry, Data/Struct member layouts). Kept out of
        # {#declaration_signature} to hold its ABC budget.
        def append_ancestry_signature(parts, file_index)
          parts.concat(file_index[:class_sources].keys.sort_by(&:to_s).map { |cn| "c:#{cn}" })
          parts.concat(sorted_by_class(file_index[:superclasses]).map { |cn, sc| "s:#{cn}<#{sc}" })
          append_mixin_signature(parts, file_index)
          parts.concat(sorted_by_class(file_index[:data_member_layouts]).map { |cn, l| "d:#{cn}=#{l.inspect}" })
          parts.concat(sorted_by_class(file_index[:struct_member_layouts]).map { |cn, l| "t:#{cn}=#{l.inspect}" })
        end

        # The mixin surface of {#append_ancestry_signature}. The lists keep SOURCE order: this is one file's own
        # index, so the order is deterministic, and it is a fact an ancestor-order reader consumes, so an edit
        # that only reorders an `include` must move the signature. The unpositioned table is there for the same
        # reason: guarding an `include` changes no name and no order, only whether the order is known.
        def append_mixin_signature(parts, file_index)
          { "i" => :includes, "p" => :prepends, "x" => :extends }.each do |tag, key|
            sorted_by_class(file_index[key] || {}).each { |cn, mods| parts << "#{tag}:#{cn}=#{Array(mods).join(',')}" }
          end
          sorted_by_class(file_index[:unpositioned_mixins] || {}).each do |cn, sides|
            sides.sort_by { |side, _| side.to_s }.each do |side, names|
              parts << "u:#{cn}.#{side}=#{names.sort.join(',')}"
            end
          end
        end

        # A class-keyed table's pairs sorted by class name (stringified) for a deterministic signature.
        def sorted_by_class(table)
          table.sort_by { |cn, _| cn.to_s }
        end

        # The method-existence and visibility surfaces of the declaration signature (kept out of
        # {#declaration_signature} to hold its ABC budget). Both are consumed cross-file — the existence table
        # by undefined-method suppression, the visibilities by the ADR-35 override-visibility rule.
        def append_declaration_tables(parts, file_index)
          file_index[:methods].sort_by { |cn, _| cn.to_s }.each do |cn, table|
            table.sort_by { |m, _| m.to_s }.each { |m, kind| parts << "e:#{cn}##{m}=#{kind}" }
          end
          file_index[:method_visibilities].sort_by { |cn, _| cn.to_s }.each do |cn, table|
            table.sort_by { |m, _| m.to_s }.each { |m, vis| parts << "v:#{cn}##{m}=#{vis}" }
          end
        end

        # Appends one def-node table's per-method signature entries (name + parameter structure + def-start
        # line) under `separator` (`#` instance / `.` singleton). Nodes here are always LIVE (both call sites —
        # {ScopeIndexer#scan_summary_for_paths} and {ScopeIndexer#build_seed_bundle} — pass a freshly parsed
        # single-file index), so the parameter structure and location are read directly.
        def append_def_signatures(parts, defs, separator)
          defs.sort_by { |cn, _| cn.to_s }.each do |class_name, methods|
            methods.sort_by { |m, _| m.to_s }.each do |method_name, node|
              parts << "m:#{class_name}#{separator}#{method_name}#{parameter_signature(node)}@#{def_start_line(node)}"
            end
          end
        end

        # ADR-89 WD1 — a compact, order-preserving descriptor of a def node's parameter STRUCTURE: each
        # parameter's kind (required / optional / rest / post / keyword-required / keyword-optional /
        # keyword-rest / block / forwarding) and name, plus default-PRESENCE (implied by the optional kinds).
        # Names are included for all parameter positions: soundness-first (a keyword-name change is Liskov-
        # visible to overriders; a positional-name change is rare and only over-conservatively keeps a
        # dependent). Not the inferred parameter TYPE — this gate is deliberately syntactic.
        def parameter_signature(node)
          return "()" unless node.respond_to?(:parameters)

          params = node.parameters
          return "()" if params.nil?

          parts = []
          parts.concat(labelled_params(params.requireds, "r"))
          parts.concat(labelled_params(params.optionals, "o"))
          parts.concat(labelled_params(params.posts, "p"))
          parts.concat(labelled_params(params.keywords) { |p| keyword_param_kind(p) })
          parts.concat(rest_param_parts(params))
          "(#{parts.join(',')})"
        end

        # The `<kind>:<name>` labels for a list of parameter nodes (nil → none). `kind` is a fixed String or a
        # block computing it per node (for the keyword-required / keyword-optional split).
        def labelled_params(nodes, kind = nil)
          (nodes || []).map { |p| "#{kind || yield(p)}:#{param_label(p)}" }
        end

        # The single rest / keyword-rest / block parameter labels (each present at most once).
        def rest_param_parts(params)
          parts = []
          parts << "*:#{param_label(params.rest)}" if params.rest
          parts << "**:#{param_label(params.keyword_rest)}" if params.keyword_rest
          parts << "&:#{param_label(params.block)}" if params.block
          parts
        end

        def keyword_param_kind(param)
          param.is_a?(Prism::OptionalKeywordParameterNode) ? "ko" : "kr"
        end

        # A parameter node's name, or a class-tagged sentinel for the nameless / destructuring forms
        # (`MultiTargetNode`, an anonymous `*` / `**` / `&`, `NoKeywordsParameterNode`, `ForwardingParameterNode`).
        def param_label(param)
          return "" if param.nil?

          param.respond_to?(:name) && param.name ? param.name.to_s : param.class.name.split("::").last
        end

        # The 1-based start line of a live def node (the `project_definition_site` an ADR-17 consumer embeds).
        def def_start_line(node)
          node.respond_to?(:location) ? node.location.start_line : 0
        end

        private_class_method :append_certainty_signature, :append_envelope_signature, :append_constant_signature,
                             :constant_descriptor_signature, :append_ancestry_signature, :append_mixin_signature,
                             :sorted_by_class, :append_declaration_tables, :append_def_signatures,
                             :parameter_signature, :labelled_params, :rest_param_parts, :keyword_param_kind,
                             :param_label, :def_start_line
      end
    end
  end
end
