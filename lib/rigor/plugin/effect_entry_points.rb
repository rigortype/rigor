# frozen_string_literal: true

module Rigor
  module Plugin
    # One entry of a plugin's `effect_entry_points:` — a **named** set of globs that
    # `effects.snapshot.reach:` may adopt by name (ADR-103 WD14).
    #
    # `reach:` is "whose transitive footprint does the snapshot record", and the honest answer for a Rails
    # app — controller actions, `perform`, mailer methods, channel methods — is a fact about the framework
    # rather than about the project. So the framework's plugin names it and the project adopts it:
    #
    #     effects:
    #       snapshot:
    #         reach: [rails]
    #
    # A preset is a **glob** set, matched against the project-relative file a method is defined in, with
    # the `rigor unused --entry-point` semantics {Rigor::Effects::EntryPoints} already implements. Globs
    # rather than a class-ancestry filter, deliberately: `reach:` is resolved from the snapshot's own
    # method table, which carries a defining path per key and no ancestry — and a Rails app's layout IS
    # the ancestry, which is why the convention exists at all.
    class EffectEntryPoints
      attr_reader :name, :globs, :why

      # @rbs name: String | Symbol --
      #   The token `reach:` adopts. Must satisfy {Rigor::Effects::EntryPoints::NAME_PATTERN}, checked at
      #   registration.
      # @rbs globs: Array[String] -- Project-relative path globs
      # @rbs why: String -- What the preset stands for, for the plugin's README and `rigor effects`' help
      def initialize(name:, globs:, why: "")
        @name = name.to_s.dup.freeze
        @globs = Array(globs).map { |glob| glob.to_s.dup.freeze }.uniq.sort.freeze
        raise ArgumentError, "effect entry-point preset #{@name.inspect} declares no globs" if @globs.empty?

        @why = why.to_s.dup.freeze
        freeze
      end

      def to_h
        { "name" => @name, "globs" => @globs }
      end

      def ==(other)
        other.is_a?(EffectEntryPoints) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end
    end
  end
end
