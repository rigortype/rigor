# frozen_string_literal: true

require "rigor/plugin"

require_relative "rspec/scope_walker"
require_relative "rspec/analyzer"
require_relative "rspec/matcher_analyzer"

module Rigor
  module Plugin
    # rigor-rspec — validates RSpec `let` / `subject`
    # declarations within each describe / context scope.
    #
    # Tier 3A of the [Rails plugins roadmap](../../../../docs/design/20260508-rails-plugins-roadmap.md).
    # Deliberately scoped — the roadmap describes a much
    # larger plugin (let-typo detection in `it` bodies,
    # `expect(x).to receive(:method)` mock-target
    # validation). Both are out of scope for v0.1.0; this
    # plugin ships the two checks that have the lowest
    # false-positive risk:
    #
    # 1. **Duplicate `let` / `subject` declarations** in
    #    the same scope (`warning`). RSpec's runtime lets
    #    the last declaration win, so the first one is
    #    silently shadowed — almost always a copy-paste
    #    bug.
    # 2. **Self-referencing `let` / `subject`** — calling
    #    the declared name *inside* its own block body
    #    (`error`). At runtime this infinite-loops; users
    #    typically meant to call a different method or
    #    forgot to introduce a `super`.
    #
    # ## Configuration
    #
    # No knobs in v0.1.0. The plugin walks every analysed
    # file looking for `RSpec.describe ... do` blocks; spec
    # files outside the project's `paths:` are not scanned.
    #
    # ## Limitations (v0.1.0)
    #
    # - **No let-typo detection.** Detecting an `it`
    #   block's reference to a misspelled `let` name
    #   requires resolving every method call inside the
    #   block against the let scope chain, the included
    #   modules, the matchers DSL, and helper methods.
    #   Reliable diagnostics here need a much heavier
    #   walker — see the README's `Future direction`.
    # - **No mock-target validation.**
    #   `expect(x).to receive(:nme)` validating against
    #   `x`'s methods is a separate slice; it overlaps with
    #   the engine's general method-existence
    #   diagnostics and needs careful coordination to avoid
    #   double-firing.
    # - **No shared-context resolution.** `include_context`,
    #   `shared_context`, and `it_behaves_like` are
    #   recognised as scope-opening calls but their
    #   declarations are not pulled into the host scope.
    # - **Constant validation is not done here.**
    #   `RSpec.describe SomeClass do` does not validate
    #   `SomeClass`; the engine's `inference.unresolved-constant`
    #   already catches that.
    class Rspec < Rigor::Plugin::Base
      manifest(
        id: "rspec",
        version: "0.2.0",
        description: "Validates RSpec `let` / `subject` declarations within each scope; " \
                     "narrows expect(x).to <matcher> assertions downstream in `it` bodies."
      )

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        Analyzer.diagnose(path: path, root: root).map { |diag| build_diagnostic(diag) }
      end

      # Pillar 2 Slice 1 — spec-derived flow facts from RSpec
      # assertions. Recognises `expect(x).to MATCHER` at every
      # call site the dispatcher visits and, for the six
      # supported matchers (`be_a` / `be_kind_of` /
      # `be_instance_of` / `be_nil` / `eq(literal)` / `eql(literal)`),
      # emits a `post_return_fact` that narrows `x` from the
      # assertion onward. The engine consumes the contribution
      # through `StatementEvaluator#apply_plugin_assertions` and
      # routes it to the new `:local` target_kind branch added
      # in v0.1.8.
      def flow_contribution_for(call_node:, scope:)
        MatcherAnalyzer.contribution_for(call_node, environment: scope&.environment)
      end

      private

      def build_diagnostic(diag)
        Rigor::Analysis::Diagnostic.new(
          path: diag.path, line: diag.line, column: diag.column,
          message: diag.message, severity: diag.severity, rule: diag.rule
        )
      end
    end

    Rigor::Plugin.register(Rspec)
  end
end
