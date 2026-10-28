# frozen_string_literal: true

require_relative "../../analysis/dependency_recorder"
require_relative "../../run_scoped_slots"
require_relative "../../type"
require_relative "../refined_dispatch/own_method"

module Rigor
  module Inference
    module ScopeIndexer
      # Issues #2079 and #2170 — the instance-side ivar writes the class-ivar census of one file does not walk, joined
      # into the ivars that census already holds for a class `K`:
      #
      # - the writes another file's reopening of `K` makes;
      # - the writes of every project module and superclass on `K`'s instance resolution chain (`include`,
      #   `prepend`, transitively, and `<`), from this file's own census of that ancestor where it declares one
      #   (`writes`, taken before the read-before-write `nil` is added, so an ancestor's `initialize` exempts nothing
      #   and its read-before-write adds nothing, and only for an ivar an instance body of the ancestor writes in this
      #   file) and from every other file's entries for it.
      #
      # Another file's write comes from its `[:own_write_type, owner, ivar, value, path]` census entry
      # ({IvarWriterCensus}): a literal joins as its `Constant`, anything else as `Dynamic[top]`. An ivar the census
      # has no entry for gains none, so a read of an ivar only another file writes still reads `Dynamic[top]`. The
      # join only widens, and every joined type is in the seed, so a `nil` it brings is declaration-sourced (ADR-58
      # WD1). A file the scope names no path for (a census built outside the project pre-pass, `rigor sig-gen`'s
      # unseeded scopes) joins nothing.
      #
      # ADR-46: each ivar read files `own_write_type:<owner>#<ivar>` for `K` and each chain owner, which the
      # incremental session fires when a file's entries for the pair appear, vanish or change value; and the chain
      # files its class edges ({Scope::ResolutionChain#record}), so an `include` added or removed re-checks the reader.
      module IvarContributions
        TABLE_KEY = RunScopedSlots.register(:__rigor_ivar_contributions_table__)
        EMPTY = {}.freeze
        private_constant :TABLE_KEY, :EMPTY

        module_function

        def join!(accumulator, writes, scope)
          path = scope.source_path
          return if path.nil?

          path = canonical(path)

          table = table(scope.discovered_global_write_census)
          accumulator.each do |class_name, entries|
            next unless class_name.is_a?(String) && !entries.empty?

            owners = chain_owners(scope, class_name)
            entries.each_key do |ivar|
              joined = contributed(owners, class_name, ivar, table, writes, path)
              entries[ivar] = Type::Combinator.union(entries[ivar], joined) if joined
            end
          end
        end

        # `K` and the project classes and modules on its instance chain, in chain order, with their class edges filed.
        # A module's own census takes no chain: its ancestors' writes land on whatever includes it.
        def chain_owners(scope, class_name)
          return [class_name] if RefinedDispatch::OwnMethod.module_name?(scope, class_name)

          chain = Scope::ResolutionChain.for(scope, class_name, :instance, :methods)
          # A guard: the class body's own `include` / `<` resolution already files these edges; kept so the read
          # states its own dependency.
          chain.record(scope) if Analysis::DependencyRecorder.active?
          ancestors = chain.entries.filter_map do |entry|
            # An external entry has no name, so `filter_map` drops it. The side check is a guard: an instance chain
            # holds only instance-side entries.
            entry.name if entry.side == :instance && entry.name != class_name
          end
          [class_name, *ancestors.uniq]
        rescue StandardError
          [class_name]
        end

        # The union of what the owners contribute to `ivar`, or nil for nothing.
        def contributed(owners, class_name, ivar, table, writes, path)
          types = []
          owners.each do |owner|
            if Analysis::DependencyRecorder.active?
              Analysis::DependencyRecorder.read_name(:own_write_type, "#{owner}##{ivar}")
            end
            by_path = table.dig(owner, ivar) || EMPTY
            # This file's census of an ancestor counts only an ivar an instance body of it writes here: the census
            # also holds a `def self.` write of a module (#1958), which runs on the module object.
            own = writes.dig(owner, ivar) if owner != class_name && by_path.key?(path)
            types << own if own
            by_path.each do |value_path, values|
              next if value_path == path

              values.each { |value| types << value_type(value) }
            end
          end
          types.empty? ? nil : Type::Combinator.union(*types)
        end

        # A String literal joins as `String`, not its `Constant`: a write elsewhere cannot see an in-place mutation of
        # the String (`@s << "abc"`) in this file, in another or in an ancestor, so the value would be pinned too
        # narrowly. Every other literal kind is immutable and joins as its `Constant`.
        def value_type(value)
          return Type::Combinator.untyped unless value.is_a?(Array)

          literal = value[1]
          literal.is_a?(String) ? Type::Combinator.nominal_of("String") : Type::Combinator.constant_of(literal)
        end

        # `path` resolved through symlinks, so a file the pre-pass tagged under one spelling (`/tmp/…`) is the one
        # analysed under another (`/private/tmp/…`); the expanded spelling when it cannot be resolved.
        def canonical(path)
          File.realpath(path)
        rescue SystemCallError
          File.expand_path(path)
        end

        # `{ owner => { ivar => { path => [value, ...] } } }` over `census`'s path-tagged `:own_write_type` entries,
        # built once per census and kept in one run-scoped slot keyed by its identity.
        def table(census)
          slot = Thread.current[TABLE_KEY]
          return slot[1] if slot && slot[0].equal?(census)

          table = {}
          canonical_paths = {}
          census.each do |entry|
            next unless entry.size == 5 && entry[0] == :own_write_type

            by_path = ((table[entry[1]] ||= {})[entry[2]] ||= {})
            (by_path[canonical_paths[entry[4]] ||= canonical(entry[4])] ||= []) << entry[3]
          end
          Thread.current[TABLE_KEY] = [census, table]
          table
        end
        private_class_method :chain_owners, :contributed, :value_type, :canonical, :table
      end
    end
  end
end
