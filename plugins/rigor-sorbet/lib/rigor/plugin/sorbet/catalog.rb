# frozen_string_literal: true

module Rigor
  module Plugin
    class Sorbet < Rigor::Plugin::Base
      # Per-run table of method signatures keyed by the `(class_name, method_name, kind)` triple. Built by
      # {CatalogWalker} during the plugin's lazy pre-walk; read by the plugin's `dynamic_return` rule at
      # every gated call site.
      #
      # The catalog is mutable while it is being built, then frozen via {#freeze!} before the first read.
      # Construction mutability is intentional — slice 1 builds the catalog incrementally as the walker
      # visits each project file — but consumers MUST treat the catalog as read-only.
      class Catalog
        # Frozen empty bucket reused for classes that have no recorded mixins. Avoids allocating a fresh
        # Hash on every `mixins_for` query.
        EMPTY_MIXINS = { include: [].freeze, extend: [].freeze }.freeze

        # Issue #2541 — the sorbet-runtime struct roots whose `prop` / `const` calls define accessors
        # (`T::Props::ClassMethods#prop` → `T::Props::Decorator#add_prop_definition` defines the reader,
        # and the writer for `prop` only; `const` is `prop(..., immutable: true)`). `T::ImmutableStruct`
        # overrides `prop` to raise, so a writer is never answered under it.
        STRUCT_ROOTS = %w[T::Struct T::InexactStruct T::ImmutableStruct].freeze
        IMMUTABLE_STRUCT_ROOT = "T::ImmutableStruct"

        def initialize
          @entries = {}
          # ADR-11 slice 8 — per-class mixin declarations collected by `CatalogWalker`. Lookup-time chain
          # traversal lifts sigs declared on a mixed-in module to call sites on the host class.
          @mixins = {}
          # Issue #2541 — `prop` / `const` accessors recorded per declaring class, the lexical superclass of
          # every `class X < Y` the walker saw, and the instance methods each class body `def`s itself. A
          # struct accessor answers only when the declaring class reaches a {STRUCT_ROOTS} root through
          # `@superclasses`, and a class's own `def` of the same name shadows it (Ruby: the later `def`
          # replaces the generated accessor; a subclass `def` overrides it).
          @struct_props = {}
          @struct_prop_types = {}
          @struct_nesting = {}
          @namespaces = {}
          @constants = {}
          @struct_includes = {}
          @mixes_in = {}
          @superclasses = {}
          @defined_methods = {}
          @frozen_after_build = false
        end

        def record(signature)
          raise "Catalog already finalised" if @frozen_after_build

          key = key_for(signature.class_name, signature.method_name, signature.kind)
          @entries[key] = signature
        end

        # @param class_name — the class / module that carries the mixin (`class Post; include Foo;
        #   end` records under `"Post"`).
        # @param module_name — the textual name of the mixed-in module as it appeared at the
        #   include / extend site (`"Foo"`, `"Foo::Bar"`, `"::Foo"`).
        def record_mixin(class_name:, kind:, module_name:)
          raise "Catalog already finalised" if @frozen_after_build

          bucket = (@mixins[class_name] ||= { include: [], extend: [] })
          list = bucket[kind]
          list << module_name unless list.include?(module_name)
        end

        # @param signature — a {MethodSignature} for a `prop` / `const` reader or a `prop` writer.
        # @param certain — false for a call nested under a conditional or a block, which never displaces
        #   an accessor already recorded for the name; a certain one replaces whatever is there.
        # @param type_source — the source text of the macro's type argument, re-translated at lookup with
        #   its constants resolved against `nesting` ({#struct_prop_type}); nil when the accessor is untyped.
        # @param nesting — the declaring class's lexical nesting, outermost first, its own name last.
        def record_struct_prop(signature, certain: true, type_source: nil, nesting: [])
          raise "Catalog already finalised" if @frozen_after_build

          props = (@struct_props[signature.class_name] ||= {})
          return unless certain || !props.key?(signature.method_name)

          props[signature.method_name] = signature
          @struct_prop_types[[signature.class_name, signature.method_name]] = type_source
          @struct_nesting[signature.class_name] ||= nesting.dup.freeze
        end

        # Issue #2541 — every class and module name the walk declared, so a struct accessor's relative
        # constant resolves to a project class the RBS environment may not know.
        def record_namespace(name)
          raise "Catalog already finalised" if @frozen_after_build

          @namespaces[name] = true
        end

        def namespace?(name)
          @namespaces.key?(name)
        end

        # A constant the walk saw assigned (`Thing = Other`) rather than declared as a class or module.
        def record_constant(name)
          raise "Catalog already finalised" if @frozen_after_build

          @constants[name] = true
        end

        def constant?(name)
          @constants.key?(name)
        end

        def record_struct_include(class_name, module_name)
          raise "Catalog already finalised" if @frozen_after_build

          list = (@struct_includes[class_name] ||= [])
          list << module_name unless list.include?(module_name)
        end

        def record_mixes_in(class_name)
          raise "Catalog already finalised" if @frozen_after_build

          @mixes_in[class_name] = true
        end

        # Issue #2541 — whether any class on `class_name`'s walked superclass chain, itself included,
        # `include`s or `prepend`s a module.
        def mixes_in_ancestry?(class_name)
          chain = []
          current = class_name.to_s.delete_prefix("::")
          until current.nil? || chain.include?(current) || STRUCT_ROOTS.include?(current)
            return true if @mixes_in.key?(current)

            chain << current
            current = resolve_superclass(current)
          end
          false
        end

        # Every walked class and module name and every assigned constant name, for the plugin's check that
        # no other `*::<name>` could shadow a top-level constant.
        def declared_constant_names
          @namespaces.keys + @constants.keys
        end

        # Issue #2541 — the classes whose constants a struct body's relative constant could reach through
        # ancestry: the class itself, its walked superclasses below the struct root, and the modules each of
        # them `include`s (as written).
        def constant_ancestry(class_name)
          chain = []
          current = class_name.to_s.delete_prefix("::")
          until current.nil? || chain.include?(current) || STRUCT_ROOTS.include?(current)
            chain << current
            current = resolve_superclass(current)
          end
          chain + chain.flat_map { |name| @struct_includes.fetch(name, []).map { |mod| mod.delete_prefix("::") } }
        end

        # @return the type source and the nesting for the accessor `signature` names, or nil when it has no type
        #   source (a conditional or type-less macro).
        def struct_prop_type(signature)
          source = @struct_prop_types[[signature.class_name, signature.method_name]]
          return nil if source.nil?

          [source, @struct_nesting.fetch(signature.class_name, [])]
        end

        # @param written — the superclass expression as written (`"T::Struct"`, `"Base"`, `"::Foo::Base"`).
        # @param lexical_prefix — the enclosing namespace names, outermost first, that Ruby resolves a
        #   relative `written` against.
        def record_superclass(class_name:, written:, lexical_prefix:)
          raise "Catalog already finalised" if @frozen_after_build

          @superclasses[class_name] ||= [written, lexical_prefix.dup.freeze].freeze
        end

        def record_defined_method(class_name:, method_name:)
          raise "Catalog already finalised" if @frozen_after_build

          list = (@defined_methods[class_name] ||= [])
          list << method_name unless list.include?(method_name)
        end

        # Issue #2541 — the signature a `prop` / `const` accessor contributes to `class_name#method_name`,
        # walking the lexical superclass chain the way Ruby's method lookup does. A class on the way that
        # `def`s the name itself (or declares it with `attr_*`) stops the walk with nil, leaving the user's
        # method to the sig lookup and the engine's own tiers. Returns nil unless the declaring class descends from a {STRUCT_ROOTS} root, so a
        # project DSL that happens to be named `prop` is never read as Sorbet's.
        def lookup_struct_prop(class_name:, method_name:)
          return nil if @struct_props.empty?

          current = class_name.to_s.delete_prefix("::")
          visited = []
          while current && !visited.include?(current)
            visited << current
            return nil if @defined_methods[current]&.include?(method_name)

            signature = @struct_props.dig(current, method_name)
            return struct_answer(signature, current) if signature

            current = resolve_superclass(current)
          end
          nil
        end

        def freeze!
          @frozen_after_build = true
          @struct_props.each_value(&:freeze)
          @struct_props.freeze
          @struct_prop_types.freeze
          @struct_nesting.freeze
          @namespaces.freeze
          @constants.freeze
          @struct_includes.each_value(&:freeze)
          @struct_includes.freeze
          @mixes_in.freeze
          @superclasses.freeze
          @defined_methods.each_value(&:freeze)
          @defined_methods.freeze
          @entries.freeze
          @mixins.each_value do |bucket|
            bucket.each_value(&:freeze)
            bucket.freeze
          end
          @mixins.freeze
          freeze
        end

        def lookup(class_name:, method_name:, kind:)
          @entries[key_for(class_name, method_name, kind)]
        end

        # @return frozen `:include` / `:extend` buckets of mixed-in module names.
        #   Returns {EMPTY_MIXINS} when no mixins were recorded.
        def mixins_for(class_name)
          @mixins[class_name] || EMPTY_MIXINS
        end

        def empty?
          @entries.empty? && @struct_props.empty?
        end

        # ADR-52 slice 4 — the distinct method names the catalog carries at least one signature for,
        # across every `(class_name, kind)` owner. Feeds the plugin's run-time `dynamic_return methods:`
        # name gate: the engine only consults the plugin for a call whose name appears here (or in the
        # static assertion vocabulary), and the precise `(class, kind)` lookup stays in the rule block.
        # Computed fresh per call — the plugin memoises the resolved set, and `freeze!` freezes the
        # catalog itself so a lazy memo ivar here would raise.
        def method_names
          names = @entries.keys.map { |key| key[1] }
          @struct_props.each_value { |props| names.concat(props.keys) }
          names.uniq
        end

        def size
          @entries.size
        end

        private

        def struct_answer(signature, declaring_class)
          root = struct_root(declaring_class)
          return nil if root.nil?
          return nil if root == IMMUTABLE_STRUCT_ROOT && signature.method_name.end_with?("=")

          signature
        end

        def struct_root(class_name)
          current = class_name
          visited = []
          while current && !visited.include?(current)
            return current if STRUCT_ROOTS.include?(current)

            visited << current
            current = resolve_superclass(current)
          end
          nil
        end

        # Resolves the superclass expression recorded for `class_name` the way Ruby's lexical constant lookup
        # would, as far as the walked sources can tell: a rooted `::Foo` is absolute; a relative `Foo` is tried
        # under each enclosing namespace, innermost first, against the classes the walk saw, then as written.
        def resolve_superclass(class_name)
          written, prefix = @superclasses[class_name]
          return nil if written.nil?
          return written.delete_prefix("::") if written.start_with?("::")

          prefix.size.downto(1) do |depth|
            candidate = "#{prefix.first(depth).join('::')}::#{written}"
            return candidate if known_class?(candidate)
          end
          written
        end

        def known_class?(name)
          @superclasses.key?(name) || @struct_props.key?(name)
        end

        def key_for(class_name, method_name, kind)
          [class_name.to_s, method_name.to_sym, kind]
        end
      end
    end
  end
end
