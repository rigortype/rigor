# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    # rigor-grape — recognises the Grape endpoint-declaration DSL (`class API < Grape::API`) and the
    # grape-entity exposure DSL (`class E < Grape::Entity`) so the calls stop reading `Dynamic[top]`
    # (issue #1099; gitlab's `lib/api` accounted for ~10k opaque implicit-self sends in the
    # 2026-09-19 survey — `expose` ~3.9k, `optional` ~2.2k, `route_setting` ~1.5k, `desc` ~1.4k,
    # `requires` ~1.4k).
    #
    # Grape is more dynamic than the frameworks the ADR-16 substrate was built for:
    #
    # - `Grape::API` subclasses have NO static class methods — every declaration call is forwarded
    #   to the base `Grape::API::Instance` class object at runtime (`delegate_missing_to` +
    #   `override_all_methods!`, `lib/grape/api.rb`). The bundled sig declares the shared surface
    #   once in `Grape::DSL::ClassMethods` and `extend`s it onto both `Grape::API` (reached from
    #   source subclasses via `rbs_complete_ancestors`, ADR-43 WD4) and `Grape::API::Instance`
    #   (reached inside `namespace` bodies, whose `self` is the Instance class object).
    # - Block `self` bindings differ per macro family — `params` bodies `instance_eval` on a
    #   `Grape::Validations::ParamsScope` instance, `namespace`/`route_param`/`version`/`given`/
    #   `mounted` bodies on the Instance class object, and verb bodies run as `Grape::Endpoint`
    #   instance methods. `block_as_methods` entries carry a named `self_type` ("Foo" /
    #   "singleton(Foo)") so each body binds the object Grape actually evaluates it on.
    # - `Grape::Entity`'s `expose` bodies run via `block.call` — `self` stays the Entity class
    #   object — so nested `expose` calls need no entry; the `def self.` declarations cover them.
    #
    # ## Deferred (documented in README)
    #
    # - `helpers do ... end` bodies (`class_eval` on an anonymous Module — unnamed self).
    # - `desc ... do ... end` nested documentation DSL (DescContainer's own surface).
    # - Typing `present`/`declared` results against the declared entity/params (runtime shape).
    class Grape < Rigor::Plugin::Base
      # `namespace`-family bodies evaluate as instance methods of the Instance *class object*
      # (`Instance.nest` / `evaluate_as_instance_with_configuration` do `instance_eval(&block)`).
      NAMESPACE_METHODS = %i[namespace group resource resources segment route_param version given mounted].freeze
      # HTTP verb macros are generated over `Grape::HTTP_SUPPORTED_METHODS` and delegate to `route`;
      # their bodies run inside `Grape::Endpoint` instances.
      VERB_METHODS = %i[get put post delete head patch options route].freeze
      # `params` bodies evaluate on a `ParamsScope` instance; the block-carrying scope macros re-enter
      # a child scope the same way.
      PARAMS_SCOPE_METHODS = %i[requires optional given with].freeze

      manifest(
        id: "grape",
        target_gems: %w[grape grape-entity],
        version: "0.1.0",
        description: "Types the Grape endpoint-declaration DSL (`Grape::API` subclasses: `params`, " \
                     "`namespace`, HTTP verb macros, `desc`, `route_setting`, `helpers`) and the " \
                     "grape-entity exposure DSL (`Grape::Entity` subclasses: `expose`), including " \
                     "the `instance_eval`'d block `self` bindings.",
        signature_paths: ["sig"],
        # ADR-43 WD4 — `Grape::API`/`Grape::Entity` subclasses bridge their class-level DSL calls to
        # the bundled sig's `def self.` declarations. Justified because the bundled sig IS the
        # authority (neither gem ships RBS) and the declared surface is what the DSL exposes.
        rbs_complete_ancestors: %w[
          Grape::API
          Grape::Entity
        ],
        # All five classes have genuinely open runtime surfaces (`override_all_methods!` generates
        # and forwards methods on API subclasses; ParamsScope/Endpoint pick up DSL modules) — calls
        # we don't declare must stay opaque, not diagnosed.
        open_receivers: %w[
          Grape::API
          Grape::API::Instance
          Grape::Entity
          Grape::Validations::ParamsScope
          Grape::Endpoint
        ],
        block_as_methods: [
          # Class-body context: `class API < Grape::API; namespace :x do ... end`.
          Rigor::Plugin::Macro::BlockAsMethod.new(
            receiver_constraint: "Grape::API",
            method_names: NAMESPACE_METHODS,
            self_type: "singleton(Grape::API::Instance)"
          ),
          # Inside an already-narrowed namespace body (self is the Instance class object), nested
          # `namespace`/`version`/`given` calls re-enter the same context.
          Rigor::Plugin::Macro::BlockAsMethod.new(
            receiver_constraint: "Grape::API::Instance",
            method_names: NAMESPACE_METHODS,
            self_type: "singleton(Grape::API::Instance)"
          ),
          # `params do ... end` — body `instance_eval`s on a `ParamsScope` instance.
          Rigor::Plugin::Macro::BlockAsMethod.new(
            receiver_constraint: "Grape::API",
            method_names: %i[params],
            self_type: "Grape::Validations::ParamsScope"
          ),
          Rigor::Plugin::Macro::BlockAsMethod.new(
            receiver_constraint: "Grape::API::Instance",
            method_names: %i[params],
            self_type: "Grape::Validations::ParamsScope"
          ),
          # `requires :x, type: Hash do ... end` inside a params body re-enters a child ParamsScope —
          # the receiver is already the `Nominal[ParamsScope]` `self` of the enclosing body, which is
          # what named-instance `self_type` entries additionally match.
          Rigor::Plugin::Macro::BlockAsMethod.new(
            receiver_constraint: "Grape::Validations::ParamsScope",
            method_names: PARAMS_SCOPE_METHODS,
            self_type: "Grape::Validations::ParamsScope"
          ),
          # Verb bodies run inside `Grape::Endpoint` instances.
          Rigor::Plugin::Macro::BlockAsMethod.new(
            receiver_constraint: "Grape::API",
            method_names: VERB_METHODS,
            self_type: "Grape::Endpoint"
          ),
          Rigor::Plugin::Macro::BlockAsMethod.new(
            receiver_constraint: "Grape::API::Instance",
            method_names: VERB_METHODS,
            self_type: "Grape::Endpoint"
          )
        ]
      )
    end

    Rigor::Plugin.register(Grape)
  end
end
