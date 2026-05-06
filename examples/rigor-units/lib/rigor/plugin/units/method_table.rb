# frozen_string_literal: true

module Rigor
  module Plugin
    class Units < Rigor::Plugin::Base
      # Dispatch table mapping (receiver dimension, method name,
      # argument dimensions) tuples onto a result dimension or a
      # dimensional-mismatch error message. Pure data — the
      # {Analyzer} walks the AST and consults this module to
      # decide what each call site contributes to the local
      # binding map.
      #
      # Dimensions are kept as plain Symbols so the table reads
      # like a small physical-units cheatsheet. The set is
      # closed:
      #
      #   :numeric       — Integer / Float literal (no unit yet)
      #   :distance      — m / km / mi / ft
      #   :time          — s / min / h
      #   :speed         — distance / time
      #   :acceleration  — speed / time
      #   :bool          — comparison results
      #   :float         — `.in_*` terminal queries
      #   :string        — string literals (for `puts` arguments)
      module MethodTable
        Result = Struct.new(:dimension, :error, keyword_init: true)

        DISTANCE_UNIT_METHODS = %i[kilometers meters miles feet].freeze
        TIME_UNIT_METHODS = %i[seconds minutes hours].freeze

        DISTANCE_PER_TIME = %i[per_hour per_minute per_second].freeze
        DISTANCE_PER_TIME_SQUARED = %i[per_second_squared per_minute_squared per_hour_squared].freeze

        # Allowed `.in_<unit>` queries per receiver dimension.
        # Anything not listed here is a dimensional mismatch.
        IN_METHODS = {
          distance: %i[in_kilometers in_meters in_miles in_feet].freeze,
          time: %i[in_seconds in_minutes in_hours].freeze,
          speed: %i[in_kilometers_per_hour in_meters_per_second in_miles_per_hour].freeze,
          acceleration: %i[in_meters_per_second_squared in_kilometers_per_hour_squared].freeze
        }.freeze

        COMPARISON_OPS = %i[< > <= >= == !=].freeze

        DIMENSION_LABELS = {
          numeric: "Numeric",
          distance: "Distance",
          time: "Time",
          speed: "Speed",
          acceleration: "Acceleration",
          bool: "bool",
          float: "Float",
          string: "String"
        }.freeze

        module_function

        # @return [Result, nil]
        #   - `Result(dimension: <dim>, error: nil)` — recognised, well-typed.
        #   - `Result(dimension: nil, error: msg)` — recognised, dimensional mismatch.
        #   - `nil` — unrecognised; the analyzer should stay silent.
        def dispatch(receiver:, method:, args:)
          numeric = numeric_unit_constructor(receiver, method)
          return numeric if numeric

          chained = chained_unit_constructor(receiver, method)
          return chained if chained

          binop = arithmetic_or_comparison(receiver, method, args)
          return binop if binop

          query = in_query(receiver, method)
          return query if query

          nil
        end

        def label(dimension)
          DIMENSION_LABELS.fetch(dimension, dimension.to_s)
        end

        # Internal helpers below. Public-but-inside-the-module so
        # the analyzer-side specs can poke at them; not part of the
        # plugin's external API.

        def numeric_unit_constructor(receiver, method)
          return nil unless receiver == :numeric

          if DISTANCE_UNIT_METHODS.include?(method)
            Result.new(dimension: :distance)
          elsif TIME_UNIT_METHODS.include?(method)
            Result.new(dimension: :time)
          end
        end

        def chained_unit_constructor(receiver, method)
          return nil unless receiver == :distance

          if DISTANCE_PER_TIME.include?(method)
            Result.new(dimension: :speed)
          elsif DISTANCE_PER_TIME_SQUARED.include?(method)
            Result.new(dimension: :acceleration)
          end
        end

        def arithmetic_or_comparison(receiver, method, args)
          return nil if args.size != 1

          arg = args.first
          case method
          when :+, :- then additive(receiver, method, arg)
          when :* then multiplicative(receiver, method, arg)
          when :/ then divisive(receiver, method, arg)
          when *COMPARISON_OPS then comparison(receiver, method, arg)
          end
        end

        def additive(receiver, method, arg)
          return nil unless dimensional?(receiver) && dimensional?(arg)
          return Result.new(dimension: receiver) if receiver == arg

          Result.new(error: dimension_mismatch(receiver, method, arg))
        end

        def multiplicative(receiver, method, arg)
          return nil unless dimensional?(receiver) && dimensional?(arg)

          case [receiver, arg]
          when %i[acceleration time], %i[time acceleration] then Result.new(dimension: :speed)
          when %i[speed time], %i[time speed] then Result.new(dimension: :distance)
          else Result.new(error: dimension_mismatch(receiver, method, arg))
          end
        end

        def divisive(receiver, method, arg)
          return nil unless dimensional?(receiver) && dimensional?(arg)

          case [receiver, arg]
          when %i[distance time] then Result.new(dimension: :speed)
          when %i[speed time] then Result.new(dimension: :acceleration)
          else Result.new(error: dimension_mismatch(receiver, method, arg))
          end
        end

        def comparison(receiver, method, arg)
          return nil unless dimensional?(receiver) && dimensional?(arg)
          return Result.new(dimension: :bool) if receiver == arg

          Result.new(error: dimension_mismatch(receiver, method, arg))
        end

        def in_query(receiver, method)
          return nil unless method.to_s.start_with?("in_") && IN_METHODS.key?(receiver)

          if IN_METHODS.fetch(receiver).include?(method)
            Result.new(dimension: :float)
          else
            allowed = IN_METHODS.fetch(receiver).map { |m| ".#{m}" }.join(", ")
            Result.new(
              error: "#{label(receiver)} has no `.#{method}` query (allowed: #{allowed})"
            )
          end
        end

        def dimensional?(dimension)
          %i[distance time speed acceleration].include?(dimension)
        end

        def dimension_mismatch(receiver, method, arg)
          "dimensional mismatch: `#{label(receiver)} #{method} #{label(arg)}` is not defined"
        end
      end
    end
  end
end
