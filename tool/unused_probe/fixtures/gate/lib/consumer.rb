# frozen_string_literal: true

class Consumer
  def call
    UsedFromOtherFile.new.hello
  end
end
