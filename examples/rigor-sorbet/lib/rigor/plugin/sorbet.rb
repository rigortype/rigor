# frozen_string_literal: true

require "prism"
require "rigor/plugin"

require_relative "sorbet/method_signature"
require_relative "sorbet/catalog"
require_relative "sorbet/type_translator"
require_relative "sorbet/sig_parser"
require_relative "sorbet/catalog_walker"
require_relative "sorbet/assertion_recognizer"
require_relative "sorbet/absurd_recognizer"
require_relative "sorbet/sigil_detector"

module Rigor
  module Plugin
    # rigor-sorbet — ingests Sorbet `sig { ... }` blocks as
    # method-signature contributions to Rigor's analyzer.
    #
    # ADR-11 slice 1 — first deliverable. Recognises:
    #
    # - `sig { params(x: Integer).returns(String) }` above a
    #   `def foo(x)` definition, contributing the parsed return
    #   type at every call site.
    # - The `void` terminus and the `abstract` / `override` /
    #   `overridable` / `final` modifiers (recorded on the
    #   {MethodSignature} for slice ≥2).
    # - `class Foo` / `module Foo::Bar` / `class << self`
    #   nesting; `def self.foo` is recognised as a singleton
    #   method.
    #
    # Slice 1 vocabulary is the bare minimum to round-trip the
    # most common sig shapes; the {TypeTranslator} table
    # documents what's covered. Anything else (T.proc / T::Array
    # / T.class_of / T::Struct) degrades silently to
    # `Dynamic[top]` for now — slice 3 widens the translator.
    #
    # Architecture: per-run `Catalog` is built lazily on first
    # access by walking every configured `paths:` entry's `.rb`
    # files plus every `rbi_paths:` entry's `.rbi` files (slice
    # 4) via the plugin's `IoBoundary`. The catalog is frozen
    # after the first build and consulted by
    # `#flow_contribution_for` at every call site. RBI files
    # share the catalog with project-source sigs — both produce
    # `MethodSignature` entries keyed by
    # `(class_name, method_name, kind)`. When a key collides
    # across files, the last-walked sig wins (ordering is
    # platform-dependent: `Dir.glob` returns directory entries
    # in filesystem order). Sorbet's full shim-override
    # semantics — `sorbet/rbi/shims/` overriding
    # `sorbet/rbi/gems/` — lands in a later slice once the
    # catalog gains per-source provenance.
    #
    # The plugin emits `plugin.sorbet.parse-error` warnings for
    # malformed sig blocks (no block / empty block / no
    # `returns` or `void` terminus / two consecutive sigs / sig
    # not followed by a def) but never aborts a run.
    #
    # ## Configuration
    #
    #     plugins:
    #       - gem: rigor-sorbet
    #         config:
    #           paths: ["lib", "app"]         # directories to scan for `.rb` sigs; defaults to `paths:`
    #           rbi_paths: ["sorbet/rbi"]     # directories to scan for `.rbi` files; default shown
    #
    # The `paths:` config key narrows the plugin's `.rb` walk;
    # omit it to inherit the project-wide `paths:` value. The
    # `rbi_paths:` key controls where Sorbet's RBI tree is read
    # from — defaults to `sorbet/rbi/` per Tapioca's standard
    # layout (`gems/`, `annotations/`, `dsl/`, `shims/`). Set
    # to `[]` to opt out of RBI loading entirely.
    class Sorbet < Rigor::Plugin::Base
      manifest(
        id: "sorbet",
        version: "0.1.0",
        description: "Ingests Sorbet `sig` blocks as method-signature contributions.",
        config_schema: {
          "paths" => :array,
          "rbi_paths" => :array
        }
      )

      # Default RBI directory tree. Matches the layout
      # `tapioca init` generates — see Sorbet's `rbi.md`. Slice 4
      # walks every `.rbi` file under these roots recursively;
      # the four standard Tapioca subdirectories
      # (`gems` / `annotations` / `dsl` / `shims`) are picked
      # up as a side effect of recursing into the parent root.
      DEFAULT_RBI_PATHS = ["sorbet/rbi"].freeze

      def init(services)
        @services = services
        @configured_paths = Array(config.fetch("paths", services.configuration.paths)).map(&:to_s)
        @rbi_paths = Array(config.fetch("rbi_paths", DEFAULT_RBI_PATHS)).map(&:to_s)
        @catalog = nil
        @parse_errors_by_path = {}
        @catalog_built = false
        # ADR-11 slice 6 — Prism nodes for `T.absurd` calls
        # we observed in `flow_contribution_for` to be
        # *reachable* (i.e., their discriminant didn't narrow
        # to `bot`). `diagnostics_for_file` walks the per-file
        # AST and surfaces these as `plugin.sorbet.absurd-reachable`
        # warnings. Hash is keyed on the Prism node's
        # `object_id` because the runner only parses each file
        # once per run, so identity is stable across the two
        # plugin hooks.
        @reachable_absurd_nodes = {}.compare_by_identity
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        ensure_catalog
        # The catalog records errors under the canonicalised
        # (realpath-resolved) form; the runner may pass the
        # symlink-bearing form here. Look up under both so the
        # match is symlink-agnostic.
        errors = @parse_errors_by_path[path] || @parse_errors_by_path[canonicalize(path)] || []
        diagnostics = errors.map { |error| parse_error_diagnostic(path, error) }
        diagnostics.concat(absurd_reachable_diagnostics(path, root))
        diagnostics
      end

      # ADR-11 slice 1 — return-type contribution from the
      # parsed `sig { ... }` block. Resolves the receiver in two
      # passes:
      #
      # 1. Constant receiver (`User.find(...)`) → singleton-side
      #    catalog lookup.
      # 2. Nominal receiver-type (`user.name` where `user`'s
      #    inferred type is `Nominal["User"]`) → instance-side
      #    catalog lookup.
      #
      # Implicit-self calls (no receiver, current-class method)
      # are deferred to slice 2 — slice 1 covers the common case
      # where the sig is on the called method's own class.
      def flow_contribution_for(call_node:, scope:)
        return nil unless call_node.is_a?(Prism::CallNode)

        # ADR-11 slice 6 — `T.absurd(x)` exhaustiveness. Always
        # contributes a `bot` return + raise effect (matches
        # Sorbet's runtime behaviour); when the discriminant
        # *isn't* narrowed to `bot` at this scope, also records
        # the call node so `diagnostics_for_file` can surface a
        # `plugin.sorbet.absurd-reachable` warning.
        if AbsurdRecognizer.absurd_call?(call_node)
          @reachable_absurd_nodes[call_node] = true unless AbsurdRecognizer.exhaustive?(call_node, scope)
          return AbsurdRecognizer.contribution(call_node, manifest.id)
        end

        # ADR-11 slice 2 — `T.let` / `T.cast` / `T.must` /
        # `T.unsafe` are checked first because they're cheaper
        # to recognise (no catalog walk required) and they
        # win over any cataloged signature: the user explicitly
        # asserted the type at the call site.
        assertion = AssertionRecognizer.recognize(
          call_node: call_node, scope: scope, plugin_id: manifest.id
        )
        return assertion if assertion

        ensure_catalog
        return nil if @catalog.nil? || @catalog.empty?

        signature = lookup_signature(call_node, scope)
        return nil if signature.nil?

        return_type = signature.return_type
        return nil if return_type.nil?

        Rigor::FlowContribution.new(
          return_type: return_type,
          provenance: Rigor::FlowContribution::Provenance.new(
            source_family: "plugin.#{manifest.id}",
            plugin_id: manifest.id,
            node: call_node,
            descriptor: nil
          )
        )
      end

      private

      def lookup_signature(call_node, scope)
        receiver = call_node.receiver
        method_name = call_node.name
        return nil if method_name.nil?

        if (singleton_target = constant_receiver_name(receiver))
          # `Post.find(...)` — direct singleton method, or
          # `extend M` lifting `M#find` to the extending class.
          chain_lookup(singleton_target, method_name, anchor_kind: :singleton, mixin_kind: :extend)
        elsif receiver
          instance_chain_lookup(receiver, method_name, scope)
        end
      end

      def instance_chain_lookup(receiver_node, method_name, scope)
        return nil if scope.nil?

        receiver_type = scope.type_of(receiver_node)
        return nil unless receiver_type.is_a?(Rigor::Type::Nominal)

        chain_lookup(receiver_type.class_name, method_name, anchor_kind: :instance, mixin_kind: :include)
      rescue StandardError
        # `scope.type_of` can raise on unrecognised synthetic
        # nodes; degrade to "no contribution" rather than
        # bubbling the failure into the dispatcher.
        nil
      end

      # ADR-11 slice 8 — chain-aware catalog lookup.
      #
      # For instance-side calls (`post.body`):
      # - `anchor_kind: :instance` (try `Post#body` first)
      # - `mixin_kind: :include` (then walk Post's `include`d
      #   modules and try `Foo#body` on each)
      #
      # For singleton-side calls (`Post.find`):
      # - `anchor_kind: :singleton` (try `Post.find` first)
      # - `mixin_kind: :extend` (then walk Post's `extend`ed
      #   modules and try `Foo#find` *as :instance* — `extend
      #   Foo` lifts Foo's INSTANCE methods to the extending
      #   class's SINGLETON methods, matching Ruby's MRO).
      def chain_lookup(class_name, method_name, anchor_kind:, mixin_kind:)
        each_class_form(class_name).each do |form|
          sig = @catalog.lookup(class_name: form, method_name: method_name, kind: anchor_kind)
          return sig if sig
        end

        visited = Set.new
        queue = mixin_modules_for(class_name, mixin_kind).dup

        until queue.empty?
          candidate = queue.shift
          next unless visited.add?(candidate)

          forms_for_mixin(class_name, candidate).each do |form|
            sig = @catalog.lookup(class_name: form, method_name: method_name, kind: :instance)
            return sig if sig

            # Transitive: an `include` inside the mixed-in
            # module is also inherited by the host class.
            mixin_modules_for(form, :include).each do |inner|
              queue << inner unless visited.include?(inner)
            end
          end
        end

        nil
      end

      # `Post` and `::Post` are routinely confused at the catalog
      # boundary (the walker records the lexical name; user code
      # often writes the rooted form). Try both at every lookup.
      def each_class_form(class_name)
        [class_name, "::#{class_name}"]
      end

      # Resolution forms for a mixed-in module name. Tapioca's
      # generated DSL RBIs use the nested form
      # (`class Post; module GeneratedAttributeMethods; ...; end`);
      # hand-written shims often use the top-level form
      # (`module GeneratedAttributeMethods; ...; end` outside any
      # class); explicit rooting (`::GeneratedAttributeMethods`)
      # is occasionally seen. Try all three.
      def forms_for_mixin(host_class, mixin_name)
        if mixin_name.start_with?("::")
          [mixin_name, mixin_name.delete_prefix("::")]
        else
          ["#{host_class}::#{mixin_name}", mixin_name, "::#{mixin_name}"]
        end
      end

      def mixin_modules_for(class_name, kind)
        each_class_form(class_name).flat_map { |form| @catalog.mixins_for(form)[kind] }.uniq
      end

      def constant_receiver_name(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode then constant_path_name(node)
        end
      end

      def constant_path_name(node)
        parts = []
        current = node
        while current.is_a?(Prism::ConstantPathNode)
          parts.unshift(current.name.to_s)
          current = current.parent
        end
        case current
        when nil then "::#{parts.join('::')}"
        when Prism::ConstantReadNode then "#{current.name}::#{parts.join('::')}"
        end
      end

      def ensure_catalog
        return @catalog if @catalog_built

        catalog = Catalog.new
        # Project source — `.rb` only.
        @configured_paths.each { |root| harvest_path(root, catalog, extensions: %w[.rb]) }
        # Sorbet RBI tree — `.rbi` only. Slice 4 of ADR-11.
        @rbi_paths.each { |root| harvest_path(root, catalog, extensions: %w[.rbi]) }
        catalog.freeze!
        @catalog = catalog
        @catalog_built = true
        catalog
      end

      # @param root [String] directory or single file.
      # @param catalog [Catalog]
      # @param extensions [Array<String>] file extensions to
      #   accept (e.g. `[".rb"]` for project source,
      #   `[".rbi"]` for Sorbet RBI tree).
      def harvest_path(root, catalog, extensions:)
        absolute = canonicalize(root)
        if File.directory?(absolute)
          extensions.each do |ext|
            Dir.glob(File.join(absolute, "**", "*#{ext}")).each do |path|
              harvest_file(canonicalize(path), catalog)
            end
          end
        elsif File.file?(absolute) && extensions.any? { |ext| absolute.end_with?(ext) }
          # `paths:` may list individual files (the demos do
          # this); walk them directly rather than skipping.
          harvest_file(absolute, catalog)
        end
      end

      # Canonicalises a path through `File.realpath` so it
      # matches the form `Plugin::TrustPolicy#allow_read?` sees
      # (the runner builds the policy's roots from `Dir.pwd`,
      # which has symlinks resolved on macOS — `/tmp` →
      # `/private/tmp` etc.). Falls back to `File.expand_path`
      # when realpath fails (e.g. the path no longer exists).
      def canonicalize(path)
        expanded = File.expand_path(path)
        File.exist?(expanded) ? File.realpath(expanded) : expanded
      rescue StandardError
        expanded
      end

      def harvest_file(path, catalog)
        contents = io_boundary.read_file(path)
        return if contents.nil?

        # ADR-11 slice 5 — honour Sorbet's `# typed: ignore`
        # magic comment by skipping the file entirely. Other
        # levels (`false` / `true` / `strict` / `strong`)
        # parse and harvest the same way today; per-call-site
        # honouring is queued for a later slice.
        return if SigilDetector.ignored?(SigilDetector.detect(contents))

        result = Prism.parse(contents)
        return unless result.errors.empty?

        errors = CatalogWalker.walk(root: result.value, catalog: catalog, path: path)
        @parse_errors_by_path[path] = errors unless errors.empty?
      rescue Plugin::AccessDeniedError, Errno::ENOENT
        # Skip files outside the trusted read scope or that
        # vanished between glob and read; the plugin produces
        # no output for them.
        nil
      end

      # Walks the per-file AST looking for `T.absurd(x)` call
      # nodes and emits a `plugin.sorbet.absurd-reachable`
      # warning for any whose object identity matches
      # `@reachable_absurd_nodes` (populated during the engine's
      # earlier pass through `flow_contribution_for`). Pops
      # matched entries so a duplicate run doesn't double-emit.
      def absurd_reachable_diagnostics(path, root)
        return [] if @reachable_absurd_nodes.empty?

        diagnostics = []
        walk_for_absurd(root) do |call_node|
          next unless @reachable_absurd_nodes.delete(call_node)

          diagnostics << absurd_diagnostic(path, call_node)
        end
        diagnostics
      end

      def walk_for_absurd(node, &)
        return unless node.is_a?(Prism::Node)

        yield node if node.is_a?(Prism::CallNode) && AbsurdRecognizer.absurd_call?(node)
        node.compact_child_nodes.each { |child| walk_for_absurd(child, &) }
      end

      def absurd_diagnostic(path, call_node)
        location = call_node.location
        Rigor::Analysis::Diagnostic.new(
          path: path,
          line: location.start_line,
          column: location.start_column + 1,
          message: "`T.absurd` is reachable: the discriminant did not narrow to `T.noreturn`. " \
                   "Either add the missing case branch above the `else`, or remove the " \
                   "`T.absurd(...)` call.",
          severity: :warning,
          rule: "absurd-reachable"
        )
      end

      def parse_error_diagnostic(path, error)
        location = error.node.location
        Rigor::Analysis::Diagnostic.new(
          path: path,
          line: location.start_line,
          column: location.start_column + 1,
          message: parse_error_message(error.kind),
          severity: :warning,
          rule: "parse-error"
        )
      end

      def parse_error_message(kind)
        case kind
        when :no_block then "Sorbet `sig` call missing a block."
        when :empty_block then "Sorbet `sig` block is empty."
        when :missing_returns_or_void
          "Sorbet `sig` block must end in `.returns(...)` or `.void`."
        when :duplicate_sig
          "Two `sig` blocks in a row; the first one has no following method definition."
        when :dangling_sig
          "`sig` block is not immediately followed by a method definition."
        else "Sorbet `sig` block did not parse (#{kind})."
        end
      end
    end

    Rigor::Plugin.register(Sorbet)
  end
end
