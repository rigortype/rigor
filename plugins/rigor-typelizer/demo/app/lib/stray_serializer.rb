# frozen_string_literal: true

# Outside the configured `dirs`: typelizer never loads this directory, so it is not rooted.
class StraySerializer
  include Typelizer::DSL
end
