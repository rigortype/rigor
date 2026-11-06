# ADR-129 G1' witness for :key_presence_walk. `call.possible-nil-receiver` is about to report on `r[:a] = 1`, whose
# receiver is a computed-key read of a closed Hash that a `key?` guard rules the miss `nil` out of, so the rule re-walks
# the file with the key-presence walk installed and the re-walk types the guarded read.
class Mapper
  MAP = { integer: { type: :integer }, string: { type: :string } }.freeze

  def by_local(prop)
    k = prop.column_type
    if MAP.key?(k)
      r = MAP[k].dup
      r[:a] = 1
    end
  end
end
