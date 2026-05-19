# frozen_string_literal: true

require "prism"

require_relative "scope_walker"

module Rigor
  module Plugin
    class Rspec < Rigor::Plugin::Base
      # Per-file walker that:
      #
      # 1. Collects every RSpec scope (each `RSpec.describe`
      #    plus its nested `describe` / `context` blocks)
      #    via {ScopeWalker}.
      # 2. Reports duplicate `let(:name)` / `subject(:name)`
      #    declarations within the same scope (the second
      #    declaration wins at runtime — an easy
      #    copy-paste bug).
      # 3. Reports recursive self-references —
      #    `let(:user) { user.something }` will infinite-loop
      #    at runtime — an easy oversight.
      module Analyzer
        Diagnostic = Struct.new(:path, :line, :column, :severity, :rule, :message, keyword_init: true)

        module_function

        # @param path [String]
        # @param root [Prism::Node]
        # @return [Array<Diagnostic>]
        def diagnose(path:, root:)
          diagnostics = []
          ScopeWalker.collect_scopes(root).each do |outer|
            ScopeWalker.each_scope(outer) do |scope|
              diagnostics.concat(duplicate_diagnostics(path, scope))
              diagnostics.concat(self_reference_diagnostics(path, scope))
            end
          end
          diagnostics
        end

        def duplicate_diagnostics(path, scope)
          counts = Hash.new { |h, k| h[k] = [] }
          scope.declarations.each { |decl| counts[decl.name] << decl }
          counts.flat_map do |name, decls|
            next [] if decls.size < 2

            duplicate_diagnostics_for(path, name, decls)
          end
        end

        def duplicate_diagnostics_for(path, name, decls)
          # Report each subsequent occurrence; the first
          # one is the "winner" only by literal source
          # order, but RSpec lets the LAST declaration win
          # at runtime, so flag everything after the first
          # so the user can see the full list.
          decls.drop(1).map do |decl|
            Diagnostic.new(
              path: path,
              line: decl.location.start_line,
              column: decl.location.start_column + 1,
              severity: :warning,
              rule: "duplicate-let",
              message: "duplicate `#{decl.kind}(:#{name})` in this scope " \
                       "(first declared at line #{decls.first.location.start_line}); " \
                       "the last declaration wins at runtime"
            )
          end
        end

        def self_reference_diagnostics(path, scope)
          scope.declarations.flat_map do |decl|
            next [] unless self_references?(decl)

            [self_reference_diagnostic(path, decl)]
          end
        end

        # Walks the declaration's block body looking for a
        # call to its own name with no explicit receiver.
        # Returns true if at least one such call exists.
        def self_references?(decl)
          body = decl.block_node&.body
          return false if body.nil?

          contains_self_reference?(body, decl.name)
        end

        def contains_self_reference?(node, name)
          return false unless node.is_a?(Prism::Node)
          return true if node.is_a?(Prism::CallNode) && node.name == name && node.receiver.nil?

          node.compact_child_nodes.any? { |child| contains_self_reference?(child, name) }
        end

        def self_reference_diagnostic(path, decl)
          Diagnostic.new(
            path: path,
            line: decl.location.start_line,
            column: decl.location.start_column + 1,
            severity: :error,
            rule: "self-reference",
            message: "`#{decl.kind}(:#{decl.name})` references its own name `#{decl.name}` — " \
                     "this will infinite-loop at runtime"
          )
        end
      end
    end
  end
end
