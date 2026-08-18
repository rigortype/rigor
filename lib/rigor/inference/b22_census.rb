# frozen_string_literal: true

module Rigor
  module Inference
    # Throwaway measurement harness for issue #389 (the B2.2 ivar-reset skip). Inert unless
    # `RIGOR_B22_CENSUS` names an output file. Records one row per reset EVENT — an intervening
    # implicit-self / self-receiver call that actually widened at least one narrowed ivar back to its
    # seed — as `class<TAB>selector<TAB>line<TAB>count`, so the rows can be joined offline against
    # `rigor effects --format json --full` to estimate how many of those resets an effect summary
    # would let the analyzer skip.
    #
    # Sequential runs only (`parallel: {workers: 0}`): a forked worker's counters die with `exit!`.
    module B22Census
      PATH = ENV.fetch("RIGOR_B22_CENSUS", nil)

      @events = Hash.new(0)

      class << self
        def active?
          !PATH.nil?
        end

        # The headroom experiment: with `RIGOR_B22_DISABLE=1` the reset does not happen at all, so a
        # diagnostic diff against a normal run is the WHOLE consumer's upper bound — every criterion
        # #389 could ever use is a subset of "never reset".
        DISABLED = !ENV["RIGOR_B22_DISABLE"].nil?

        def disabled?
          DISABLED
        end

        def record(class_name, selector, line)
          @events["#{class_name}\t#{selector}\t#{line}"] += 1
        end

        def dump
          return if PATH.nil?

          File.open(PATH, "a") do |io|
            @events.each { |key, count| io.puts("#{key}\t#{count}") }
          end
        end
      end
    end
  end
end

at_exit { Rigor::Inference::B22Census.dump } if Rigor::Inference::B22Census.active?
