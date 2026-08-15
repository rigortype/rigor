# frozen_string_literal: true

module Holder
  SAME_FILE_USED = 1
  CROSS_FILE_USED = 2
  NEVER_USED = 3

  def self.read_same_file
    SAME_FILE_USED
  end
end
