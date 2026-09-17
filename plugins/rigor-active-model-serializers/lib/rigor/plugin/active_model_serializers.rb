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
    #           serializer_search_paths: ["app/serializers", "app/lib"]  # default; optional
    #           serializer_base_classes: ["ActiveModel::Serializer"]     # default; optional
    #           model_overrides: {}                                      # default; optional
    #
    # ## What `object` types to, and when it declines
    #
    # AMS's `object` is `ActiveModel::Serializer#object`, the resource the serializer was constructed
    # with. Nothing in a serializer's source STATES that resource's class — AMS binds it at `new` time —
    # so the type is only ever derived, and two independent things have to agree before it is:
    #
    # 1. The `<Model>Serializer` naming convention resolves to exactly one model `rigor-activerecord`
    #    discovered (`REST::AccountSerializer` → `Account`), and
    # 2. that model ANSWERS the serializer: every name the serializer will read off its resource — the
    #    `attributes` / `has_many` / `has_one` declarations it does not define itself, plus every
    #    `object.<name>` in its body — is a column, association, enum, alias or scope of that model, or a
    #    method the project defines on it.
    #
    # A `model_overrides` entry short-circuits both: the project asserted the answer. Anything else
    # DECLINES, and `object` keeps whatever the engine would have given it (`Dynamic`).
    #
    # ## Why the name alone is not enough
    #
    # The name is a guess and the model index only proves the guessed class EXISTS, never that this
    # serializer serializes it. Mastodon has three serializers where the guess is wrong and the class is
    # real: `REST::ConversationSerializer` serializes an `AccountConversation` (its `unread`,
    # `participant_accounts` and `last_status` are all absent from `Conversation`), and both
    # `REST::InstanceSerializer` and `REST::V1::InstanceSerializer` serialize an `InstancePresenter`
    # (`object.contact`, `object.thumbnail`). A corpus diff cannot see the damage, because an Active
    # Record model's surface is open and a wrong-but-real model absorbs every read in silence — so the
    # check has to be a positive one, made before the answer is contributed.
    #
    # Requiring EVERY name to be answered, rather than most of them, is the same choice: a serializer
    # whose resource is a decorator around the model shares most of the model's surface, and it is
    # exactly the one or two extra names that say so.
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
    # - **A serializer with no declarations and no `object` reads gets no answer.** There is nothing to
    #   check the name against, and the name alone is what this refuses to trust.
    class ActiveModelSerializers < Rigor::Plugin::Base
      manifest(
        id: "active-model-serializers",
        target_gems: ["active_model_serializers"],
        version: "0.1.0",
        description: "Types the implicit-self `object` reader inside ActiveModel::Serializer subclasses " \
                     "as the serializer's model, and declares the gem's framework constants.",
        config_schema: {
          # `app/lib` is in the default set because a project base serializer routinely lives outside
          # `app/serializers` — Mastodon's `ActivityPub::Serializer`, the parent of 60 of its 153
          # serializers, is at `app/lib/activitypub/serializer.rb`. Without it the ancestry closure stops
          # at the base class and two fifths of the project's serializers are simply not serializers as
          # far as this plugin is concerned. A directory the project does not have costs one probe.
          "serializer_search_paths" => { kind: :array, default: ["app/serializers", "app/lib"] },
          "serializer_base_classes" => { kind: :array, default: ["ActiveModel::Serializer"] },
          # Serializer class name => model class name, for the resources the derivation cannot reach: a
          # serializer whose resource is a presenter or a decorator, or one named for a JSON shape rather
          # than a model. An override is the project's own assertion and is NOT re-checked — a project
          # that names a class Rigor has no RBS for gets a lenient nominal.
          "model_overrides" => { kind: :hash, default: {} }
        },
        # Optional on purpose: without `rigor-activerecord` there is no model set to check a name
        # against, and every non-overridden serializer declines. That is the designed degradation — the
        # plugin contributes less, never something wrong.
        consumes: [{ plugin_id: "activerecord", name: :model_index, optional: true }],
        # ADR-25 (#534 item 7, same admission rule as `rigor-activerecord`'s `sig/active_record/
        # framework.rbs`) — the gem's own constants, declared so they resolve and asserting nothing else.
        signature_paths: ["sig"],
        # ADR-26 — every class and module the bundled signature names is open, so that declaring it buys
        # constant resolution and asserts nothing about a member. `ActiveModel::Serializer` is the row
        # that matters most (a project's serializers inherit from it, and its whole instance surface —
        # `object`, `scope`, `read_attribute_for_serialization`, the `_attributes` class state — is
        # unenumerated), and `ActiveModelSerializers` / `::Adapter` are the ones the canonical
        # initializer dispatches on: `ActiveModelSerializers.config.adapter = :json_api` and
        # `ActiveModelSerializers::Adapter.register(...)` are what an AMS `config/initializers` file says.
        open_receivers: [
          "ActiveModel::Serializer",
          "ActiveModel::Serializer::CollectionSerializer",
          "ActiveModelSerializers",
          "ActiveModelSerializers::Adapter",
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
        @derivations = {}
      end

      # The `methods:` gate keeps this off every dispatch whose name is not `object`; the receiver and
      # argument checks keep it off `foo.object` and `object(x)`, neither of which is the AMS reader.
      dynamic_return methods: [:object] do |call_node, scope|
        next nil unless call_node.is_a?(Prism::CallNode)
        next nil unless call_node.receiver.nil?
        next nil unless call_node.arguments.nil?

        entry = serializer_entry(scope)
        next nil if entry.nil?
        # An explicit `def object`, here or on an ancestor, is the definition that runs. Answering over
        # it would replace a type the engine derived from real source with a guess, and silence whatever
        # that source proves.
        next nil if entry.defines_object? || project_defines_object?(entry.class_name, scope)

        model_name = model_class_name_for(entry, scope)
        next nil if model_name.nil?

        Rigor::Type::Combinator.nominal_of(model_name)
      end

      private

      # The discovered serializer whose body `self` is in, or nil. Membership of the index is the only
      # gate: a `*Serializer` name is not evidence of anything, since `object` is an ordinary method name
      # that a `Json::ConversationSerializer` or an `Oj::AccountSerializer` may define for itself.
      def serializer_entry(scope)
        self_type = scope&.self_type
        return nil unless self_type.respond_to?(:class_name)

        name = self_type.class_name
        return nil if name.nil? || name.empty?

        producer_value(:serializer_index)&.find(name)
      end

      def project_defines_object?(serializer_name, scope)
        return false unless scope.respond_to?(:user_def_through_ancestors)

        !scope.user_def_through_ancestors(serializer_name, :object).first.nil?
      end

      # The model a serializer serializes, or nil where nothing corroborates it. Memoised per serializer
      # class INCLUDING the nil answer: the ancestor walks behind `project_defines?` are run once per
      # name per serializer, and `object` is read hundreds of times across a real `app/serializers`.
      def model_class_name_for(entry, scope)
        return @derivations[entry.class_name] if @derivations.key?(entry.class_name)

        @derivations[entry.class_name] = derive_model_class_name(entry, scope)
      end

      def derive_model_class_name(entry, scope)
        override = @model_overrides[entry.class_name]
        return override unless override.nil? || override.empty?

        # The published `:model_index` fact is a Hash keyed by the model's DE-ROOTED constant path
        # (#583). `rigor-activerecord` withholds it entirely in reduced mode (no `db/schema.rb` /
        # `db/structure.sql`), so a schema-less project declines here rather than typing `object` off a
        # name alone.
        index = read_fact(plugin_id: "activerecord", name: :model_index)
        return nil if index.nil? || index.empty?

        resolved = convention_candidates(entry.class_name).select { |candidate| index.key?(candidate) }
        # Two readings that both name a real model (`Admin::AccountSerializer` where `Admin::Account` and
        # `Account` both exist) is an ambiguity, not a first-hit: nothing here ranks one above the other.
        return nil unless resolved.size == 1

        model = resolved.first
        answers?(entry, index.fetch(model), model, scope) ? model : nil
      end

      # Whether the model ANSWERS the serializer — see the class comment for why this is required and why
      # it is required of every name rather than most of them. A serializer that reads nothing off its
      # resource states nothing to check, and is declined for that reason rather than admitted for it.
      def answers?(entry, row, model_name, scope)
        required = entry.required_names
        return false if required.empty?

        members = model_members(row)
        required.all? do |name|
          members.include?(name) || project_defines?(model_name, name, scope)
        end
      end

      # Every name the model answers that its `:model_index` row states. The `?` forms are Active
      # Record's own per-column predicates, which a serializer reads as readily as the column.
      def model_members(row)
        columns = Array(row[:columns]).map(&:to_s)
        associations = Array(row[:associations]).map { |a| a[:name].to_s }
        enums = row[:enums].is_a?(Hash) ? row[:enums].keys.map(&:to_s) : []
        aliases = row[:aliases].is_a?(Hash) ? row[:aliases].keys.map(&:to_s) : []
        scopes = Array(row[:scopes]).map(&:to_s)
        (columns + columns.map { |c| "#{c}?" } + associations + enums + aliases + scopes).to_set
      end

      # The other half of "answers": a method the project writes in Ruby on the model or an ancestor of
      # it — `Account#local?`, a concern's reader, an `attr_accessor`. The model index cannot see these,
      # and without them the check would decline nearly every real serializer.
      def project_defines?(model_name, method_name, scope)
        return false unless scope.respond_to?(:user_def_through_ancestors)

        !scope.user_def_through_ancestors(model_name, method_name.to_sym).first.nil?
      end

      # `REST::AccountSerializer` offers two readings — the namespaced `REST::Account` and the
      # demodulized `Account` — and Rails apps use both (`Admin::AccountSerializer` for `Admin::Account`
      # is as real as Mastodon's `REST::AccountSerializer` for `Account`). Both are offered to the model
      # index, and exactly one of them has to land.
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
