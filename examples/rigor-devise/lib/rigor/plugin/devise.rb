# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    # ADR-16 Tier B worked plugin: recognises Devise's model-side
    # `devise :strategy_a, :strategy_b` DSL on `ActiveRecord::Base`
    # subclasses and explodes each strategy's module RBS into the
    # calling class.
    #
    # Per the per-library survey (§ Devise), Devise's `devise(*modules)`
    # at `lib/devise/models.rb:79-112` is a **table-driven include
    # sequence**: each Symbol argument resolves through
    # `Devise::Models.const_get(m.to_s.classify)` to a concrete
    # `Devise::Models::*` module, which is then mixed into the
    # calling class. The substrate replays the same shape
    # statically — the manifest's `modules_by_symbol:` mirrors
    # Devise's `lib/devise/modules.rb` and the pre-pass scanner
    # synthesises one SyntheticMethod per (calling class, included
    # module instance method) pair into the SyntheticMethodIndex.
    #
    # ## Reach
    #
    # The full set of strategies Devise registers via
    # `Devise.add_module` at gem load (per `lib/devise/modules.rb`):
    #
    # - `:database_authenticatable` — password + email auth core
    # - `:recoverable` — password-reset flow
    # - `:rememberable` — persistent cookies
    # - `:registerable` — sign-up + account-edit flow
    # - `:trackable` — sign-in count / last-IP / last-at
    # - `:validatable` — email + password validations
    # - `:confirmable` — email confirmation flow
    # - `:lockable` — account-lock-after-failed-attempts
    # - `:timeoutable` — automatic logout after idle
    # - `:omniauthable` — OmniAuth providers
    # - `:authenticatable` — always-included base module
    #
    # The substrate's pre-pass scanner consults each module's RBS
    # via `Environment::RbsLoader#instance_definition` to enumerate
    # method names. A user project providing real Devise via
    # Bundler will see methods like `valid_password?`,
    # `send_reset_password_instructions`, etc. resolve through the
    # synthetic-method tier without `call.undefined-method`.
    #
    # ## Floor / ceiling per ADR-16 WD13
    #
    # Slice 3 ships at the **floor**: synthesised method names
    # emit and the dispatcher's `try_synthetic_method` tier
    # returns `Type::Combinator.untyped` (Dynamic[T]) for every
    # match. Per the slice-3 design judgment (1) the precision
    # promotion — looking up the module's authored RBS return
    # type at dispatch time — is **slice-6 ceiling work** and is
    # NOT a delivery commitment of slice 3c. The `origin_module:`
    # provenance field is recorded so the ceiling slice can
    # promote without rescanning.
    #
    # ## Scope (slice 3c minimum)
    #
    # - Recognises model-side `devise :a, :b` on any AR::Base
    #   subclass; trait symbol set mirrors `lib/devise/modules.rb`.
    # - `Devise::Models::Authenticatable` is always_included
    #   (matches Devise's `with_options model: true`).
    # - Unknown trait symbols silently skipped (per slice-3
    #   design judgment (2)). User initializers that call
    #   `Devise.add_module :my_strategy, ...` are NOT seen — that
    #   path requires a separate scanner for `config/initializers/`
    #   and is deferred.
    # - Controller-side helpers (`current_user`, `authenticate_user!`,
    #   etc.) are Tier C work, NOT Tier B; deferred to a future
    #   slice that consumes ADR-9 fact-store entries from a
    #   `rigor-rails-routes`-style walker.
    # - Per-strategy `ClassMethods` extend (Devise's `extend
    #   Mod::ClassMethods` pattern) is NOT yet wired — slice 3
    #   covers instance methods only per WD13 floor.
    class Devise < Rigor::Plugin::Base
      manifest(
        id: "devise",
        version: "0.1.0",
        description: "Recognises Devise's `devise :strategy` DSL via ADR-16 Tier B.",
        trait_registries: [
          Rigor::Plugin::Macro::TraitRegistry.new(
            receiver_constraint: "ActiveRecord::Base",
            method_name: :devise,
            symbol_arg_position: :rest,
            modules_by_symbol: {
              database_authenticatable: "Devise::Models::DatabaseAuthenticatable",
              recoverable: "Devise::Models::Recoverable",
              rememberable: "Devise::Models::Rememberable",
              registerable: "Devise::Models::Registerable",
              trackable: "Devise::Models::Trackable",
              validatable: "Devise::Models::Validatable",
              confirmable: "Devise::Models::Confirmable",
              lockable: "Devise::Models::Lockable",
              timeoutable: "Devise::Models::Timeoutable",
              omniauthable: "Devise::Models::Omniauthable",
              authenticatable: "Devise::Models::Authenticatable"
            },
            always_included: ["Devise::Models::Authenticatable"]
          )
        ]
      )
    end

    Rigor::Plugin.register(Devise)
  end
end
