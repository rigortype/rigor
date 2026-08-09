# frozen_string_literal: true

module Rigor
  module Type
    # #319 — the spelling of a class that Ruby created without a name: the `Class.new do ... end` /
    # `Module.new do ... end` form away from constant-write position, which owns whatever its block body defines
    # but has no constant to be keyed by.
    #
    # `Inference::AnonymousMetaClass` decides WHICH call sites get one and what goes in the key; this module owns
    # the spelling, because the two places a name reaches a human live here. `#<Label:key>` is deliberately
    # unspellable as a Ruby constant path, so a synthetic name can never collide with a real class in the
    # discovery tables.
    #
    # Both renderings drop the key. `describe` keeps only the label (`#<Class>`) because the key is a file
    # position — reproducing it would pin every `assert_type` fixture and precision snapshot to a line number.
    # `erase_to_rbs` answers `untyped`: the name is not valid RBS, and emitting it from `rigor sig-gen` would
    # produce a signature file that does not parse.
    module AnonymousClassName
      module_function

      PREFIX = "#<"

      # `build("Class", "lib/a.rb:3:17") #=> "#<Class:lib/a.rb:3:17>"`
      def build(label, key)
        "#{PREFIX}#{label}:#{key}>"
      end

      def match?(class_name)
        class_name.is_a?(String) && class_name.start_with?(PREFIX)
      end

      # The display form: the label alone, key dropped.
      def display(class_name)
        return class_name unless match?(class_name)

        "#{PREFIX}#{class_name.delete_prefix(PREFIX).split(':', 2).first}>"
      end
    end
  end
end
