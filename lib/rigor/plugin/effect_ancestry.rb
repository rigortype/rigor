# frozen_string_literal: true

require_relative "effect_attribution"

module Rigor
  module Plugin
    # One entry of a plugin's `effect_ancestry:` — an ancestry edge the plugin's own gem introduces and
    # the project's source never writes down (ADR-103 WD17; [#465](https://github.com/rigortype/rigor/issues/465)).
    #
    # `Effects::PluginFacts` walks the project's own `class … <` and `include` lines and nothing else,
    # deliberately: reading the RBS ancestor chain instead would make a row's reach a function of whether
    # anyone happened to run `rbs prototype`. The cost is that a chain which leaves project source never
    # comes back. `class UserMailer < Devise::Mailer` is the measured case — `Devise::Mailer <
    # ActionMailer::Base` is a line in the devise gem, so `rigor-actionmailer`'s rows stop one step short
    # of every mailer a Devise application writes, and the five `Auth::*Controller < Devise::*Controller`
    # subclasses beside it are entry points.
    #
    # A plugin that models a gem knows that gem's own inheritance. Declaring it here keeps the rule that
    # Rigor reads *declarations* rather than RBS: the declaration simply comes from the plugin instead of
    # from project source.
    #
    # ## What a claim may say
    #
    # `parent:` need only be a **true ancestor**, not the immediate superclass. The sole use of the
    # ancestry is to make a row reachable, and no plugin row is ever keyed on a project class, so
    # skipping intermediate links loses nothing — while insisting on the immediate parent would force a
    # claim that is sometimes false: `Devise::SessionsController`'s real parent is `DeviseController`,
    # whose own parent is `Devise.parent_controller` and therefore configurable per project. A claim that
    # skips links MUST say so in its `why:`.
    #
    # ## Who may make one
    #
    # Bundled plugins only ({Rigor::Plugin::FirstParty}), enforced in `PluginFacts`. An ancestry claim
    # carries no labels of its own, so it looks harmless — but it makes *other* plugins' rows reachable,
    # and a third-party plugin asserting `Foo < ActiveRecord::Base` would pull rigor-activerecord's
    # first-party discharging rows onto `Foo`. The `effect_root:` demotion and the `discharge:` grant
    # both answer their own version of that question the same way.
    class EffectAncestry
      attr_reader :child, :parent, :why

      def initialize(child:, parent:, why:)
        @child = validate_class_name!(child, "child")
        @parent = validate_class_name!(parent, "parent")
        @why = validate_why!(why)
        freeze
      end

      def to_h
        { "child" => @child, "parent" => @parent }
      end

      def ==(other)
        other.is_a?(EffectAncestry) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end

      private

      def validate_class_name!(value, role)
        name = value.to_s
        unless EffectAttribution::CLASS_NAME.match?(name)
          raise ArgumentError, "effect ancestry #{role} must be a class name, got #{value.inspect}"
        end

        name.dup.freeze
      end

      def validate_why!(why)
        value = why.to_s
        raise ArgumentError, "effect ancestry #{@child} < #{@parent} needs a `why:` justification" if value.empty?

        value.dup.freeze
      end
    end
  end
end
