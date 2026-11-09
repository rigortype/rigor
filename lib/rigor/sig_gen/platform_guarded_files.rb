# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"

module Rigor
  module SigGen
    # Issue #3035 — the files a sig-gen run must not read as ordinary definitions: every scanned `.rb`
    # file Ruby loads ONLY through a platform-conditional `require` / `require_relative`.
    #
    # `stackprof.rb` opens with `if RUBY_ENGINE == 'truffleruby'` → `require "stackprof/truffleruby"`,
    # and `truffleruby.rb` re-implements `StackProf.run` / `.results` as raising stubs — on MRI the C
    # extension defines them. Scanning every `.rb` under `lib/` reads that stub file as an ordinary
    # definition and proposes `StackProf.run -> bot` against a method whose real signature returns
    # `Hash[Symbol, untyped]`.
    #
    # {.call} answers the guarded set from the resolved file list alone: it parses each file once,
    # collects the literal `require` / `require_relative` sites, marks a site guarded when it sits
    # inside a conditional whose predicate reads `RUBY_ENGINE`, `RUBY_PLATFORM` or `defined?(…)`,
    # resolves each feature against the scanned set (`require_relative` against the file's own
    # directory; `require` against the file's ancestor directories — the load-path approximation a
    # gem's `lib/` root satisfies), and keeps the files whose EVERY incoming edge is guarded —
    # directly, or through a file already known guarded (a helper `truffleruby.rb` requires
    # unconditionally is still truffleruby-only). A file with no scanned require site is never
    # guarded: an entry point, an autoload target or a `load`ed file cannot be told apart from a
    # guarded one, and the unguarded reading is the one that emits.
    #
    # Limits, deliberately: require sites in files OUTSIDE the scanned set are invisible (a sibling
    # the run did not read may require the file unguarded); `load`, `autoload` and computed features
    # are not edges; and a file that fails to parse poisons the whole answer — its require edges are
    # unknowable, so {.call} returns an empty set rather than risk a false guarded verdict.
    module PlatformGuardedFiles
      # The constants a conditional predicate may read to make a require platform-dependent.
      GUARD_CONSTANTS = %i[RUBY_ENGINE RUBY_PLATFORM].freeze
      private_constant :GUARD_CONSTANTS

      # The conditional forms whose whole subtree a platform predicate guards — `if` / `unless` in
      # statement, modifier and ternary spelling, `case` and `case/in` on a guarded subject. Both
      # branches count: `else` of `RUBY_ENGINE == 'x'` is `RUBY_ENGINE != 'x'`, still conditional.
      CONDITIONALS = [Prism::IfNode, Prism::UnlessNode, Prism::CaseNode, Prism::CaseMatchNode].freeze
      private_constant :CONDITIONALS

      REQUIRE_CALLS = %i[require require_relative].freeze
      private_constant :REQUIRE_CALLS

      module_function

      # @param paths — the `.rb` files the run will analyse, as spelled by the run.
      # @param ruby_version — the Prism version to parse with (the configuration's `target_ruby`).
      # @return a Set of `File.expand_path`'d paths that are required only under platform guards.
      def call(paths, ruby_version: nil)
        files = paths.map { |path| File.expand_path(path) }.uniq
        known = files.to_set
        edges = Hash.new { |hash, key| hash[key] = [] }
        files.each do |file|
          sites = require_sites(file, ruby_version, known)
          return Set.new if sites.nil?

          sites.each { |target, guarded| edges[target] << { from: file, guarded: guarded } }
        end
        guarded_closure(files, edges)
      end

      # Every `[target, guarded]` pair `file`'s literal require sites resolve to inside `known`;
      # `nil` when the file does not parse (see the class comment for why that voids the answer).
      def require_sites(file, ruby_version, known)
        result = Prism.parse(File.read(file), filepath: file, version: ruby_version)
        return nil if result.errors.any?

        sites = []
        walk_require_sites(result.value) do |node, guarded|
          target = require_target(file, node, known)
          sites << [target, guarded] if target
        end
        sites
      end

      # An explicit stack, not recursion: a require site deep in a generated file must not exhaust it.
      def walk_require_sites(root, &block)
        stack = [[root, false]]
        until stack.empty?
          node, guarded = stack.pop
          next unless node.is_a?(Prism::Node)

          block.call(node, guarded) if require_call?(node)
          child_guarded = guarded || platform_conditional?(node)
          node.rigor_each_child { |child| stack << [child, child_guarded] }
        end
      end

      # A `require "feature"` / `require_relative "feature"` with one string literal and no receiver —
      # the same strictness {Analysis::RequireRelativeClosure} reads `require_relative` with.
      def require_call?(node)
        return false unless node.is_a?(Prism::CallNode) && node.receiver.nil?
        return false unless REQUIRE_CALLS.include?(node.name)

        arguments = node.arguments&.arguments
        arguments&.size == 1 && arguments.first.is_a?(Prism::StringNode)
      end

      # Whether `node` is a conditional whose predicate makes what it guards platform-dependent: a
      # `RUBY_ENGINE` / `RUBY_PLATFORM` read or a `defined?(…)` anywhere in it.
      def platform_conditional?(node)
        return false unless CONDITIONALS.any? { |klass| node.is_a?(klass) }

        predicate = node.predicate
        !predicate.nil? && platform_expression?(predicate)
      end

      # Iterative like {#walk_require_sites}: a predicate can chain thousands of `||` operands.
      def platform_expression?(root)
        stack = [root]
        until stack.empty?
          node = stack.pop
          return true if node.is_a?(Prism::DefinedNode)
          return GUARD_CONSTANTS.include?(node.name) if node.is_a?(Prism::ConstantReadNode)
          # `::RUBY_ENGINE` names the same constant; `Foo::RUBY_ENGINE` is a different one.
          return node.parent.nil? && GUARD_CONSTANTS.include?(node.name) if node.is_a?(Prism::ConstantPathNode)

          node.rigor_each_child { |child| stack << child }
        end
        false
      end

      # The scanned file `node`'s feature resolves to, or nil when it names nothing the run reads
      # (a gem, a `.so`, a computed path's sibling).
      def require_target(site_file, node, known)
        feature = node.arguments.arguments.first.unescaped
        feature += ".rb" unless feature.end_with?(".rb")
        if node.name == :require_relative
          candidate = File.expand_path(feature, File.dirname(site_file))
          return candidate if known.include?(candidate)

          return nil
        end

        # `require` resolves through the load path; the file's own directory upward is the
        # approximation that finds `lib/stackprof/truffleruby.rb` for `require "stackprof/truffleruby"`
        # in `lib/stackprof.rb`, nearest ancestor first.
        dir = File.dirname(site_file)
        loop do
          candidate = File.expand_path(feature, dir)
          return candidate if known.include?(candidate)

          parent = File.dirname(dir)
          return nil if parent == dir

          dir = parent
        end
      end

      # The fixpoint: a file is guarded-only when it has at least one scanned require edge and every
      # edge reaching it is either syntactically guarded or issued from a file already guarded-only.
      def guarded_closure(files, edges)
        guarded = Set.new
        loop do
          added = false
          files.each do |file|
            next if guarded.include?(file)

            incoming = edges[file]
            next if incoming.empty?
            next unless incoming.all? { |edge| edge[:guarded] || guarded.include?(edge[:from]) }

            guarded << file
            added = true
          end
          break unless added
        end
        guarded
      end
    end
  end
end
