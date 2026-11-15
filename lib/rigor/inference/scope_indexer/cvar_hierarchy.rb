# frozen_string_literal: true

module Rigor
  module Inference
    module ScopeIndexer
      # Issue #3219 — Ruby keeps one class-variable slot for a class and its subclasses: a subclass's `@@x` reads and
      # writes the slot a superclass created, and a slot a subclass created first is overtaken (a `RuntimeError`) once
      # the superclass writes the name. The class-cvar census keys each class on its own, so this joins, into each
      # entry a class's own `def` write created, every write of the same cvar that another class of its in-file
      # superclass tree makes, `join_only` writes (a class body's, `class_variable_set`) included.
      #
      # The tree is the classes linked by `class Sub < Base` headers whose superclass names a class this file
      # declares. When the topmost class names a superclass the file does not declare (a class another file or a
      # signature declares, one nothing declares, or a non-constant expression such as `Struct.new(:a)`), the writes
      # that superclass makes are unseen, so every entry of the tree also joins `Dynamic[top]`. An implicit or
      # explicit `Object` / `BasicObject` superclass ends the tree. A module's entries stay as they are: a module's
      # cvar is shared with its includers, which this does not follow (#3222).
      module CvarHierarchy
        # The superclass a header names that the tree cannot follow.
        OPEN = :open
        # The superclasses that end a tree, as an implicit superclass does.
        ROOTS = %w[Object BasicObject].freeze
        private_constant :OPEN, :ROOTS

        module_function

        # `{ declared: { name => :class | :module }, superclasses: { name => [[raw, nesting], ...] } }`, filled by
        # {.record} as the census walk enters each header.
        def headers = { declared: {}, superclasses: {} }

        # A header that names its class: an unnameable one (below `class <<`) keys no census entry. `raw` is the
        # as-written superclass name ({ScopeIndexer.recorded_ancestor_name}, nil for a non-constant expression) and
        # `nesting` the `Module.nesting` outside the header, where Ruby resolves it (nil when the walk lost it).
        def record(headers, node, context, body)
          # A header below `class <<` that names no class leaves the prefix empty, `singleton_cref` included.
          return if body.prefix.empty?

          name = body.prefix.join("::")
          klass = node.is_a?(Prism::ClassNode)
          headers[:declared][name] = klass ? :class : (headers[:declared][name] || :module)
          return unless klass && node.superclass

          (headers[:superclasses][name] ||= []) << [ScopeIndexer.recorded_ancestor_name(node.superclass),
                                                    context.nesting]
        end

        # `accumulator` (the census before {ScopeIndexer#finished_cvar_census}) with each class's entries joined
        # along its tree, as a new Hash; `scope` answers whether a name is declared outside the file.
        def join(accumulator, headers, scope)
          return accumulator if accumulator.empty? || headers[:superclasses].empty?

          parents = headers[:superclasses].to_h { |name, sites| [name, parent(sites, headers, scope)] }
          roots = {}
          root = ->(name) { roots[name] ||= root_of(name, parents, headers, scope) }
          trees = (accumulator.keys | parents.keys).group_by(&root)
          unions = {}
          accumulator.to_h do |class_name, entries|
            key = root.call(class_name)
            tree = trees.fetch(key)
            next [class_name, entries] if tree.size == 1 && !key[1]

            [class_name, entries.to_h do |cvar, type|
              next [cvar, type] if type.is_a?(JoinOnlyCvarWrite)

              [cvar, unions[[key, cvar]] ||= tree_union(tree, cvar, accumulator, key[1])]
            end]
          end
        end

        # Every write of `cvar` in `tree`, `Dynamic[top]` too when the tree is open: the one seed each entry of the
        # tree a creating write made joins to, built once per tree and cvar.
        def tree_union(tree, cvar, accumulator, open)
          writes = tree.filter_map do |member|
            write = accumulator.dig(member, cvar)
            write.is_a?(JoinOnlyCvarWrite) ? write.type : write
          end
          writes << Type::Combinator.untyped if open
          Type::Combinator.union(*writes)
        end

        # `[root, open]`: the topmost class above `name` and whether the tree cannot see all of its superclass's
        # writes: the topmost class names a superclass {.parent} cannot follow, or names none in this file while
        # another source declares it ({.reopened_elsewhere?}), so its superclass is not known to be `Object`.
        def root_of(name, parents, headers, scope)
          seen = [name]
          while (up = parents[name])
            return [name, true] if up == OPEN || seen.include?(up)

            seen << (name = up)
          end
          [name, !parents.key?(name) && reopened_elsewhere?(name, headers, scope)]
        end

        # Whether a class this file reopens without a superclass header is declared elsewhere with one it may
        # name: another file's header (`discovered_superclasses`) or a bundled signature (core, stdlib, a gem).
        # A class only the project's own `sig/` declares stays rooted, as that signature mirrors the source.
        def reopened_elsewhere?(name, headers, scope)
          return false unless headers[:declared][name] == :class

          return true if scope.discovered_superclasses.key?(name)

          loader = scope.environment&.rbs_loader
          !loader.nil? && loader.class_known?(name) && !loader.project_declared_class?(name)
        rescue StandardError
          true
        end

        # The in-file class every header of a class names as its superclass, nil for `Object` / `BasicObject`, or
        # {OPEN}: for a superclass outside the file, a non-constant one, or headers that disagree.
        def parent(sites, headers, scope)
          resolved = sites.map { |raw, nesting| resolve(raw, nesting, headers, scope) }.uniq
          resolved.size == 1 ? resolved.first : OPEN
        end

        # Ruby's lexical lookup of a superclass name: the first candidate this file declares, else the first that
        # something outside the file declares, read as {OPEN}.
        def resolve(raw, nesting, headers, scope)
          return OPEN if raw.nil? || nesting.nil?

          candidates = raw.start_with?("::") ? [raw.delete_prefix("::")] : [*nesting.map { "#{it}::#{raw}" }, raw]
          candidates.each do |candidate|
            kind = headers[:declared][candidate]
            return kind == :class ? candidate : OPEN if kind
            return nil if ROOTS.include?(candidate)
            return OPEN if declared_elsewhere?(scope, candidate)
          end
          OPEN
        end

        def declared_elsewhere?(scope, name)
          scope.discovered_classes.key?(name) || scope.discovered_superclasses.key?(name) ||
            scope.environment&.rbs_loader&.class_known?(name) || false
        rescue StandardError
          true
        end

        private_class_method :tree_union, :root_of, :reopened_elsewhere?, :parent, :resolve, :declared_elsewhere?
      end
    end
  end
end
