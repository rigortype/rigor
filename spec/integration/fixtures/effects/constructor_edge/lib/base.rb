# frozen_string_literal: true

# The ancestors, in a file of their own: `Const.new` is resolved against the MERGED project ancestry, so an
# `#initialize` inherited from another file is the shape that matters.
module ConstructorEdge
  class BaseWriter
    def initialize(path)
      @path = path
      File.write(path, "opened")
    end
  end
end
