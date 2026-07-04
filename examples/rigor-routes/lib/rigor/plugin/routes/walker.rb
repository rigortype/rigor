# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Routes < Rigor::Plugin::Base
      # Recognises the implicit-receiver `*_path` / `*_url` route
      # helper call shape. The engine owns the per-file AST walk
      # (ADR-37 `node_rule`); this module is only the matcher the
      # node rule applies to each `Prism::CallNode` it is handed —
      # it holds no traversal of its own.
      module Walker
        SUFFIX_RE = /\A(?<base>.+)_(?<kind>path|url)\z/

        module_function

        # Returns `[base, kind]` for an implicit-receiver `*_path` /
        # `*_url` call (`users_path` → `["users", :path]`), or `nil`
        # for any other node.
        def helper_call(node)
          return nil unless node.is_a?(Prism::CallNode)
          return nil unless node.receiver.nil?

          match = SUFFIX_RE.match(node.name.to_s)
          return nil unless match

          [match[:base], match[:kind].to_sym]
        end
      end
    end
  end
end
