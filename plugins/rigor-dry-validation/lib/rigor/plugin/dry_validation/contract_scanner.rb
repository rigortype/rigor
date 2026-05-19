# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class DryValidation < Rigor::Plugin::Base
      # Walks project source for `class T < Dry::Validation::Contract`
      # subclasses and returns the contract class FQN set.
      #
      # Recognition tightness: the superclass match accepts EITHER
      # the fully-qualified `Dry::Validation::Contract` (3-segment
      # path) OR the lexical-nested `Validation::Contract`
      # (2-segment path, when the class body lives inside
      # `module Dry`). The bare `< Contract` form (1-segment)
      # is NOT recognised — too ambiguous; users who deeply nest
      # under `Dry::Validation` should use the explicit form.
      # Unrelated `< MyApp::Validation::Contract` shapes with the
      # same tail do NOT register.
      module ContractScanner
        CONTRACT_FULL_PATH = %w[Dry Validation Contract].freeze
        CONTRACT_LEXICAL_DRY_PATH = %w[Validation Contract].freeze
        private_constant :CONTRACT_FULL_PATH, :CONTRACT_LEXICAL_DRY_PATH

        module_function

        # @param paths [Array<String>] absolute paths to `.rb`
        #   files the project's `paths:` resolves to.
        # @return [Array<String>] frozen, sorted list of
        #   recognized contract class FQNs (e.g.
        #   `["App::NewUserContract", "Types::EmailContract"]`).
        def scan(paths:)
          contracts = []
          paths.each { |path| contracts.concat(scan_file(path)) }
          contracts.uniq.sort.freeze
        end

        def scan_file(path)
          source = File.read(path)
          parse_result = Prism.parse(source, filepath: path)
          return [] unless parse_result.errors.empty?

          collect_contracts(parse_result.value, [])
        rescue StandardError
          []
        end
        private_class_method :scan_file

        def collect_contracts(node, qualified_prefix)
          return [] if node.nil?

          case node
          when Prism::ClassNode then collect_class_node(node, qualified_prefix)
          when Prism::ModuleNode then collect_module_node(node, qualified_prefix)
          else
            node.compact_child_nodes.flat_map { |c| collect_contracts(c, qualified_prefix) }
          end
        end
        private_class_method :collect_contracts

        def collect_class_node(node, qualified_prefix)
          inner_name = constant_name_for(node.constant_path)
          return [] if inner_name.nil?

          new_prefix = qualified_prefix + [inner_name]
          inner = collect_contracts(node.body, new_prefix)
          inner += [new_prefix.join("::")] if contract_subclass?(node)
          inner
        end
        private_class_method :collect_class_node

        def collect_module_node(node, qualified_prefix)
          inner_name = constant_name_for(node.constant_path)
          return [] if inner_name.nil?

          collect_contracts(node.body, qualified_prefix + [inner_name])
        end
        private_class_method :collect_module_node

        # Matches superclasses whose constant chain is EXACTLY
        # `Dry::Validation::Contract` (full path) OR EXACTLY
        # `Validation::Contract` (lexical-Dry path). Other shapes
        # — including same-tail-but-different-root chains and
        # the ambiguous bare `Contract` — do not match.
        def contract_subclass?(class_node)
          superclass = class_node.superclass
          return false if superclass.nil?

          path = constant_path_segments(superclass)
          [CONTRACT_FULL_PATH, CONTRACT_LEXICAL_DRY_PATH].include?(path)
        end
        private_class_method :contract_subclass?

        def constant_path_segments(node)
          case node
          when Prism::ConstantReadNode then [node.name.to_s]
          when Prism::ConstantPathNode
            segments = []
            current = node
            while current.is_a?(Prism::ConstantPathNode)
              segments.unshift(current.name.to_s)
              current = current.parent
            end
            segments.unshift(current.name.to_s) if current.is_a?(Prism::ConstantReadNode)
            segments
          else
            []
          end
        end
        private_class_method :constant_path_segments

        def constant_name_for(node)
          segments = constant_path_segments(node)
          segments.empty? ? nil : segments.join("::")
        end
        private_class_method :constant_name_for
      end
    end
  end
end
