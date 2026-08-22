# Three shapes of `save` on one page, because the difference between them is the whole of #440.
#
# `User` (the file next door) never writes `def save`: its row is synthesised entirely from the class body's
# callbacks and its uniqueness validator, and for a long time that row said the validator's SELECT and
# nothing else — "save does not write to the database", on a model whose `save` writes.
class Audit < ApplicationRecord
  before_save :stamp
  before_destroy :stamp

  def stamp
    @stamped = true
  end
end

# An override that delegates upward. Whatever the framework does on `save`, this still does.
class WrappedAudit < ApplicationRecord
  before_save :stamp

  def save
    super
  end

  def stamp
    @stamped = true
  end
end

# An override that REPLACES the framework's implementation and never reaches `super`. This one really does
# not touch the database, and the report must keep saying so — the fix for #440 must not paint the write
# onto every row that carries the name.
class RefusedAudit < ApplicationRecord
  before_save :stamp

  def save
    false
  end

  def stamp
    @stamped = true
  end
end
