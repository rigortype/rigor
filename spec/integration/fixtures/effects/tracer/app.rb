# frozen_string_literal: true

# Fixture app for the ADR-103 effect-labels tracer slice (#379). Every method here exists to exercise
# one recorded shape: a catalogued origin, a transitive edge, a converging recursion, a taint cause, a
# language construct, an ownership classification, or a synthesised accessor.
module Tracer
  class Reporter
    attr_reader :label

    def initialize(label)
      @label = label
    end

    # Two catalogue rows in one body: `Kernel#puts` and `Time.now`.
    def report
      puts("#{label} at #{Time.now}")
    end

    # Transitive: nothing of its own, everything of `report`'s.
    def announce
      report
    end

    # A converging cycle — the fixpoint must terminate and give both methods the same reading.
    def ping
      pong
    end

    def pong
      ping
    end

    # A language construct rather than a catalogue row.
    def shell
      `echo tracer`
    end

    # `$gvar` write.
    def flag
      $tracer_flag = true
    end

    # A local the frame allocates and never lets out: `mutate.local`, tolerated by every envelope.
    def collect
      buffer = []
      buffer << label
      buffer.length
    end

    # A `define_method` with a literal name is a unit of its own, keyed `Tracer::Reporter#generated`.
    define_method(:generated) do
      warn("generated")
    end
  end

  # One method per taint cause the tracer slice can produce.
  class Gateway
    def initialize(client)
      @client = client
    end

    # The receiver's type is unknown, so the callee is unknown: `dynamic-receiver`.
    def fetch
      @client.get("/health")
    end

    # The same cause, reached through an untyped parameter, which carries a {DynamicOrigin} name as the
    # taint's detail.
    def probe(client)
      client.get("/health")
    end

    # A computed selector: `dynamic-send`.
    def dispatch(name)
      @client.public_send(name)
    end

    # A callable the analyzer cannot follow to a body: `opaque-callable`.
    def run_callback
      @callback.call(1)
    end

    # An implicit-self call the closed world has no definition for: `unresolved-self-call`.
    def missing_helper
      no_such_helper
    end

    def build
      []
    end

    # The receiver is fresh at run time but the collector cannot prove it: `unknown-ownership`, never a
    # proven `mutate`.
    def unowned
      row = build
      row << 1
      row.length
    end

    # A parameter's contents are the caller's to observe: `mutate.instance`, proven from the syntax of the
    # write even though the receiver's type is unknown — and tainted alongside it, because what else the
    # call does is not known.
    def append(target)
      target[0] = 1
    end
  end
end
