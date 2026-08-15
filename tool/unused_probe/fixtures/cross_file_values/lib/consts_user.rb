# frozen_string_literal: true

module Holder
  # Same constant namespace, DIFFERENT file: a bare-name read.
  def self.read_bare_cross_file
    CROSS_FILE_USED
  end
end

Holder.read_same_file
Holder.read_bare_cross_file
Holder::CROSS_FILE_USED
