# frozen_string_literal: true

require "rigor/source/node_children"

require "prism"

module Rigor
  module Plugin
    class Web < Rigor::Plugin::Base
      # The "check" half of the ADR-28 provide-and-check pair.
      #
      # Walks one analysed file's AST and, for every class defined
      # in a file matching a contract's `path_glob`, confirms:
      #
      # 1. the class defines the contracted method, and
      # 2. that method's inferred return type conforms to the
      #    contract's `return_type_name`.
      #
      # The "provide" half — binding the contract's parameter types into the method body — happens engine-side in
      # `Inference::MethodParameterBinder` before this checker runs. The checker re-binds the same parameter types onto
      # its own query scope so `Scope#type_of` types the body identically to the engine's own per-file inference.
      class ProtocolChecker
        FNMATCH_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

        def initialize(contracts:)
          @contracts = contracts
        end

        # Per-`ClassNode` check over the engine-owned walk (ADR-37):
        # called once per class node the `node_rule` in `web.rb` dispatches, checking it against every contract whose
        # `path_glob` matches the file. No cross-class-node state is needed, so the checker ships no `class_nodes`
        # traversal of its own.
        def check_class(class_node, path:, scope:)
          @contracts.flat_map do |contract|
            next [] unless path_matches?(contract.path_glob, path)

            diagnostics_for_class(contract, path, scope, class_node)
          end
        end

        private

        # Contract globs are authored project-root-relative; the analyzer may pass a relative or an absolute path, so
        # the glob is matched directly and as a `**/`-prefixed suffix.
        def path_matches?(glob, path)
          return false if path.nil?

          File.fnmatch?(glob, path, FNMATCH_FLAGS) ||
            File.fnmatch?(File.join("**", glob), path, FNMATCH_FLAGS)
        end

        def diagnostics_for_class(contract, path, scope, class_node)
          def_node = target_def(class_node, contract)
          if def_node.nil?
            [missing_method_diagnostic(contract, path, class_node)]
          else
            Array(return_type_diagnostic(contract, path, scope, def_node))
          end
        end

        # The contracted method, defined directly in `class_node`'s body (not in a nested class / module).
        def target_def(class_node, contract)
          direct_defs(class_node).find do |def_node|
            def_node.name == contract.method_name &&
              singleton_def?(def_node) == contract.singleton
          end
        end

        def direct_defs(class_node)
          defs = []
          collect_direct_defs(class_node.body, defs)
          defs
        end

        def collect_direct_defs(node, defs)
          return if node.nil?

          case node
          when Prism::DefNode then defs << node
          when Prism::ClassNode, Prism::ModuleNode then nil # a nested scope owns its own defs
          else node.rigor_each_child { |child| collect_direct_defs(child, defs) }
          end
        end

        def singleton_def?(def_node)
          def_node.receiver.is_a?(Prism::SelfNode)
        end

        def missing_method_diagnostic(contract, path, class_node)
          kind = contract.singleton ? "singleton method" : "instance method"
          location = (class_node.constant_path || class_node).location
          Rigor::Analysis::Diagnostic.from_location(
            location,
            path: path,
            severity: contract.severity,
            rule: "missing-protocol-method",
            message: "`#{class_name(class_node)}` must define #{kind} `#{contract.method_name}` — " \
                     "required of every class under `#{contract.path_glob}`"
          )
        end

        # Compares the inferred return type of the contracted method against the contract's declared return type. Stays
        # silent when the protocol's RBS is not loaded (return type unresolvable) or when inference cannot pin the body
        # type down (`Dynamic[Top]`) — the plugin defers to runtime rather than frighten code that may be correct.
        def return_type_diagnostic(contract, path, scope, def_node)
          return nil if contract.return_type_name.nil?

          last_expr = body_last_expression(def_node.body)
          return nil if last_expr.nil?

          return_type = nominal_for(scope, contract.return_type_name)
          return nil if return_type.nil?

          inferred = bind_contract_params(contract, scope, def_node).type_of(last_expr)
          return nil if inconclusive?(inferred)
          return nil unless return_type.accepts(inferred).no?

          location = def_node.name_loc || def_node.location
          Rigor::Analysis::Diagnostic.from_location(
            location,
            path: path,
            severity: contract.severity,
            rule: "protocol-return-mismatch",
            message: "`#{def_node.name}` must return a #{contract.return_type_name} — " \
                     "inferred #{inferred.describe(:short)}"
          )
        end

        # Re-binds the contract's parameter types onto the query scope so `type_of` analyses the body with the same
        # parameter knowledge the engine's binder used.
        def bind_contract_params(contract, scope, def_node)
          contract.param_types.reduce(scope) do |acc, param_type|
            name = positional_param_name(def_node, param_type.index)
            next acc if name.nil?

            resolved = nominal_for(scope, param_type.type_name)
            next acc if resolved.nil?

            acc.with_local(name, resolved)
          end
        end

        def positional_param_name(def_node, index)
          params = def_node.parameters
          return nil if params.nil?

          node = params.requireds[index] || params.optionals[index]
          return nil unless node.respond_to?(:name)

          node.name
        end

        def nominal_for(scope, type_name)
          environment = scope.environment
          return nil if environment.nil?

          environment.nominal_for_name(type_name)
        end

        def inconclusive?(type)
          type.is_a?(Rigor::Type::Dynamic) || (type.respond_to?(:top?) && type.top?.yes?)
        end

        # The implicit-return expression of a method body.
        def body_last_expression(body)
          case body
          when nil then nil
          when Prism::StatementsNode then body.body.last
          when Prism::BeginNode then body_last_expression(body.statements)
          else body
          end
        end

        def class_name(class_node)
          path = class_node.constant_path
          path.respond_to?(:slice) ? path.slice : class_node.name.to_s
        end
      end
    end
  end
end
