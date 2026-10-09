# frozen_string_literal: true

require "rbs"

module Rigor
  class Environment
    # Issue #1700 — the type names a {RequiredFeatures}-gated vendored directory declares, which
    # `RbsLoader.gated_trouble` builds in its trial to decide whether the directory may stay in an environment.
    # Read off the vendored files themselves: a nested `class Prime; class EratosthenesGenerator` names
    # `Prime::EratosthenesGenerator`, and a reopened core class (`class Integer`) is named too, since a clash
    # there fails `Integer`'s own definition.
    module GatedSignatureGuard
      module_function

      # @param dir — the vendored directory (Pathname).
      # @return the absolute-less names (`"Prime::PseudoPrimeGenerator"`) of every class and module it declares.
      def type_names(dir)
        Dir.glob(File.join(dir.to_s, "*.rbs")).flat_map do |file|
          _, _, decls = RBS::Parser.parse_signature(File.read(file))
          names(decls, nil)
        rescue RBS::BaseError, SystemCallError
          []
        end.uniq
      end

      def names(decls, namespace)
        decls.flat_map do |decl|
          next [] unless decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)

          name = qualify(namespace, decl.name)
          [name] + names(decl.members, name)
        end
      end

      def qualify(namespace, type_name)
        text = type_name.to_s
        return text.delete_prefix("::") if text.start_with?("::") || namespace.nil?

        "#{namespace}::#{text}"
      end
    end
  end
end
