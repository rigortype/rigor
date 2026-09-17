# frozen_string_literal: true

# rigor-active-model-serializers contributes one return type: the implicit-self `object` reader
# inside a discovered serializer. `Rigor.dump_type` prints what each site resolves to.
class ProbeSerializer < ActiveModel::Serializer
  def derived
    # No `Probe` model exists, so the derivation declines and `object` keeps `Dynamic[top]`.
    Rigor.dump_type(object)
  end
end

# Outside `app/serializers`, so the discoverer never indexed it — the `*Serializer` name-convention
# fallback is what admits it.
class AccountSerializer < ActiveModel::Serializer
  def derived
    Rigor.dump_type(object)
    Rigor.dump_type(object.username)
  end
end
