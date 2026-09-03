# frozen_string_literal: true

module Rigor
  module Plugin
    class FFI < Base
      class FFICatalog
        attr_reader :functions,
                    :functions_by_receiver,
                    :libraries,
                    :structs,
                    :typedefs,
                    :enums,
                    :callbacks,
                    :function_method_names,
                    :struct_field_names,
                    :struct_names,
                    :all_receiver_names,
                    :all_method_names

        def initialize(functions: {}, functions_by_receiver: {}, libraries: Set.new, structs: {}, typedefs: {}, enums: {}, callbacks: {})
          @functions = functions
          @functions_by_receiver = functions_by_receiver
          @libraries = libraries
          @structs = structs
          @typedefs = typedefs
          @enums = enums
          @callbacks = callbacks

          @function_method_names = Set.new(functions.keys.map(&:to_sym)).freeze

          field_names = Set.new
          structs.each_value do |fields|
            fields.each_key do |f|
              field_names << f.to_sym
            end
          end
          field_names << :[]
          field_names << :[]=
          @struct_field_names = field_names.freeze
          @struct_names = structs.keys.freeze

          @all_receiver_names = (libraries.to_a + structs.keys).freeze
          @all_method_names = (@function_method_names + @struct_field_names).freeze
        end

        def function_for(receiver_name, method_name)
          if receiver_name
            scoped = @functions_by_receiver[[receiver_name.to_s, method_name.to_sym]]
            return scoped if scoped
          end

          # Fallback if receiver matches any registered library
          return unless receiver_name.nil? || @libraries.include?(receiver_name.to_s)

          @functions[method_name.to_sym]&.first
        end

        def struct_fields(struct_name)
          @structs[struct_name.to_s]
        end
      end
    end
  end
end
