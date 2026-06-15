# frozen_string_literal: true

module Rigor
  module Plugin
    class Sorbet < Rigor::Plugin::Base
      # Frozen description of one Sorbet `sig` block as parsed by
      # {SigParser}. Holds the return type, parameter shape, and
      # modifier list. Call-site argument-type checking and
      # override-compatibility validation are deferred; only the
      # return-type contribution is active.
      #
      # `kind` distinguishes `def foo` (`:instance`) from
      # `def self.foo` / `class << self; def foo; end`
      # (`:singleton`).
      #
      # `modifiers` records the `sig`-level flags observed:
      # `:abstract`, `:override`, `:overridable`, `:final`.
      # Currently stored but not acted on.
      MethodSignature = Data.define(
        :class_name, :method_name, :kind, :params, :return_type, :modifiers
      )
    end
  end
end
