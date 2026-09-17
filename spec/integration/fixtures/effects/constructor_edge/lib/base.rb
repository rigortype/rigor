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

# A class built at load time whose constructor lives in the block — the scan files that `def` under the
# enclosing namespace and cannot attribute it to `Sticky` at all. The reopening in `constructors.rb`
# spells a superclass, and must not turn this into a readable ancestry.
ConstructorEdge::Sticky = Class.new(ConstructorEdge::BaseWriter) do
  def initialize(path)
    File.write(path, "sticky")
  end
end
