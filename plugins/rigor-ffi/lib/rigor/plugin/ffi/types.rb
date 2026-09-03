# frozen_string_literal: true

require "set"

module Rigor
  module Plugin
    class FFI < Base
      module Types
        # The 25 primitive type symbols supported by ffx and classic FFI
        FFX_PRIMITIVE_TYPES = %i[
          void
          int uint short ushort long ulong
          int8 int16 int32 int64
          uint8 uint16 uint32 uint64
          long_long ulong_long
          size_t
          float double
          bool
          char uchar
          string
          pointer
        ].to_set.freeze

        # Regex anchor must match end of string \z
        NOMINAL_OPAQUE_REGEX = Regexp.new("(_ptr|_handle|Ptr|Handle)\\z")

        module_function

        def nominal_opaque_pointer?(alias_name, exceptions: [])
          sym_str = alias_name.to_s
          return false if Array(exceptions).map(&:to_s).include?(sym_str)

          NOMINAL_OPAQUE_REGEX.match?(sym_str)
        end

        def camelize(name)
          name.to_s.split("_").map(&:capitalize).join
        end

        def return_type_for(type_sym, target: :ffi, module_name: nil, exceptions: [], typedefs: {}, callbacks: {})
          sym = type_sym.is_a?(Symbol) ? type_sym : type_sym.to_s.to_sym

          # Check if symbol is a defined callback
          if callbacks.key?(sym)
            return target == :ffx ? Rigor::Type::Combinator.nominal_of("Integer") : Rigor::Type::Combinator.nominal_of("FFI::Function")
          end

          if typedefs.key?(sym)
            underlying = typedefs[sym]
            if underlying == :pointer && nominal_opaque_pointer?(sym, exceptions: exceptions)
              nominal = camelize(sym)
              nominal = "#{module_name}::#{nominal}" if module_name && !module_name.empty?
              return Rigor::Type::Combinator.nominal_of(nominal)
            end
            sym = underlying
          end

          case sym
          when :void
            Rigor::Type::Combinator.void
          when :int, :uint, :short, :ushort, :long, :ulong,
               :int8, :int16, :int32, :int64,
               :uint8, :uint16, :uint32, :uint64,
               :long_long, :ulong_long, :size_t, :char, :uchar
            Rigor::Type::Combinator.nominal_of("Integer")
          when :float, :double
            Rigor::Type::Combinator.nominal_of("Float")
          when :bool
            Rigor::Type::Combinator.bool
          when :string
            Rigor::Type::Combinator.nominal_of("String")
          when :pointer
            if target == :ffx
              Rigor::Type::Combinator.nominal_of("Integer")
            else
              Rigor::Type::Combinator.nominal_of("FFI::Pointer")
            end
          else
            if nominal_opaque_pointer?(sym, exceptions: exceptions)
              nominal = camelize(sym)
              nominal = "#{module_name}::#{nominal}" if module_name && !module_name.empty?
              Rigor::Type::Combinator.nominal_of(nominal)
            else
              Rigor::Type::Combinator.top
            end
          end
        end

        # Universal parameter widening per WD7
        def param_type_for(type_sym, target: :ffi, module_name: nil, exceptions: [], typedefs: {}, callbacks: {})
          sym = type_sym.is_a?(Symbol) ? type_sym : type_sym.to_s.to_sym

          if callbacks.key?(sym)
            return Rigor::Type::Combinator.union_of(
              Rigor::Type::Combinator.nominal_of("Proc"),
              Rigor::Type::Combinator.nominal_of("Method"),
              Rigor::Type::Combinator.nominal_of("FFI::Pointer"),
              Rigor::Type::Combinator.nominal_of("FFI::Function"),
              Rigor::Type::Combinator.nil_type
            )
          end

          if typedefs.key?(sym)
            underlying = typedefs[sym]
            if underlying == :pointer && nominal_opaque_pointer?(sym, exceptions: exceptions)
              nominal = camelize(sym)
              nominal = "#{module_name}::#{nominal}" if module_name && !module_name.empty?
              return Rigor::Type::Combinator.union_of(
                Rigor::Type::Combinator.nominal_of(nominal),
                Rigor::Type::Combinator.nominal_of("FFI::Pointer"),
                Rigor::Type::Combinator.nil_type
              )
            end
            sym = underlying
          end

          case sym
          when :pointer
            if target == :ffx
              Rigor::Type::Combinator.union_of(
                Rigor::Type::Combinator.nominal_of("Integer"),
                Rigor::Type::Combinator.nil_type
              )
            else
              Rigor::Type::Combinator.union_of(
                Rigor::Type::Combinator.nominal_of("FFI::Pointer"),
                Rigor::Type::Combinator.nominal_of("FFI::MemoryPointer"),
                Rigor::Type::Combinator.nominal_of("FFI::AutoPointer"),
                Rigor::Type::Combinator.nominal_of("FFI::Buffer"),
                Rigor::Type::Combinator.nominal_of("Integer"),
                Rigor::Type::Combinator.nominal_of("String"),
                Rigor::Type::Combinator.nil_type
              )
            end
          when :int, :uint, :short, :ushort, :long, :ulong,
               :int8, :int16, :int32, :int64,
               :uint8, :uint16, :uint32, :uint64,
               :long_long, :ulong_long, :size_t, :char, :uchar
            Rigor::Type::Combinator.nominal_of("Integer")
          when :float, :double
            Rigor::Type::Combinator.union_of(
              Rigor::Type::Combinator.nominal_of("Float"),
              Rigor::Type::Combinator.nominal_of("Integer")
            )
          when :bool
            Rigor::Type::Combinator.bool
          when :string
            Rigor::Type::Combinator.nominal_of("String")
          else
            Rigor::Type::Combinator.top
          end
        end
      end
    end
  end
end
