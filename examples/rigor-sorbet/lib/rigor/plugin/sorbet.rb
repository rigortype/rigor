# frozen_string_literal: true

require "prism"
require "rigor/plugin"

require_relative "sorbet/method_signature"
require_relative "sorbet/catalog"
require_relative "sorbet/type_translator"
require_relative "sorbet/sig_parser"
require_relative "sorbet/catalog_walker"
require_relative "sorbet/assertion_recognizer"

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
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        ensure_catalog
        # The catalog records errors under the canonicalised
        # (realpath-resolved) form; the runner may pass the
        # symlink-bearing form here. Look up under both so the
        # match is symlink-agnostic.
        errors = @parse_errors_by_path[path] || @parse_errors_by_path[canonicalize(path)] || []
        errors.map { |error| parse_error_diagnostic(path, error) }
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
          singleton_lookup(singleton_target, method_name)
        elsif receiver
          instance_lookup(receiver, method_name, scope)
        end
      end

      def singleton_lookup(class_name, method_name)
        # Try the as-is name first, then the rooted form
        # (`::Foo`); user code typically writes `Foo.find(...)`,
        # but the catalog records the lexical full name which
        # may have a leading `::` for top-level classes.
        @catalog.lookup(class_name: class_name, method_name: method_name, kind: :singleton) ||
          @catalog.lookup(class_name: "::#{class_name}", method_name: method_name, kind: :singleton)
      end

      def instance_lookup(receiver_node, method_name, scope)
        return nil if scope.nil?

        receiver_type = scope.type_of(receiver_node)
        return nil unless receiver_type.is_a?(Rigor::Type::Nominal)

        @catalog.lookup(class_name: receiver_type.class_name, method_name: method_name, kind: :instance) ||
          @catalog.lookup(class_name: "::#{receiver_type.class_name}", method_name: method_name, kind: :instance)
      rescue StandardError
        # `scope.type_of` can raise on unrecognised synthetic
        # nodes; degrade to "no contribution" rather than
        # bubbling the failure into the dispatcher.
        nil
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
