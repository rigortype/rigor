# frozen_string_literal: true

require "rigor/plugin"

require_relative "activestorage/attachment_discoverer"
require_relative "activestorage/attachment_index"
require_relative "activestorage/analyzer"
require_relative "activestorage/effects"

module Rigor
  module Plugin
    # rigor-activestorage — recognises `has_one_attached` / `has_many_attached` macros on ActiveRecord
    # models and contributes attachment accessor return types so chained calls (`user.avatar.attached?`)
    # route through Rigor's normal dispatch.
    #
    # ## Architecture
    #
    # One discovery pass per run reads the configured AR model paths (default `app/models/`) via the
    # plugin's `IoBoundary`, walks each `.rb` file with Prism, and collects `has_one_attached :avatar` /
    # `has_many_attached :photos` macros into an {AttachmentIndex} keyed by class name. The walker is
    # stand-alone (mirrors `rigor-activerecord`'s `ModelDiscoverer`) so the plugin works even when
    # `rigor-activerecord` is not loaded; when it IS loaded, the published `:model_index` fact (ADR-9
    # cross-plugin API) drives the same class set so the two plugins agree on what counts as a model.
    #
    # ## Configuration
    #
    #     plugins:
    #       - gem: rigor-activerecord  # producer of :model_index
    #       - gem: rigor-activestorage
    #         config:
    #           model_search_paths: ["app/models"]
    #
    # `model_search_paths` defaults to `["app/models"]`.
    #
    # The class name `Rigor::Plugin::Activestorage` (single capital A) matches the constant-distinguishing
    # convention used by `rigor-activerecord`.
    class Activestorage < Rigor::Plugin::Base
      manifest(
        id: "activestorage",
        # Bumped 2026-09-02 (#621) — attachment owners are keyed by their de-rooted name and a reopened
        # class's attachments are UNIONed rather than clobbered, so a cached 0.1.0 index can be missing the
        # attachments the merge restores.
        version: "0.2.0",
        description: "Types ActiveStorage attachment macros (has_one_attached / has_many_attached) on AR models.",
        config_schema: {
          "model_search_paths" => { kind: :array, default: ["app/models"] }
        },
        consumes: [{ plugin_id: "activerecord", name: :model_index, optional: true }],
        # ADR-103 WD10 (#387) — see {Effects} for what each row is and why.
        effect_root: "rails",
        effect_labels: %w[rails.activestorage.read rails.activestorage.write],
        effect_attributions: Effects.attributions
      )

      # Cached: attachment index. Walks every `.rb` file under `model_search_paths` for `has_*_attached`
      # macros. `watch:` (ADR-60 WD3) covers model-file additions; the discoverer's in-block reads are
      # captured into the record-and-validate dependency descriptor after the block runs.
      producer :attachment_index, watch: -> { [[@model_search_paths, "**/*.rb"]] } do |_params|
        rows = AttachmentDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @model_search_paths
        ).discover
        AttachmentIndex.build(rows: rows)
      end

      def init(_services)
        @model_search_paths = Array(config.fetch("model_search_paths")).map(&:to_s)
        @attachment_index = nil
        @load_errors = []
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        index = attachment_index
        return load_error_diagnostics(path) if index.nil?
        return [] if index.empty?

        Analyzer.new(path: path, attachment_index: index).analyze(root).diagnostics
      end

      # Return-type contribution: when the receiver is `Nominal[Model]` and the method matches a
      # discovered attachment, narrows to `Nominal[ActiveStorage::Attached::One]` (singular) or
      # `Nominal[ActiveStorage::Attached::Many]` (collection) via a `dynamic_return` rule keyed on the
      # live set of model class names from the attachment index. The chained call (`.attached?`, `.purge`,
      # `.url`) then resolves through ActiveStorage's RBS surface. Attachment setters (`user.avatar=`)
      # decline — they take side-effecting argument types that the RBS surface already covers.
      dynamic_return receivers: -> { attachment_index&.class_names || [] } do |call_node, scope|
        next nil unless call_node.is_a?(Prism::CallNode)
        next nil if call_node.receiver.nil?
        next nil unless call_node.arguments.nil?

        index = attachment_index
        next nil if index.nil? || index.empty?

        receiver_type = scope.type_of(call_node.receiver)
        next nil unless receiver_type.is_a?(Rigor::Type::Nominal)

        # `AttachmentIndex#attachments_for` de-roots the query itself (#621) — no retry arm here.
        attachments = index.attachments_for(receiver_type.class_name)
        next nil if attachments.nil?

        attachment = attachments.find { |a| a[:name] == call_node.name.to_s }
        next nil if attachment.nil?

        target = case attachment[:kind]
                 when :singular then "ActiveStorage::Attached::One"
                 when :collection then "ActiveStorage::Attached::Many"
                 end
        next nil if target.nil?

        Rigor::Type::Combinator.nominal_of(target)
      end

      # @!visibility private
      def attachment_index_for_spec
        attachment_index
      end

      private

      def attachment_index
        return @attachment_index if @attachment_index

        # ADR-60 WD3 record-and-validate: the producer's in-block `AttachmentDiscoverer` reads are
        # captured into the dependency descriptor after the block runs, and the producer's `watch:`
        # covers model-file additions.
        @attachment_index = cache_for(:attachment_index, params: {}).call
      rescue Plugin::AccessDeniedError => e
        @load_errors << "rigor-activestorage: #{e.message}"
        nil
      rescue StandardError => e
        @load_errors << "rigor-activestorage: discovery failed: #{e.class}: #{e.message}"
        nil
      end

      def load_error_diagnostics(path)
        @load_errors.uniq.map do |message|
          Rigor::Analysis::Diagnostic.new(
            path: path,
            line: 1,
            column: 1,
            message: message,
            severity: :warning,
            rule: "load-error"
          )
        end
      end
    end

    Rigor::Plugin.register(Activestorage)
  end
end
