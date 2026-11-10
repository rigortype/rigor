# frozen_string_literal: true

module Courier
  Parcel = Struct.new(:id, :weight)

  class Chain
  end

  class Client
    # Sends the parcel to the carrier.
    #
    # Returns the tracking number, or nil when the carrier rejects the parcel.
    def deliver(parcel)
      return nil unless carrier_accepts?(parcel)

      "TRK-#{parcel.id}"
    end

    # Queues a parcel for delivery.
    def dispatch(parcel)
      deliver(parcel)
    end

    # Yields the middleware chain for configuration and returns it.
    def middleware
      @middleware ||= Chain.new
      yield @middleware if block_given?
      @middleware
    end

    def label(parcel)
      "Parcel #{parcel.id}"
    end

    private

    def carrier_accepts?(parcel)
      parcel.weight < 30
    end
  end
end
