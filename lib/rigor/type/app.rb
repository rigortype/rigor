# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # A defunctionalised higher-kinded type application — the abstract
    # "apply type-constructor `uri` to argument list `args`" carrier.
    #
    # `uri` is a namespaced `Symbol` of the form `:author::name`
    # (e.g. `:"json::value"`, `:"dry_monads::result"`); the `::`
    # namespace separator is mandatory per ADR-20 WD1 to prevent
    # cross-plugin tag collisions.
    #
    # `args` is an ordered, frozen `Array` of `Rigor::Type` values
    # carrying the application's argument list. At least one argument
    # is required; arity-zero "HKT" forms are not modelled by this
    # carrier (use a plain type alias instead).
    #
    # `bound` is a `Rigor::Type` representing the value Rigor MUST
    # erase to when this `App` cannot be reduced — registered at
    # `%a{rigor:v1:hkt_register}` time, defaulting to
    # `Rigor::Type::Dynamic[Rigor::Type::Top]` per ADR-20 D5 / WD2. It
    # also drives the lattice probes (`top` / `bot` / `dynamic`) and
    # the acceptance fallback while no reduction is wired (Slice 1).
    #
    # Slice 1 ships the carrier as **opaque**: every operation
    # delegates to `bound` since no reduction surface exists yet. Slice
    # 2 introduces the conditional / indexed-access evaluator that
    # reduces `App` to its registered body before delegating; the
    # carrier shape stays identical.
    #
    # Display form per ADR-20 OQ5: bare RBS-style `uri[arg1, arg2]`,
    # not the wrapped `App[uri, [arg1, arg2]]` faithful form. Two
    # `App` values are structurally equal iff their `uri`, `args`,
    # AND `bound` match.
    #
    # See docs/adr/20-lightweight-hkt.md.
    class App
      URI_SEPARATOR = "::"

      attr_reader :uri, :args, :bound

      def initialize(uri, args, bound:)
        raise ArgumentError, "uri must be a Symbol, got #{uri.class}" unless uri.is_a?(Symbol)
        unless uri.to_s.include?(URI_SEPARATOR)
          raise ArgumentError,
                "uri must be namespaced as `:author#{URI_SEPARATOR}name` per ADR-20 WD1, got #{uri.inspect}"
        end
        raise ArgumentError, "args must be an Array, got #{args.class}" unless args.is_a?(Array)
        raise ArgumentError, "args must be non-empty (use a plain type alias for arity-0 forms)" if args.empty?
        raise ArgumentError, "bound must be a Rigor type, got #{bound.class}" if bound.nil?

        @uri = uri
        @args = args.dup.freeze
        @bound = bound
        freeze
      end

      def describe(verbosity = :short)
        rendered = args.map { |t| t.describe(verbosity) }.join(", ")
        "#{uri}[#{rendered}]"
      end

      def erase_to_rbs
        bound.erase_to_rbs
      end

      def top
        bound.top
      end

      def bot
        bound.bot
      end

      def dynamic
        bound.dynamic
      end

      def accepts(other, mode: :gradual)
        Inference::Acceptance.accepts(bound, other, mode: mode)
      end

      def ==(other)
        other.is_a?(App) && uri == other.uri && args == other.args && bound == other.bound
      end
      alias eql? ==

      def hash
        [App, uri, args, bound].hash
      end

      def inspect
        "#<Rigor::Type::App #{describe(:short)} (bound=#{bound.describe(:short)})>"
      end
    end
  end
end
