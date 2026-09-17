# frozen_string_literal: true

module Probe
  # `Probe::AccountSerializer` resolves to `Account`, and `Account` answers every name it reads.
  # `Rigor.dump_type` prints what each `object` site then is; the plugin emits no diagnostic of its own.
  class AccountSerializer < ActiveModel::Serializer
    attributes :username

    def derived
      Rigor.dump_type(object)
      Rigor.dump_type(object.username)
    end
  end

  # No `Nothing` model exists, so the name resolves to nothing and the derivation declines.
  class NothingSerializer < ActiveModel::Serializer
    attributes :username

    def derived
      Rigor.dump_type(object)
    end
  end
end
