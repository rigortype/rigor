# frozen_string_literal: true

class RbsConsumer
  def make
    build
  end

  def build
    raise NotImplementedError
  end
end
