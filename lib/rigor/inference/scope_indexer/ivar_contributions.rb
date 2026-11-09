# frozen_string_literal: true

require_relative "../../analysis/dependency_recorder"
require_relative "../../typing_state"
require_relative "../../memo_audit"
require_relative "../../type"
require_relative "../census_foreign_block"
require_relative "../ivar_writer_census"

module Rigor
  module Inference
    module ScopeIndexer
      # Issues #2079 and #2170 — the instance-side ivar writes the class-ivar census of one file does not walk, joined
      # into the ivars that census already holds for a class `K`:
      #
      # - the writes another file's reopening of `K` makes;
      # - the writes of every project module and superclass on `K`'s instance resolution chain (`include`,
      #   `prepend`, transitively, and `<`; for a module `K`, the modules it includes or prepends), from this file's
      #   own census of that ancestor where it declares one (`writes`, taken before the read-before-write `nil` is
      #   added, so an ancestor's `initialize` exempts nothing and its read-before-write adds nothing, and only for an
      #   ivar an instance body of the ancestor writes in this file) and from every other file's entries for it.
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
        # ADR-129 WD1 — a run-scoped Memo: the table is a pure function of the census it is keyed on by identity.
        TABLE = TypingState.memo(
          :ivar_contributions_table,
          run_scoped: true, audit: "ivar contributions table",
          reason: "the contribution table of one census; keyed on the census's identity"
        )
        EMPTY = {}.freeze
        NONE = [].freeze
        BINDINGS = :bindings
        CANDIDATE_KEYS = :candidate_keys
        ANCESTOR_ROOTS = CensusForeignBlock::ANCESTOR_ROOTS.to_a.freeze
        # The one implicit root a class whose superclass chain stops at `BasicObject` keeps.
        BASIC_ROOTS = %w[BasicObject].freeze
        SEPARATOR = CensusForeignBlock::CANDIDATE_SEPARATOR
        OBJECT_MARK = CensusForeignBlock::OBJECT_MARK
        private_constant :TABLE, :EMPTY, :NONE, :BINDINGS, :CANDIDATE_KEYS, :ANCESTOR_ROOTS, :BASIC_ROOTS, :SEPARATOR,
                         :OBJECT_MARK

        module_function

        def join!(accumulator, writes, scope)
          path = scope.source_path
          return if path.nil?

          path = canonical(path)

          table = table(scope.discovered_global_write_census)
          resolution = resolution(scope, table)
          accumulator.each do |class_name, entries|
            next unless class_name.is_a?(String) && !entries.empty?

            owners = chain_owners(scope, class_name, resolution)
            any = any_ivar_types(owners, table)
            entries.each_key do |ivar|
              joined = contributed(owners, class_name, ivar, table, writes, path)
              joined = joined ? Type::Combinator.union(joined, any) : any if any
              entries[ivar] = Type::Combinator.union(entries[ivar], joined) if joined
            end
          end
        end

        # `K` and the project classes and modules on its instance chain, in chain order, with their class edges filed.
        # A module's chain holds the modules it includes or prepends (#2487): each is on the chain of every class that
        # includes the module, so its writes land on every object a read in the module's own methods sees. `extend`
        # is no instance chain entry, for a module as for a class.
        #
        # Issue #2983 — the chain is read under the `:constants` flavor, so a project class or module with no method of
        # its own (`class Anc; end`, whose writer a `class_eval` installs) is an owner too. {ANCESTOR_ROOTS}
        # (`Object`, `BasicObject`, `Kernel`) follow, as every instance has them, except that a class whose superclass
        # chain stops at `BasicObject` keeps `BasicObject` alone; then each owner's alias and instance constants
        # (`[:binds_class, …]` entries), and every candidate key that resolves to an owner ({.resolution}), under which
        # a `class_eval` rooted at that constant files its code.
        def chain_owners(scope, class_name, resolution)
          ancestors, reaches_object = ancestor_names(scope, class_name)
          names = [class_name, *ancestors, *(reaches_object ? ANCESTOR_ROOTS : BASIC_ROOTS)].uniq
          aliases, bound = resolution
          bound_names = names.flat_map do |name|
            segment = name.split("::").last
            Analysis::DependencyRecorder.read_name(:binds_class, segment) if Analysis::DependencyRecorder.active?
            bound[name] || NONE
          end
          (names + bound_names).uniq.flat_map { |owner| [owner, *(aliases[owner] || NONE)] }.uniq
        end

        # The project ancestors on `class_name`'s instance chain, and whether the chain reaches `Object`: false when a
        # superclass edge names `BasicObject`, which has neither `Object` nor `Kernel` among its ancestors.
        def ancestor_names(scope, class_name)
          chain = Scope::ResolutionChain.for(scope, class_name, :instance, :constants)
          # A guard: the class body's own `include` / `<` resolution already files these edges; kept so the read
          # states its own dependency.
          chain.record(scope) if Analysis::DependencyRecorder.active?
          names = chain.entries.filter_map do |entry|
            # An external entry has no name, so `filter_map` drops it. The side check is a guard: an instance chain
            # holds only instance-side entries.
            entry.name if entry.side == :instance && entry.name != class_name
          end
          [names, chain.entries.none? { |entry| basic_object_edge?(entry) }]
        rescue StandardError
          [NONE, true]
        end

        def basic_object_edge?(entry)
          entry.external? && entry.superclass_edge &&
            (entry.raw.to_s.delete_prefix("::") == "BasicObject" || entry.candidates.include?("BasicObject"))
        end

        # Review round 1 of #3001 — the candidate keys ({CensusForeignBlock.candidate_key}) resolved against the
        # project: each to its first candidate the project declares as a class or module, or binds as a constant, else
        # to its last (top-level) spelling, as Ruby's lexical lookup finds the nearest. Answers `[aliases, bound]`:
        # `{ resolved owner => [candidate key, ...] }` over the census's owners, and `{ resolved class => [bound
        # constant, ...] }` over its `[:binds_class, …]` entries.
        #
        # Review round 2: a candidate a signature declares (`sig/`, a gem's RBS) counts as existing too, so a nearer
        # `N::Anc` only RBS knows wins over a top-level project `Anc` and credits no project class; and a key carrying
        # {OBJECT_MARK} joins only when it resolves to an instance binding.
        def resolution(scope, table)
          bindings = table[BINDINGS] || NONE
          constants = bindings.to_set { |_, name, _| name }
          instances = bindings.filter_map { |_, name, kind| name if kind == :instance }.to_set
          bound = {}
          bindings.each { |key, name, _| (bound[resolve(scope, key, constants)] ||= []) << name }
          aliases = {}
          (table[CANDIDATE_KEYS] || NONE).each do |key|
            resolved = resolve(scope, key.delete_prefix(OBJECT_MARK), constants)
            next if key.start_with?(OBJECT_MARK) && !instances.include?(resolved)

            (aliases[resolved] ||= []) << key
          end
          [aliases, bound]
        end

        def resolve(scope, key, constants)
          candidates = key.split(SEPARATOR)
          candidates.find do |name|
            constants.include?(name) || scope.discovered_classes.key?(name) ||
              scope.discovered_superclasses.key?(name) || scope.discovered_includes.key?(name) || declared?(scope, name)
          end || candidates.last
        end

        # Whether a loaded signature declares `name` as a class, module or constant.
        def declared?(scope, name)
          loader = scope.environment&.rbs_loader
          return false if loader.nil?

          loader.class_known?(name) || !loader.constant_declaration(name).nil?
        rescue StandardError
          false
        end

        # Issue #2983 — what the owners' string `class_eval`s contribute to every ivar (`[:own_write_type, owner, :*,
        # :dynamic]`), from every file, this one included: the per-file census reads no String either.
        def any_ivar_types(owners, table)
          types = []
          owners.each do |owner|
            # A guard: a String `class_eval` also gives its module the discovery index's dynamic mark, whose edge
            # re-checks the reader when one comes or goes; kept so the read states its own dependency.
            if Analysis::DependencyRecorder.active?
              Analysis::DependencyRecorder.read_name(:own_write_type, "#{owner}##{IvarWriterCensus::ANY_IVAR}")
            end
            add_entry_types(types, table.dig(owner, IvarWriterCensus::ANY_IVAR) || EMPTY, nil)
          end
          types.empty? ? nil : Type::Combinator.union(*types)
        end

        # The union of what the owners contribute to `ivar`, or nil for nothing.
        def contributed(owners, class_name, ivar, table, writes, path)
          types = []
          owners.each do |owner|
            if Analysis::DependencyRecorder.active?
              Analysis::DependencyRecorder.read_name(:own_write_type, "#{owner}##{ivar}")
            end
            by_path = table.dig(owner, ivar) || EMPTY
            # This file's census of an ancestor counts only an ivar an instance body of it writes here. `writes` leaves
            # out an ivar a `def self.` of the ancestor also writes (the census files that write under it, #1958, and it
            # runs on the module object); this file's census entries for it join instead, as in another file (#2931).
            own = writes.dig(owner, ivar) if owner != class_name && by_path.key?(path)
            types << own if own
            add_entry_types(types, by_path, own || owner == class_name ? path : nil)
          end
          types.empty? ? nil : Type::Combinator.union(*types)
        end

        # Each census entry's value type, except those of `skipped_path` (the file whose census already holds them).
        def add_entry_types(types, by_path, skipped_path)
          by_path.each do |value_path, values|
            next if value_path == skipped_path

            values.each { |value| types << value_type(value) }
          end
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
          return build_table(census) if MemoAudit.enabled? && MemoAudit.suspended?

          state = TypingState.current
          slot = state[TABLE]
          if slot && slot[0].equal?(census)
            return MemoAudit.check("ivar contributions table", slot[1], census.size) { build_table(census) }
          end

          table = MemoAudit.key_audit("ivar contributions table") { build_table(census) }
          state[TABLE] = [census, table]
          table
        end

        # Issue #2983 — `table[BINDINGS]` lists `[class candidate key, constant name, kind]` over the census's
        # `[:binds_class, …]` entries, and `table[CANDIDATE_KEYS]` the owners that are candidate keys; no class is named
        # by a Symbol.
        def build_table(census)
          table = {}
          canonical_paths = {}
          census.each do |entry|
            next (table[BINDINGS] ||= []) << entry.drop(1) if entry[0] == :binds_class
            next unless entry.size == 5 && entry[0] == :own_write_type

            by_path = (owner_slot(table, entry[1])[entry[2]] ||= {})
            (by_path[canonical_paths[entry[4]] ||= canonical(entry[4])] ||= []) << entry[3]
          end
          table
        end

        def owner_slot(table, owner)
          table[owner] ||= begin
            (table[CANDIDATE_KEYS] ||= []) << owner if owner.include?(SEPARATOR) || owner.start_with?(OBJECT_MARK)
            {}
          end
        end

        private_class_method :chain_owners, :ancestor_names, :basic_object_edge?, :resolution, :resolve, :declared?,
                             :any_ivar_types, :contributed, :add_entry_types, :value_type, :canonical, :table,
                             :build_table, :owner_slot
      end
    end
  end
end
