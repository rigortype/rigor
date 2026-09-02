# frozen_string_literal: true

require "rigor/plugin"

require_relative "railties/effects"

module Rigor
  module Plugin
    # rigor-railties — the Rails **framework core**: its effect vocabulary, and the type of the four
    # `Rails.` singleton readers.
    #
    # It emits no diagnostic and declares no producer. What it contributes is the part of ADR-103's Rails
    # layer that belongs to no single component gem — `Rails.cache`, `Rails.logger`, `Rails.env`, the
    # application configuration and the credentials — plus the `rails` entry-point preset that
    # `effects.snapshot.reach:` adopts by name, plus the lenient nominals those same readers return
    # ({RAILS_SINGLETON_READER_TYPES}).
    #
    # ## Why it is its own plugin
    #
    # The rule ADR-103 WD10 works to is "the row lives in the plugin that owns the gem". `Rails.cache` and
    # `Rails.application` come from railties and activesupport, not from Action Pack or Active Record, and
    # putting them in whichever Rails plugin a project happened to enable would make a model's
    # `Rails.logger.info` visible or invisible depending on whether the app has controllers. A project that
    # wants the Rails effect vocabulary lists this plugin; a project that wants only Active Record's rows
    # does not.
    #
    # It is also the natural owner of the `rails` preset. A preset name may be registered once with one
    # glob set ({Rigor::Effects::EntryPoints.register}), and `rails` spans four directories owned by four
    # different component plugins — so exactly one plugin has to declare the union, and it is this one.
    # Each component plugin additionally declares its own narrower preset (`rails-controllers`,
    # `rails-jobs`, `rails-mailers`, `rails-channels`) for a project that wants a slice.
    #
    #     plugins:
    #       - gem: rigor-railties
    #
    #     effects:
    #       snapshot:
    #         reach: [rails]
    #       tolerated: [telemetry, rails.config.read]
    #
    # ## Cost when effects are off
    #
    # The manifest's effect fields are frozen arrays; nothing reads them unless the project has an
    # `effects:` block ({Rigor::Plugin::Registry#effect_contributions} is lazy). The reader typing costs one
    # `ContributionIndex` name-gate probe per dispatch of a method actually named `logger` / `cache` /
    # `configuration` / `application` (ADR-52 WD1 compiles the `methods:` gate into the registry), and the
    # block declines on the first check for anything whose receiver is not the `Rails` constant. Its one
    # type lookup ({#project_defined_rails?}) runs only after that syntactic gate passes, so it is confined
    # to `Rails.`-shaped sites.
    class Railties < Rigor::Plugin::Base
      manifest(
        id: "railties",
        # Bumped 2026-09-01 (#534 item 2) — the four `Rails.` singleton readers now return lenient
        # nominals instead of `Dynamic[top]`.
        version: "0.2.0",
        description: "The Rails framework-core effect vocabulary and singleton-reader types: cache, " \
                     "logger, environment, configuration, credentials, and the `rails` entry-point preset.",
        # ADR-103 WD2 — rigor-railties models Rails itself, so it opens the `rails.*` root. Granted only
        # because the engine bundles this plugin ({Rigor::Plugin::FirstParty}); the same declaration from a
        # third-party gem would open `railties.*` and earn a warning.
        effect_root: "rails",
        effect_labels: %w[rails.config.read rails.credentials.read],
        effect_attributions: Effects.attributions,
        effect_entry_points: Effects.entry_points
      )

      # Issue #534 item 2 — the four `Rails.` singleton readers, measured on the 2026-09-01 corpus sweep as
      # 261 opaque sites on mastodon alone (`configuration` 108, `cache` 81, `logger` 50, `application` 22).
      # Every one of them typed `Dynamic[top]`, so the whole `Rails.cache.fetch(...)` /
      # `Rails.application.config...` surface was unprotected.
      #
      # Each value is a **lenient nominal**: a real Rails class name for which Rigor ships NO RBS. That is
      # the same construction rigor-actionpack's `REQUEST_CONTEXT_READER_TYPES` uses, and it is chosen for
      # the same reason — the site becomes a *concrete* receiver (`coverage --protection` counts it, the
      # dispatch resolves against a named class) while the method surface stays engine-lenient, because
      # `call.undefined-method` and the argument / arity rules all bail at
      # `Rigor::Reflection.rbs_class_known?`. Shipping a partial RBS for any of these would invert that:
      # a declared class drops every member its RBS omits, and `Rails.logger.tagged { }` becomes a false
      # positive.
      #
      # ## Why these names, and why not `::Logger`
      #
      # - `logger` → **`ActiveSupport::BroadcastLogger`**, not `::Logger`. `::Logger` is the name the issue
      #   suggested and it is the one name here that must NOT be used: it is a stdlib class, so Rigor knows
      #   its RBS, so the leniency argument above evaporates and every ActiveSupport extension of the logger
      #   — `tagged`, `silence`, `broadcast_to`, `local_level=` — becomes `call.undefined-method` on working
      #   Rails code. Measured, not assumed (spec: "does not fire undefined-method on the ActiveSupport
      #   logger surface"). `BroadcastLogger` is what `Rails.logger` actually returns on Rails 7.1+, which
      #   is every Rails still supported; on 7.0 and earlier it was an `ActiveSupport::Logger`, and since
      #   both names are RBS-less the difference is invisible to every rule — the accurate modern name is
      #   preferred only so a project that later authors its own `sig/` for it gets the right class.
      # - `cache` → `ActiveSupport::Cache::Store`, the declared return of `Rails.cache` and the base class
      #   of every store implementation.
      # - `application` → `Rails::Application`, the singleton the railtie builds.
      # - `configuration` → `Rails::Application::Configuration`. This is the entry whose *leniency* matters
      #   most rather than its accuracy: `config.x_service_url` works through `method_missing` into
      #   `@custom`, so no RBS could ever be complete for it, and the RBS-less nominal is the only answer
      #   that types the receiver without claiming to know the members.
      #
      # ## The nil question
      #
      # All four are non-nil nominals, and a non-nil type licenses the flow rules to fold `if Rails.logger`
      # to always-truthy (the hazard that kept `Parameters#[]` out of rigor-actionpack's table, #578). The
      # difference is that here the non-nil claim is TRUE: inside a booted application — the only state in
      # which `app/` code runs — the railtie initializers have assigned all four, and `Rails.logger` is nil
      # only in a bare `require "rails"` process. The paired specs pin both halves: no `undefined-method` on
      # the extension surface, and no fold on a `Rails.cache.fetch { }` guard shape.
      RAILS_SINGLETON_READER_TYPES = {
        logger: "ActiveSupport::BroadcastLogger",
        cache: "ActiveSupport::Cache::Store",
        configuration: "Rails::Application::Configuration",
        application: "Rails::Application"
      }.freeze

      # `logger` / `cache` / `configuration` / `application` are ordinary method names that any project may
      # define on its own objects, so the receiver gate is syntactic and exact: the literal `Rails` constant,
      # bare or root-qualified (`::Rails`). A `receivers:` gate cannot express it — the `Rails` constant is
      # unresolved in a project with no Rails RBS, so the receiver type is `Dynamic` and
      # `dynamic_return_receiver_class_name` yields nil. The one thing the type side CAN see is the opposite
      # case — a `Rails` the project defines itself — and that is the second gate ({#project_defined_rails?}).
      dynamic_return methods: RAILS_SINGLETON_READER_TYPES.keys do |call_node, scope|
        next nil unless call_node.is_a?(Prism::CallNode)
        next nil unless call_node.arguments.nil? # `Rails.logger`, not `Rails.logger(x)`
        next nil unless call_node.block.nil?
        next nil unless rails_constant_receiver?(call_node.receiver)
        next nil if project_defined_rails?(call_node.receiver, scope)

        class_name = RAILS_SINGLETON_READER_TYPES[call_node.name]
        next nil if class_name.nil?

        Rigor::Type::Combinator.nominal_of(class_name)
      end

      # ADR-88 WD1 — the reader types are a static table, and the effect rows are built from the manifest;
      # nothing here scans a project file, so the plugin contributes no cross-file state and a project that
      # enables it stays incremental-capable.
      def incremental_state_fingerprint
        "static-rails-readers"
      end

      private

      # True for the `Rails` constant written as a receiver — `Rails.logger` (`ConstantReadNode`) and
      # `::Rails.logger` (a `ConstantPathNode` with no parent). A nested `Foo::Rails` is deliberately NOT
      # matched: it is a different constant, and matching it would type someone else's `logger`.
      def rails_constant_receiver?(receiver)
        case receiver
        when Prism::ConstantReadNode then receiver.name == :Rails
        when Prism::ConstantPathNode then receiver.parent.nil? && receiver.name == :Rails
        else false
        end
      end

      # #588 — the syntactic gate cannot tell the framework's `Rails` from a `module Rails` the project
      # declares itself: at top level, or lexically nested so that a bare `Rails` inside `module MyApp`
      # resolves to `MyApp::Rails`. Listing this plugin beside such a definition is a self-contradictory
      # configuration (activation is the `plugins:` list alone — no lockfile gate notices the framework is
      # absent), but the project's own definition is the honest answer for its own constant, and the engine
      # already has it: the receiver resolves to the `Singleton` of a discovered class. Declining hands the
      # call back to the project's `def self.logger`. Verified diagnostics-silent either way (the nominal is
      # RBS-less), so this is precision-honesty — the project's own answer surviving — not a false-positive
      # fix. The unresolved framework constant types `Dynamic` and passes through; an RBS-declared `Rails`
      # is not a project definition and keeps the contribution tier's ordinary precedence.
      def project_defined_rails?(receiver, scope)
        return false if scope.nil?

        receiver_type = scope.type_of(receiver)
        receiver_type.is_a?(Rigor::Type::Singleton) &&
          Rigor::Reflection.discovered_class?(receiver_type.class_name, scope: scope)
      end
    end

    Rigor::Plugin.register(Railties)
  end
end
