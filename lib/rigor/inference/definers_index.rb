# frozen_string_literal: true

require_relative "../run_scoped_slots"

module Rigor
  module Inference
    # The `method_name (Symbol) → [owner names]` inverted index the override gate reads
    # (`ExpressionTyper#method_definers_index`), over one instance or singleton def table.
    #
    # Issue #2300 — a file's def table is its own `def`s merged over the cross-file seed
    # (`ScopeIndexer#merge_def_node_tables`, `#merge_singleton_def_nodes`, then the #526 extend fold), a new Hash per
    # file. Inverting it whole scanned every project `def` once per analysed file. {.record_layers} remembers the
    # seed a final merged table was built over, and {.for} then inverts the seed ONCE per seed table and, per file,
    # only the owners whose inner table is not the seed's own object ({Layered}).
    #
    # The two answers hold the same owners: an owner the merge left alone shares the seed's inner table, so its
    # names are the seed's, and every other owner is read from the merged table itself. That holds only while the
    # seed cannot change under the cached index, so a seed whose tables are not all frozen, or a merged table
    # missing one of the seed's owners, is inverted whole, as is a table {.record_layers} was not told about. Only
    # the order of a name's owners can differ, and the gate asks `any?` of the list.
    module DefinersIndex
      # These thread slots are bounded, like `ExpressionTyper#method_definers_index`'s two ways. Each is a fixed
      # number of entries, replaced rather than accumulated: two `[merged, seed]` pairs (the last file's two def
      # tables) and two seed indexes. The run that filled them releases them when it ends ({RunScopedSlots}, #2399),
      # so a finished run keeps none of its seed tables or their indexes alive.
      LAYERS_KEY = RunScopedSlots.register(:__rigor_definers_index_layers__)
      SEED_INDEX_KEY = RunScopedSlots.register(:__rigor_definers_index_seed__)
      SEED_INDEX_ALT_KEY = RunScopedSlots.register(:__rigor_definers_index_seed_alt__)
      private_constant :LAYERS_KEY, :SEED_INDEX_KEY, :SEED_INDEX_ALT_KEY

      # A name's owners: the seed's, less the owners the file replaced, plus the replaced owners' own.
      class Layered
        def initialize(seed_index, replaced, replaced_index)
          @seed_index = seed_index
          @replaced = replaced
          @replaced_index = replaced_index
          @answers = {}
        end

        def [](method_name)
          return @answers[method_name] if @answers.key?(method_name)

          from_seed = @seed_index[method_name]
          from_seed = from_seed.reject { |owner| @replaced.key?(owner) } if from_seed && !@replaced.empty?
          from_file = @replaced_index[method_name]
          owners = from_file.nil? ? from_seed : (from_seed || []) + from_file
          @answers[method_name] = owners.nil? || owners.empty? ? nil : owners
        end
      end

      module_function

      # Records that the final `merged` table was built over `seed`. The last two are kept (a file merges an
      # instance and a singleton table), replaced rather than accumulated.
      def record_layers(merged, seed)
        previous = Thread.current[LAYERS_KEY]
        Thread.current[LAYERS_KEY] = [[merged, seed], previous&.first].compact
      end

      # The definers index over `table`.
      def for(table)
        seed = Thread.current[LAYERS_KEY]&.find { |entry| entry[0].equal?(table) }&.last
        return build(table) if seed.nil? || !deeply_frozen?(seed)

        replaced = {}
        kept = 0
        table.each do |owner, methods|
          if methods.equal?(seed[owner])
            kept += 1
          else
            replaced[owner] = methods
          end
        end
        return build(table) unless kept + replaced.count { |owner, _| seed.key?(owner) } == seed.size

        Layered.new(seed_index(seed), replaced, build(replaced))
      end

      def deeply_frozen?(seed)
        seed.frozen? && seed.each_value.all?(&:frozen?)
      end

      # The seed's index, built once per seed table. Two ways, an instance and a singleton seed table.
      def seed_index(seed)
        [SEED_INDEX_KEY, SEED_INDEX_ALT_KEY].each do |key|
          slot = Thread.current[key]
          return slot[1] if slot && slot[0].equal?(seed)
        end
        index = build(seed)
        Thread.current[SEED_INDEX_ALT_KEY] = Thread.current[SEED_INDEX_KEY]
        Thread.current[SEED_INDEX_KEY] = [seed, index]
        index
      end

      def build(table)
        index = {}
        table.each do |class_name, methods|
          next if class_name == ScopeIndexer::TOP_LEVEL_DEF_KEY

          methods.each_key { |method_name| (index[method_name] ||= []) << class_name }
        end
        index
      end
    end
  end
end
