# frozen_string_literal: true

require "set"

module Rigor
  module Plugin
    class FFI < Base
      class FFICatalog
        attr_reader :functions, :libraries, :structs, :typedefs, :enums, :all_method_names

        def initialize(functions: {}, libraries: Set.new, structs: {}, typedefs: {}, enums: {})
          @functions = functions
          @libraries = libraries
          @structs = structs
          @typedefs = typedefs
          @enums = enums

          method_names = Set.new(functions.keys.map(&:to_sym))
          structs.each_value do |fields|
            fields.each_key do |f|
              method_names << f.to_sym
              method_names << :[]
              method_names << :[]=
            end
          end
          @all_method_names = method_names.freeze
        end

        def function_for(method_name)
          @functions[method_name.to_sym]
        end

        def struct_fields(struct_name)
          @structs[struct_name.to_s]
        end
      end
    end
  end
end
