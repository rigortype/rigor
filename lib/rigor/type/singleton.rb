# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # The singleton type for a Ruby class or module. Inhabitants are the
    # class object itself (e.g. the constant `Foo`), not its instances.
    # In RBS this corresponds to `singleton(Foo)`.
    #
    # `Singleton[Foo]` and `Nominal[Foo]` share the same `class_name` but
    # are NEVER equal; they describe disjoint values (the class object vs.
    # instances of the class).
    #
    # See docs/type-specification/rbs-compatible-types.md (singleton(T)).
    class Singleton
      attr_reader :class_name

      def initialize(class_name)
        raise ArgumentError, "class_name must be a String, got #{class_name.class}" unless class_name.is_a?(String)
        raise ArgumentError, "class_name must not be empty" if class_name.empty?

        @class_name = class_name.freeze
        freeze
      end

      def describe(_verbosity = :short)
        "singleton(#{class_name})"
      end

      def erase_to_rbs
        "singleton(#{class_name})"
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
        other.is_a?(Singleton) && class_name == other.class_name
      end
      alias eql? ==

      def hash
        [Singleton, class_name].hash
      end

      def inspect
        "#<Rigor::Type::Singleton #{class_name}>"
      end
    end
  end
end
