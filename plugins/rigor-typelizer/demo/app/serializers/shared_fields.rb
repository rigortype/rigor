# frozen_string_literal: true

# typelizer registers this module's own name and then calls `.descendants` on it, which a Module lacks, so it
# is not a serializer and neither is a class that merely includes it.
module SharedFields
  include Typelizer::DSL
end

class ModuleUser
  include SharedFields
end
