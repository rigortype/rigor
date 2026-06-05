# frozen_string_literal: true

require "rigor/plugin"

require_relative "rspec/scope_walker"
require_relative "rspec/analyzer"
require_relative "rspec/matcher_analyzer"
require_relative "rspec/let_scope_index"
require_relative "rspec/let_type_resolver"

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
        version: "0.3.0",
        description: "Validates RSpec `let` / `subject` declarations within each scope; " \
                     "narrows expect(x).to <matcher> assertions downstream in `it` bodies; " \
                     "binds let / subject locals to their inferred return type (Pillar 2 " \
                     "Slice 2) — `let(:user) { User.new(...) }` / `let(:user) { create(:user) }` / " \
                     "`subject { described_class.new(...) }`.",
        consumes: [
          { plugin_id: "factorybot", name: :factory_index, optional: true }
        ],
        additional_initializers: [
          # ADR-38 block-form: `before { @ivar = … }`, `let(:x) { @ivar = … }`,
          # and `subject { @ivar = … }` establish ivar state before `it` bodies
          # run. Declaring them here suppresses the read-before-write nil
          # widening that would otherwise appear on those ivars in `it` / `specify`
          # sibling blocks.
          Rigor::Plugin::AdditionalInitializer.new(
            receiver_constraint: "RSpec::ExampleGroup",
            block_methods: %i[before let subject]
          )
        ]
      )

      def init(services)
        @services = services
        @factory_index_resolved = false
        @factory_index = nil
        # Per-path `LetScopeIndex` cache. The plugin's
        # `flow_contribution_for` is called for every call
        # node the dispatcher visits; building the index once
        # per file is essential for performance.
        @let_index_cache = {}
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        # Build the let-scope index for this file while we
        # have the parsed root in hand — `flow_contribution_for`
        # picks it up from `@let_index_cache` keyed on path.
        @let_index_cache[path] ||= LetScopeIndex.build(root)
        Analyzer.diagnose(path: path, root: root).map { |diag| build_diagnostic(diag) }
      end

      # ADR-37 slice 2 — Pillar 2 Slice 1 matcher narrowing
      # (`expect(x).to be_a(T)` → `post_return_facts` on `x`),
      # method-gated by the engine on the expectation verbs.
      type_specifier methods: %i[to not_to to_not] do |call_node, scope|
        MatcherAnalyzer.contribution_for(call_node, environment: scope&.environment)&.post_return_facts
      end

      # Pillar 2 Slice 2 — binds local reads in `it` / spec bodies to
      # their `let(:name) { ... }` block's inferred return type. This is
      # a *method-gated return type* (keyed on the let-bound name read),
      # which the receiver-gated `dynamic_return` cannot express, so it
      # stays on `flow_contribution_for` — the deprecated escape valve
      # (ADR-37 slice 2 § "Outcome").
      def flow_contribution_for(call_node:, scope:)
        let_binding_contribution(call_node, scope)
      end

      private

      # Pillar 2 Slice 2 — when the call node is a no-receiver
      # method call (`user`, `subject`, etc.) inside an RSpec
      # `describe` block whose lets include a matching name,
      # return a `FlowContribution(return_type: <inferred>)`.
      def let_binding_contribution(call_node, scope)
        return nil if scope.nil?
        return nil unless candidate_call?(call_node)

        index = let_scope_index_for(scope.source_path)
        return nil if index.nil?

        line = call_node.location.start_line
        block_node = index.let_block_at(line, call_node.name)
        return nil if block_node.nil?

        describe_const = index.describe_const_at(line)
        type = LetTypeResolver.resolve(
          block_node,
          describe_const: describe_const,
          factory_index: factory_index_or_nil,
          environment: scope.environment
        )
        return nil if type.nil?

        Rigor::FlowContribution.new(return_type: type)
      end

      def candidate_call?(call_node)
        call_node.is_a?(Prism::CallNode) &&
          call_node.receiver.nil? &&
          call_node.block.nil? &&
          # Calls with arguments are matcher / DSL invocations,
          # not let-bound name reads. `subject` / `user` etc.
          # without args are the implicit-method-call shape RSpec
          # uses to expose let / subject in `it` bodies.
          (call_node.arguments.nil? || call_node.arguments.arguments.empty?)
      end

      def let_scope_index_for(path)
        return nil if path.nil?
        return @let_index_cache[path] if @let_index_cache.key?(path)

        @let_index_cache[path] = build_let_scope_index(path)
      end

      def build_let_scope_index(path)
        source = io_boundary.read_file(path)
        parse_result = Prism.parse(source)
        return nil unless parse_result.errors.empty?

        LetScopeIndex.build(parse_result.value)
      rescue Rigor::Plugin::AccessDeniedError, Errno::ENOENT
        nil
      end

      def factory_index_or_nil
        return @factory_index if @factory_index_resolved

        @factory_index = @services&.fact_store&.read(plugin_id: "factorybot", name: :factory_index)
        @factory_index_resolved = true
        @factory_index
      end

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
