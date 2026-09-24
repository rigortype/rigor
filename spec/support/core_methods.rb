# frozen_string_literal: true

# The public instance methods a core class defines itself, for the drift guards that call every one of them (the
# `FrozenError` oracles in `string_mutation_widening_spec.rb` and `effects/hash_receiver_mutation_spec.rb`).
#
# `public_instance_methods(false)` alone answers for the whole process, so it also lists what a gem loaded by an
# earlier spec reopened the class with: `plugin/isolation_spec.rb` loads `active_support/inflector`, which adds
# `Hash#except!`, `#extract!` and `#slice!`, and the Hash oracle then failed or passed with the spec order. A core
# method is written in C (no `source_location`) or in a builtin `<internal:…>` file; a gem's has a real path.
module CoreMethods
  module_function

  def public_instance_methods(klass)
    klass.public_instance_methods(false).select do |name|
      location = klass.instance_method(name).source_location
      location.nil? || location.first.start_with?("<internal:")
    end
  end
end
