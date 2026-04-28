# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # An instance type for a Ruby class or module. The class is identified by
    # its fully-qualified Ruby name; the registry attached to the
    # environment owns the class lookup.
    #
    # See docs/type-specification/rbs-compatible-types.md.
    class Nominal
      attr_reader :class_name

      def initialize(class_name)
        raise ArgumentError, "class_name must be a String, got #{class_name.class}" unless class_name.is_a?(String)
        raise ArgumentError, "class_name must not be empty" if class_name.empty?

        @class_name = class_name.freeze
        freeze
      end

      def describe(_verbosity = :short)
        class_name
      end

      def erase_to_rbs
        class_name
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

      def ==(other)
        other.is_a?(Nominal) && class_name == other.class_name
      end
      alias eql? ==

      def hash
        [Nominal, class_name].hash
      end

      def inspect
        "#<Rigor::Type::Nominal #{class_name}>"
      end
    end
  end
end
