# frozen_string_literal: true

# Fixture for issue #1574: a plugin gem whose producer value has the shape rigor-sidekiq's `worker_index` has.
# Each row's name is a frozen String, and the index keys a Hash by that same String, so a `Marshal.dump` of
# the computed value writes the key as a back-reference to the row's field, while the value its ADR-45 cache
# entry serves has an unshared key. `spec/integration/incremental_fact_fingerprint_warm_spec.rb` runs
# `rigor check --incremental` over it: the fact-surface fingerprint must read the two as the same value.
require "prism"
require "rigor/plugin"

module Rigor
  module Plugin
    class SharedKeyDemo < Rigor::Plugin::Base
      Row = Data.define(:class_name, :arity)

      # The index a node rule reads: rows in order, and the same rows by name.
      class Index
        def initialize(rows)
          @rows = rows.freeze
          @by_name = rows.to_h { |row| [row.class_name, row] }.freeze
          freeze
        end

        def find(name)
          @by_name[name]
        end
      end

      manifest(
        id: "shared-key-demo",
        version: "0.1.0",
        description: "Fixture plugin whose producer value shares frozen Strings between rows and Hash keys."
      )

      # Reads no file, so its cache entry stays fresh once written: the first run computes the index and every
      # later run is served it.
      producer :worker_index do |_params|
        rows = { "WelcomeWorker" => 1, "DigestWorker" => 2 }.map do |name, arity|
          Row.new(class_name: name.dup.freeze, arity: arity)
        end
        Index.new(rows)
      end

      # `WelcomeWorker.perform_async(1, 2)` passes two arguments to a worker that takes one.
      node_rule Prism::CallNode do |node, _scope, path|
        receiver = node.receiver
        next [] unless node.name == :perform_async && receiver.is_a?(Prism::ConstantReadNode)

        row = producer_value(:worker_index)&.find(receiver.name.to_s)
        given = node.arguments&.arguments&.size || 0
        next [] if row.nil? || row.arity == given

        [diagnostic(
          node, path: path,
                message: "#{row.class_name}.perform_async passes #{given} argument(s); it takes #{row.arity}",
                severity: :error,
                rule: "worker-arity"
        )]
      end
    end

    Rigor::Plugin.register(SharedKeyDemo)
  end
end
