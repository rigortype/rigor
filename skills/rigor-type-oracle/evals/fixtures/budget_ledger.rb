# frozen_string_literal: true

module Demo
  class BudgetLedger
    def initialize(currency, opening_balance: 0)
      @currency = currency
      @entries = []
      @opening_balance = opening_balance
    end

    def record(amount, memo: nil, at: Time.now)
      raise ArgumentError, "amount must be non-zero" if amount.zero?

      @entries << [amount, memo, at]
      self
    end

    def balance(as_of: nil)
      scoped = as_of ? @entries.select { |(_, _, at)| at <= as_of } : @entries
      @opening_balance + scoped.sum { |(amount, _, _)| amount }
    end

    def overdrawn?(as_of: nil) = balance(as_of: as_of).negative?

    def entries_matching(pattern)
      return [] if pattern.nil?

      @entries.select { |(_, memo, _)| memo&.match?(pattern) }
    end
  end
end
