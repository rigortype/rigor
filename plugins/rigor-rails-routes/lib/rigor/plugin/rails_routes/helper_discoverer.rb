# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class RailsRoutes < Rigor::Plugin::Base
      # Walks `app/helpers/**/*.rb` (or any configured set of helper directories) and extracts every public
      # module-level method name so the analyzer's `unknown-helper` rule does not false-fire on calls to
      # project-defined `*_path` / `*_url` helpers (the canonical Rails pattern: a `UrlHelper` module
      # exposing `full_asset_url`, `host_to_url`, `frontend_asset_url`, and so on).
      #
      # The discoverer is deliberately conservative:
      #
      # - Walks `def name(...)` declarations at the module / class top level. Nested `def` inside a method
      #   body or a `define_method` macro is NOT extracted (the same reason `rigor-actionpack` is not the
      #   canonical custom-helper source — metaprogrammed helpers are out of scope for a static scan).
      # - **Visibility-agnostic.** A `private` / `protected` `def some_url` IS registered. The
      #   `unknown-helper` rule is a project-wide name-presence check, not a visibility check — if the user
      #   wrote a `_path` / `_url` method anywhere in `app/`, they very likely intend to call it (often
      #   Mastodon's pattern: a controller's `private def page_url(page)` invoked by a `link_to` in its own
      #   view). The core engine's `call.undefined-method` rule still catches the case where the receiver
      #   genuinely cannot see the method.
      # - Ignores `def self.x` (singleton-method definitions) — Rails helpers are instance methods on the
      #   helper module; class-side `self.x` shapes are usually internal utilities, not view helpers.
      # - Filters the resulting set to names ending in `_path` or `_url` (the dispatch surface the
      #   analyzer's rule actually cares about). A helper whose name does not end with either suffix is
      #   irrelevant to the rule's false-positive surface, so excluding it costs nothing and keeps the
      #   registered set focused.
      #
      # Out of scope (intentional):
      #
      # - Helpers defined via `define_method` or via macros like `inheritance_traversed_helpers`. These
      #   would need ADR-16 macro substrate or per-plugin custom recognizers.
      # - Helpers inherited from gems (`Devise::Controllers::Helpers`, `ViteRails::TagHelpers`, etc.).
      #   Those need their own handling — Devise auto-routes are covered by the companion `DeviseRoutes`
      #   generator; other gem-injected helpers fall to ADR-25 plugin-contributed RBS or the ADR-10
      #   `dependencies.source_inference:` path.
      module HelperDiscoverer
        HELPER_SUFFIXES = [/_path\z/, /_url\z/].freeze

        module_function

        # @param contents_per_path [Hash{String => String}] file path → source text. The caller is
        #   responsible for reading files (typically through the trusted `IoBoundary` so cache invalidation
        #   works).
        # @return [Set<String>] method names suitable for inclusion in the `HelperTable`'s custom-helper set.
        def discover(contents_per_path)
          names = []
          contents_per_path.each_value do |contents|
            names.concat(extract_from_contents(contents))
          rescue StandardError
            # Skip any file whose AST walk explodes — discovery is best-effort and a parse failure in one
            # helper file MUST NOT abort discovery for the rest. Other rules will still surface the parse
            # failure on the affected file through the core pipeline.
            next
          end
          names.to_set
        end

        def extract_from_contents(contents)
          parse_result = Prism.parse(contents)
          return [] unless parse_result.errors.empty?

          walker = ModuleBodyWalker.new
          walker.walk(parse_result.value)
          walker.helper_names
        end

        # Per-file AST walker. The walker is recursive into module / class bodies so `module UrlHelpers;
        # module Routing; def foo_url; end; end; end` registers `foo_url`. It does NOT recurse into method
        # bodies (a `def inside def` would be `define_method`-shaped, which we skip per the docstring).
        class ModuleBodyWalker
          attr_reader :helper_names

          def initialize
            @helper_names = []
          end

          def walk(node)
            visit_statements(node) if node.is_a?(Prism::ProgramNode)
            visit_program_children(node)
          end

          private

          def visit_program_children(node)
            return unless node.respond_to?(:compact_child_nodes)

            node.compact_child_nodes.each do |child|
              case child
              when Prism::ModuleNode, Prism::ClassNode
                visit_module_or_class(child)
              when Prism::ProgramNode, Prism::StatementsNode
                visit_program_children(child)
              end
            end
          end

          def visit_module_or_class(node)
            visit_statements(node.body)
          end

          def visit_statements(body)
            return if body.nil?

            # Visibility tracking is intentionally absent — see the "visibility-agnostic" point in the
            # module docstring. A `private def page_url(page)` inside a controller IS registered so a
            # caller in the paired view does not false-fire `unknown-helper`.
            statements_of(body).each do |stmt|
              case stmt
              when Prism::DefNode
                record_helper(stmt)
              when Prism::ModuleNode, Prism::ClassNode
                visit_module_or_class(stmt)
              when Prism::StatementsNode
                visit_statements(stmt)
              end
            end
          end

          def statements_of(node)
            case node
            when Prism::StatementsNode then node.body
            when Prism::BeginNode      then statements_of(node.statements)
            else [node]
            end
          end

          def record_helper(def_node)
            # Skip singleton methods (`def self.x`).
            return if def_node.receiver

            name = def_node.name.to_s
            return unless HELPER_SUFFIXES.any? { |suffix| name.match?(suffix) }

            @helper_names << name
          end
        end
      end
    end
  end
end
