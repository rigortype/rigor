# frozen_string_literal: true

require "rigor/plugin"
require "rigor-ffi"

module Rigor
  module Plugin
    class Ethon < Base
      manifest(
        id: "ethon",
        version: "0.1.0",
        description: "Models Ethon / Libcurl options, dynamic return types, and multi-loop operations.",
        signature_paths: ["sig"]
      )

      # Option catalogue and return types for Easy methods
      EASY_RETURN_TYPES = {
        perform: -> { Rigor::Type::Combinator.nominal_of("Integer") },
        response_code: -> { Rigor::Type::Combinator.nominal_of("Integer") },
        return_code: -> { Rigor::Type::Combinator.nominal_of("Symbol") },
        total_time: -> { Rigor::Type::Combinator.nominal_of("Float") },
        response_body: -> { Rigor::Type::Combinator.nominal_of("String") },
        response_headers: -> { Rigor::Type::Combinator.nominal_of("String") }
      }.freeze

      dynamic_return receivers: ["Ethon::Easy"], methods: EASY_RETURN_TYPES.keys do |call_node, _scope|
        builder = EASY_RETURN_TYPES[call_node.name]
        builder&.call
      end
    end
  end
end

Rigor::Plugin.register(Rigor::Plugin::Ethon)
