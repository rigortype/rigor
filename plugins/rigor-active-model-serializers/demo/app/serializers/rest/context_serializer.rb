# frozen_string_literal: true

module REST
  # `REST::ContextSerializer` names a JSON shape, not a model: nothing in the project corroborates a
  # `Context` class, so `object` DECLINES and keeps the answer the engine would have given it.
  class ContextSerializer < ActiveModel::Serializer
    attributes :ancestors, :descendants

    def ancestors
      object.ancestors
    end
  end
end
