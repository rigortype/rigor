# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # An instance type for a Ruby class or module. The class is identified by
    # its fully-qualified Ruby name; the registry attached to the
    # environment owns the class lookup.
    #
    # Slice 4 phase 2d adds `type_args`: an ordered, frozen array of
    # `Rigor::Type` values that carry the receiver's generic
    # instantiation. The empty array is the canonical "raw" form
    # (`Nominal[Array]`); a non-empty array represents an applied
    # generic (`Nominal[Array, [Integer]]`). Two Nominals are
    # structurally equal only when their `class_name` AND `type_args`
    # match, so the raw form and any applied form are intentionally
    # distinct values. Acceptance routes treat the raw form leniently
    # for backward compatibility with phase 2b call sites that have not
    # yet learned to carry generics.
    #
    # Type arguments MUST be `Rigor::Type` instances. The constructor
    # freezes the array; callers MUST NOT mutate it after construction.
    #
    # See docs/type-specification/rbs-compatible-types.md.
    class Nominal
      attr_reader :class_name, :type_args

      def initialize(class_name, type_args = [])
        raise ArgumentError, "class_name must be a String, got #{class_name.class}" unless class_name.is_a?(String)
        raise ArgumentError, "class_name must not be empty" if class_name.empty?
        raise ArgumentError, "type_args must be an Array, got #{type_args.class}" unless type_args.is_a?(Array)

        @class_name = class_name.freeze
        @type_args = type_args.dup.freeze
        freeze
      end

      def describe(verbosity = :short)
        return class_name if type_args.empty?

        rendered = type_args.map { |t| t.describe(verbosity) }.join(", ")
        "#{class_name}[#{rendered}]"
      end

      def erase_to_rbs
        return class_name if type_args.empty?

        rendered = type_args.map(&:erase_to_rbs).join(", ")
        "#{class_name}[#{rendered}]"
      end

      def top
        Trinary.no
      end

      def bot
        Trinary.no
      end

      def dynamic
        Trinary.no
      end

      def accepts(other, mode: :gradual)
        Inference::Acceptance.accepts(self, other, mode: mode)
      end

      def ==(other)
        other.is_a?(Nominal) && class_name == other.class_name && type_args == other.type_args
      end
      alias eql? ==

      def hash
        [Nominal, class_name, type_args].hash
      end

      def inspect
        "#<Rigor::Type::Nominal #{describe(:short)}>"
      end
    end
  end
end
