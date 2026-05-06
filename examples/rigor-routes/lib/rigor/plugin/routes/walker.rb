# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Routes < Rigor::Plugin::Base
      # Yields every implicit-receiver call whose method name
      # matches `*_path` or `*_url`, paired with the base helper
      # name (`users_path` → `"users"`). Reduces the AST to the
      # minimum the plugin needs to validate against the route
      # table — the rest of the file is irrelevant.
      module Walker
        SUFFIX_RE = /\A(?<base>.+)_(?<kind>path|url)\z/

        module_function

        def each_helper_call(root, &)
          return enum_for(__method__, root) unless block_given?

          walk(root) do |node|
            next unless node.is_a?(Prism::CallNode)
            next unless node.receiver.nil?

            match = SUFFIX_RE.match(node.name.to_s)
            next unless match

            yield node, match[:base], match[:kind].to_sym
          end
        end

        def walk(node, &block)
          return if node.nil?

          yield node
          node.compact_child_nodes.each { |child| walk(child, &block) }
        end
      end
    end
  end
end
