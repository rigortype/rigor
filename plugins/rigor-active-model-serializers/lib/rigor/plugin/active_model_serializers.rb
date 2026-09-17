# frozen_string_literal: true

require "rigor/plugin"

require_relative "active_model_serializers/serializer_index"
require_relative "active_model_serializers/serializer_discoverer"

module Rigor
  module Plugin
    # rigor-active-model-serializers — types the implicit-self `object` reader inside a serializer as the
    # model the serializer serializes.
    #
    # It emits no diagnostic. What it contributes is one return type and the gem's own framework
    # constants, and both exist for the same measurement: the 2026-09-01 corpus opacity sweep (#534
    # item 6) found `object` to be Mastodon's single largest unresolved implicit-self send — 751 sites in
    # `app/serializers` alone — with no plugin owning ActiveModelSerializers at all. Every
    # `object.account.username` chain below one of those sites was dispatching on `Dynamic[top]`.
    #
    #     plugins:
    #       - gem: rigor-active-model-serializers
    #         config:
    #           serializer_search_paths: ["app/serializers"]           # default; optional
    #           serializer_base_classes: ["ActiveModel::Serializer"]   # default; optional
    #           model_overrides: {}                                    # default; optional
    #
    # ## What `object` types to, and when it declines
    #
    # AMS's `object` is `ActiveModel::Serializer#object`, the resource the serializer was constructed
    # with. Nothing in a serializer's source states that resource's class — AMS binds it at `new` time —
    # so the type is only ever DERIVED, and the plugin types the reader only where the derivation is
    # corroborated by something outside the serializer:
    #
    # 1. `model_overrides` names the model for this serializer. The project asserted it; it wins.
    # 2. The `<Model>Serializer` naming convention resolves against a model `rigor-activerecord`
    #    discovered — `REST::AccountSerializer` → `Account`, because `Account` is in the project's
    #    `:model_index` fact.
    #
    # Anything else DECLINES, and `object` keeps whatever the engine would have given it (`Dynamic`). A
    # serializer for a Struct, a presenter, a `ActiveModelSerializers::Model`, or a resource the naming
    # convention mis-guesses therefore gets no answer rather than a wrong one — which is the whole
    # difference between this plugin and a rule that types `object` as some open `Object`-ish nominal.
    # A wrong nominal here would be maximally expensive: `object.foo` on a closed class is
    # `call.undefined-method` on working code, on the busiest send in the corpus.
    #
    # The model index is CONSULTED rather than trusted for the shape of the answer: the contributed type
    # is `Nominal[Account]`, and Active Record's own column / association surface reaches it through
    # `rigor-activerecord`'s existing typing of that nominal, not through anything declared here.
    #
    # ## Why `self` has to be a discovered serializer
    #
    # The naming convention alone would type `object` inside any class whose name happens to end with
    # `Serializer`. {SerializerDiscoverer} closes the `class X < Y` graph under the scanned paths from
    # `ActiveModel::Serializer` downwards, so the gate is ancestry, with the name convention kept as a
    # fallback for a serializer outside `serializer_search_paths` — the same shape, and the same
    # FP argument, as `rigor-actionpack`'s `controller_scope?`: typing a reader is precision-additive, so
    # a serializer the scan missed costing a name check is cheaper than a serializer that goes untyped.
    #
    # ## Scope
    #
    # - **SimpleForm inputs are NOT handled.** The sweep's 875-site `object` count mixes AMS serializers
    #   with `SimpleForm::Inputs::Base#object`, a different gem with a different resource story
    #   (`object` there is the form's record, named by the `simple_form_for` call site, not by the input
    #   class). That belongs in a `rigor-simple-form` plugin and is deliberately left out.
    # - **`serializer:` / `each_serializer:` options are not read.** `has_many :emojis, serializer:
    #   REST::CustomEmojiSerializer` states which serializer renders an association, never which model a
    #   serializer serializes, so it cannot ground `object`.
    # - **No association or attribute validation.** `attributes :id, :username` looks like a surface
    #   worth checking against the model's columns, and is not checked here: AMS resolves an attribute
    #   name against a method on the serializer OR a method on the object, so a name absent from both the
    #   serializer's `def`s and the model's columns is still not provably wrong.
    class ActiveModelSerializers < Rigor::Plugin::Base
      manifest(
        id: "active-model-serializers",
        target_gems: ["active_model_serializers"],
        version: "0.1.0",
        description: "Types the implicit-self `object` reader inside ActiveModel::Serializer subclasses " \
                     "as the serializer's model, and declares the gem's framework constants.",
        config_schema: {
          "serializer_search_paths" => { kind: :array, default: ["app/serializers"] },
          "serializer_base_classes" => { kind: :array, default: ["ActiveModel::Serializer"] },
          # Serializer class name => model class name, for the resources the naming convention cannot
          # reach: a serializer named for a JSON shape rather than a model (`REST::ContextSerializer`), or
          # one whose model lives under a different constant. An override is the project's own assertion
          # and is NOT re-checked against the model index — a project that names a non-model here gets a
          # nominal Rigor has no RBS for, which stays lenient.
          "model_overrides" => { kind: :hash, default: {} }
        },
        # Optional on purpose: without `rigor-activerecord` the naming-convention arm has nothing to
        # corroborate against and every non-overridden serializer declines. That is the designed
        # degradation — the plugin contributes less, never something wrong.
        consumes: [{ plugin_id: "activerecord", name: :model_index, optional: true }],
        # ADR-25 (#534 item 7, same admission rule as `rigor-activerecord`'s `sig/active_record/
        # framework.rbs`) — the gem's own constants, declared so they resolve and asserting nothing else.
        signature_paths: ["sig"],
        # ADR-26 — every class the bundled signature names is open. `ActiveModel::Serializer` is the one
        # that matters: a project's serializers inherit from it, and it is declared with an empty body, so
        # the whole AMS instance surface (`object`, `scope`, `serialization_scope`, `read_attribute_for_
        # serialization`, the `_attributes` class state) must stay lenient rather than becoming
        # `call.undefined-method` on a working serializer.
        open_receivers: [
          "ActiveModel::Serializer",
          "ActiveModel::Serializer::CollectionSerializer",
          "ActiveModelSerializers::Model",
          "ActiveModelSerializers::SerializableResource"
        ]
      )

      producer :serializer_index, watch: -> { [[@serializer_search_paths, "**/*.rb"]] } do |_params|
        SerializerDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @serializer_search_paths,
          base_classes: @serializer_base_classes
        ).discover
      end

      def init(_services)
        @serializer_search_paths = Array(config.fetch("serializer_search_paths")).map(&:to_s)
        @serializer_base_classes = Array(config.fetch("serializer_base_classes")).map(&:to_s)
        @model_overrides = config.fetch("model_overrides").to_h { |k, v| [k.to_s.delete_prefix("::"), v.to_s] }
      end

      # The `methods:` gate keeps this off every dispatch whose name is not `object`; the receiver and
      # argument checks keep it off `foo.object` and `object(x)`, neither of which is the AMS reader.
      dynamic_return methods: [:object] do |call_node, scope|
        next nil unless call_node.is_a?(Prism::CallNode)
        next nil unless call_node.receiver.nil?
        next nil unless call_node.arguments.nil?

        serializer_name = serializer_scope_name(scope)
        next nil if serializer_name.nil?

        model_name = model_class_name_for(serializer_name)
        next nil if model_name.nil?

        Rigor::Type::Combinator.nominal_of(model_name)
      end

      private

      # The enclosing class's name when `self` is a serializer, else nil. Both spellings of `self_type`
      # answer the same name — an instance method body and a class body differ in whether the type is a
      # singleton, and `object` is legitimately read from either (a class-body `if:` lambda runs against
      # the instance).
      def serializer_scope_name(scope)
        self_type = scope&.self_type
        return nil unless self_type.respond_to?(:class_name)

        name = self_type.class_name&.delete_prefix("::")
        return nil if name.nil? || name.empty?

        index = producer_value(:serializer_index)
        return name if index&.known?(name)

        name.end_with?("Serializer") ? name : nil
      end

      # The model a serializer serializes, or nil where nothing corroborates a guess.
      def model_class_name_for(serializer_name)
        override = @model_overrides[serializer_name]
        return override unless override.nil? || override.empty?

        # The published `:model_index` fact is a Hash keyed by the model's DE-ROOTED constant path (#583);
        # only the key set is read here, never a row's columns. `rigor-activerecord` withholds the fact
        # entirely in reduced mode (no `db/schema.rb` / `db/structure.sql`), so a schema-less project
        # declines here rather than typing `object` off a name alone.
        index = read_fact(plugin_id: "activerecord", name: :model_index)
        return nil if index.nil? || index.empty?

        convention_candidates(serializer_name).find { |candidate| index.key?(candidate) }
      end

      # `REST::AccountSerializer` offers two readings — the namespaced `REST::Account` and the
      # demodulized `Account` — and Rails apps use both (`Admin::AccountSerializer` for `Admin::Account`
      # is as real as Mastodon's `REST::AccountSerializer` for `Account`). Both are offered to the model
      # index and the first it RECOGNISES wins, so the index, not the spelling, decides. A base
      # serializer named exactly `Serializer` (`ActivityPub::Serializer`) strips to an empty remainder
      # and offers nothing.
      def convention_candidates(serializer_name)
        return [] unless serializer_name.end_with?("Serializer")
        # A class named exactly `Serializer` is a namespace's base serializer, never a model's.
        return [] if serializer_name.split("::").last == "Serializer"

        stripped = serializer_name.delete_suffix("Serializer").delete_suffix("::")
        return [] if stripped.empty?

        [stripped, stripped.split("::").last].uniq.reject(&:empty?)
      end
    end

    Rigor::Plugin.register(ActiveModelSerializers)
  end
end
