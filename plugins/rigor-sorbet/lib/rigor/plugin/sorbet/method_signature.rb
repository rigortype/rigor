# frozen_string_literal: true

module Rigor
  module Plugin
    class Sorbet < Rigor::Plugin::Base
      # Frozen description of one Sorbet `sig` block as parsed by
      # {SigParser}. Holds enough to reconstruct the method's
      # call-site return type (slice 1's deliverable) plus the
      # parameter shape and modifier list (kept for slice 2+ when
      # we begin checking call-site argument types and override
      # compatibility).
      #
      # `kind` distinguishes `def foo` (`:instance`) from
      # `def self.foo` / `class << self; def foo; end`
      # (`:singleton`).
      #
      # `modifiers` is the set of `sig`-level modifiers we
      # observed: `:abstract`, `:override`, `:overridable`,
      # `:final`. Slice 1 records them but does not act on them;
      # later slices wire `:abstract` into the existing
      # `def.return-type-mismatch` check and `:override` into
      # override-compatibility validation.
      MethodSignature = Data.define(
        :class_name, :method_name, :kind, :params, :return_type, :modifiers
      )
    end
  end
end
