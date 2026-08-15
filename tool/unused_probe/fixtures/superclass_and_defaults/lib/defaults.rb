# frozen_string_literal: true

class Defaults
  SAME_FILE_DEFAULT = "x"
  SAME_FILE_BODY = "y"

  def initialize(root = SAME_FILE_DEFAULT)
    @root = root
  end

  def body = SAME_FILE_BODY
end
