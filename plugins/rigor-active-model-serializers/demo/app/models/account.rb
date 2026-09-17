# frozen_string_literal: true

class Account < ApplicationRecord
  # Not a column. The derivation accepts it because the project defines it here — without that half of
  # the check, almost every real serializer would be declined over a method like this one.
  def acct
    username
  end
end
