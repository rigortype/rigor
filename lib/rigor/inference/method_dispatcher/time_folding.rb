# frozen_string_literal: true

require_relative "../../type"
require_relative "singleton_folding"

module Rigor
  module Inference
    module MethodDispatcher
      # Folds the zone-pinned `Time` class constructors on statically
      # known arguments.
      #
      # Only `Time.utc` / `Time.gm` are folded. They pin the result
      # to UTC, so the literal is machine-independent — every reader
      # (`year`, `hour`, `utc_offset`, `strftime`, …) yields the same
      # answer on any analysis host.
      #
      # `Time.now` (non-deterministic), `Time.at` / `Time.local` /
      # `Time.mktime` / `Time.new` (local-zone — the result's wall
      # clock and `utc_offset` depend on the analysis machine's
      # timezone) are deliberately NOT folded; they keep their
      # `Nominal[Time]` RBS answer. For the same reason `Time#getlocal`
      # is blocklisted in `TIME_CATALOG` so a folded `Constant[Time]`
      # cannot produce a machine-dependent local-zone copy.
      module TimeFolding
        TIME_UTC_METHODS = Set[:utc, :gm].freeze
        private_constant :TIME_UTC_METHODS

        # `Time.utc` accepts the 1–7 positional (year-first) form and
        # a 10-arg (sec-first) form; cap the arity so a malformed
        # call declines cheaply rather than reaching the constructor.
        MAX_TIME_ARITY = 10
        private_constant :MAX_TIME_ARITY

        module_function

        # @return [Rigor::Type, nil] folded result, or nil to defer.
        def try_dispatch(context)
          receiver = context.receiver
          method_name = context.method_name
          args = context.args
          return nil unless SingletonFolding.receiver?(receiver, "Time")
          return nil unless TIME_UTC_METHODS.include?(method_name)
          return nil unless args.size.between?(1, MAX_TIME_ARITY)
          return nil unless args.all?(Type::Constant)

          values = args.map(&:value)
          return nil unless values.all? { |v| v.is_a?(Integer) || v.is_a?(String) }

          Type::Combinator.constant_of(Time.utc(*values))
        rescue StandardError
          nil
        end
      end
    end
  end
end
