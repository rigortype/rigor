# frozen_string_literal: true

require "rigor/source/node_children"

require "prism"

module Rigor
  module Plugin
    class Hanami < Rigor::Plugin::Base
      # Checks the "presence" half of the Hanami::Action ADR-28 protocol contract.
      #
      # Every class defined in a file matching a contract's `path_glob` must declare `#handle(request,
      # response)`. The "provide" half — binding `Hanami::Action::Request` and `Hanami::Action::Response`
      # into the method body — is handled engine-side by `Inference::MethodParameterBinder`. Return type
      # is void so no conformance check is performed here.
      class ActionChecker
        FNMATCH_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

        def initialize(contracts:)
          @contracts = contracts
        end

        # Per-`ClassNode` check over the engine-owned walk (ADR-37): called once per class node the
        # `node_rule` in `hanami.rb` dispatches, against every contract whose `path_glob` matches the
        # file. No cross-class-node state is needed, so the checker ships no `class_nodes` traversal of
        # its own.
        def check_class(class_node, path:)
          @contracts.filter_map do |contract|
            next unless path_matches?(contract.path_glob, path)

            handle_def = find_handle(class_node, contract)
            if handle_def.nil?
              missing_handle_diagnostic(contract, path, class_node)
            else
              handle_arity_mismatch_diagnostic(contract, path, class_node, handle_def)
            end
          end
        end

        private

        # Contract globs are project-root-relative; the analyzer may supply a relative or absolute path,
        # so the glob is matched both directly and with a `**/`-prefixed suffix.
        def path_matches?(glob, path)
          return false if path.nil?

          File.fnmatch?(glob, path, FNMATCH_FLAGS) ||
            File.fnmatch?(File.join("**", glob), path, FNMATCH_FLAGS)
        end

        def find_handle(class_node, contract)
          direct_defs(class_node).find do |def_node|
            def_node.name == contract.method_name &&
              !def_node.receiver.is_a?(Prism::SelfNode)
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
          when Prism::ClassNode, Prism::ModuleNode then nil # nested scopes own their own defs
          else node.rigor_each_child { |child| collect_direct_defs(child, defs) }
          end
        end

        def handle_arity_mismatch_diagnostic(contract, path, class_node, def_node)
          req_count = def_node.parameters ? def_node.parameters.requireds.size : 0
          return nil if req_count == 2

          Rigor::Analysis::Diagnostic.from_location(
            def_node.location,
            path: path,
            message: "`#{class_name(class_node)}#handle` must accept exactly 2 parameters " \
                     "(request, response), got #{req_count}",
            severity: contract.severity,
            rule: "handle-arity-mismatch"
          )
        end

        def missing_handle_diagnostic(contract, path, class_node)
          Rigor::Analysis::Diagnostic.from_location(
            (class_node.constant_path || class_node).location,
            path: path,
            message: "`#{class_name(class_node)}` must define `#handle(request, response)` — " \
                     "required of every Hanami action under `#{contract.path_glob}`",
            severity: contract.severity,
            rule: "missing-handle-method"
          )
        end

        def class_name(class_node)
          path = class_node.constant_path
          path.respond_to?(:slice) ? path.slice : class_node.name.to_s
        end
      end
    end
  end
end
