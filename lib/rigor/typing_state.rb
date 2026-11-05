# frozen_string_literal: true

module Rigor
  # ADR-129 WD1–WD3 — the one owner of the mutable state typing reads and writes.
  #
  # Every piece of that state is a **slot** declared here with one of four kinds, where its owner names it
  # (`RETURN_SINK = TypingState.frame(:return_sink, …)`), and a deny-by-default static spec
  # (`spec/rigor/typing_state_closure_spec.rb`, ADR-129's G3) rejects any other state in a file it
  # covers. The kind decides how a future `type_of` memo treats the slot, so the memo needs no knowledge of any
  # particular one:
  #
  # - **Frame** ({.frame}): an input installed for a dynamic extent with {State#with}, restored exactly on the way
  #   out, and frozen while installed. A frame whose installed object is a container mutated in place (a jump sink,
  #   the key-presence walk) declares `contents: :resource`: the installation is the Frame, and each mutation of
  #   the contents is a Resource touch ({State#touch}, {State#rewrite}). The installed value may also hold
  #   extensional caches its owner fills in place: those are Memos by kind and take no touch.
  # - **Table** ({.table}): a keyed store typing writes and may read back. Its reads and writes are logged to the
  #   journal ({State#log_read}, {State#log_write}) while a capture is open. A table that answers what reading
  #   ABSENT would have computed declares `read_through: true` (WD1). A table whose stores are held elsewhere, one per
  #   owner (the advisory tables each file's scopes share, an installed recorder), declares `bound: true` and logs
  #   through {State#log_bound_read} / {State#log_bound_write}, which name the store beside the key.
  # - **Resource** ({.resource}): state consumed or rewritten in place, or read as a delta. A write refuses every
  #   open capture (the `any` rule, WD3); so does a read, unless the slot declares one of WD3's two read exemptions
  #   (`:id_determined`, `:delta_internal`).
  # - **Memo** ({.memo}): an extensional cache keyed on all its inputs. Unlogged.
  #
  # Typing also reaches state that is not a slot value: the instance variables of the objects a scope holds. ADR-129's
  # G4 (`spec/rigor/typing_state_reachability_spec.rb`) walks everything reachable from a scope and the slot values,
  # and accepts a mutable object only where a declaration names it: an extensional cache an object fills in place
  # ({.memo_field}), or the store of a bound Table ({.store_field}).
  #
  # The values live in one {State} per thread (per fiber, as `Thread.current[]` is), cached by the typer and the
  # evaluator, so a slot read is an ivar and an array index. Each slot constant is the slot's integer index, which
  # keeps the declaration Ractor-shareable and the read an `Array#[]`.
  #
  # Stage 1 (ADR-129 WD6) adds no caching: no capture is opened outside the specs, so the journal stays empty and
  # every touch is a size check.
  module TypingState
    KINDS = %i[frame table resource memo].freeze
    READ_EXEMPTIONS = %i[id_determined delta_internal].freeze

    # One declared slot: its name, kind and index, why it is the kind it is, and its kind's options.
    # - `run_scoped`: a Table, Memo or Resource whose contents belong to one analysis run, emptied by
    #   {.release_run_scoped} when the run ends ({RunScopedSlots.release}).
    # - `read_exemption`: a Resource, or a `contents: :resource` Frame's contents, whose reads do not refuse (WD3).
    # - `contents`: `:resource` for a Frame whose installed container is mutated in place, `:table` for one whose
    #   installed container is a store of a bound Table, whose entries are journaled rather than touched.
    # - `read_through`: a Table that is a read-through cache of the computation's own value (WD1).
    # - `bound`: a Table whose stores are not the slot's value but objects its owner holds, several at once (a store
    #   per file's scopes, per installed recorder); its journal records key on `[store, key]`.
    # - `audit`: a Memo's `MemoAudit.check` labels, the hit sites that recompute and compare (WD1, G2).
    # - `memos`: a Frame's members or keys that hold Memos its owner fills in place (G4 accepts them).
    # - `computed`: a Table filled by a computation (the ADR-84 return memo), the `MemoAudit.key_audit` label of its
    #   miss (WD1's key audit, G2).
    # - `entries`: a Table's entry protocol ({StoreEntries}), how the journal reads and writes one of its entries.
    Slot = Data.define(:name, :kind, :index, :reason, :run_scoped, :read_exemption, :contents, :read_through, :bound,
                       :audit, :memos, :computed, :entries)

    # A field declared outside the slots: `kind` is `:memo` ({.memo_field}) or `:store` ({.store_field}, whose `slot`
    # names the bound Table).
    Field = Data.define(:owner, :ivar, :kind, :slot, :reason)

    # A Table read of a key the table does not hold logs this rather than nil, so a stored nil and a miss differ.
    ABSENT = Object.new.freeze

    # ADR-129 WD3 — a Table's entry protocol: how the journal reaches one entry of a store, to validate a logged read
    # ({State#stale_read}), replay a logged write ({State#replay}) and note the value a write replaces
    # ({State#open_priors}). A Table names its protocol as `entries:`; this one is the default, for a store that answers
    # `fetch(key, default)` and `[]=` (a Hash, or a recorder's accumulator built to that shape). A protocol module
    # answers:
    # - `entry(store, key)`: the value at `key`, or {ABSENT}, for a nil store too (an unbound table not created yet);
    # - `put(store, key, value)`: stores `value` at `key` the way the table's own writer does;
    # - `container(state, slot)`: the store an unbound table's replay writes into, the one `state` holds in `slot` or
    #   one it creates there the way the table's writer does.
    #
    # Records index their stores by identity and their keys by `eql?`, which is identity for the Prism nodes most
    # tables key on (`Prism::Node` defines neither `==` nor `hash`) and what each store's own lookup uses for the rest.
    module StoreEntries
      module_function

      def entry(store, key) = store.nil? ? ABSENT : store.fetch(key, ABSENT)

      def put(store, key, value)
        store[key] = value
      end

      def container(state, slot) = state[slot] || (state[slot] = {})
    end

    # The entry protocol of a Table whose slot holds an `ObjectSpace::WeakKeyMap` ({State#weak_key_map}), which has no
    # `fetch`.
    module WeakKeyMapEntries
      module_function

      def entry(store, key) = store&.key?(key) ? store[key] : ABSENT

      def put(store, key, value)
        store[key] = value
      end

      def container(state, slot) = state.weak_key_map(slot)
    end

    # The read and write slices of a computation that logged nothing.
    EMPTY_SLICES = [[].freeze, [].freeze].freeze

    # A read slice's fourth element when the read is not a read-through cache's ABSENT read of a key the computation
    # then wrote; a write's prior when the writer did not pass one ({State#log_write}).
    NONE = Object.new.freeze
    private_constant :NONE

    STATE_KEY = :__rigor_typing_state__
    private_constant :STATE_KEY

    # The registry and the run-scoped indices, each replaced by a frozen copy on every declaration so a non-main
    # Ractor can read them. Declarations run at require time, on the main Ractor.
    @slots = [].freeze
    @run_scoped = [].freeze
    @fields = [].freeze

    class << self
      # Declares a Frame slot and returns its index. A `contents: :resource` frame may declare a read exemption for
      # reads of its contents. `memos` names the members (a Data or Struct value) or keys (a Hash value) of the
      # installed value that hold extensional caches its owner fills in place, Memos by kind, which `reason` explains.
      def frame(name, reason:, contents: nil, read_exemption: nil, memos: nil)
        unless [nil, :resource, :table].include?(contents)
          raise ArgumentError, "#{name}: contents must be :resource, :table or nil"
        end
        if read_exemption && contents != :resource
          raise ArgumentError, "#{name}: only a contents: :resource frame declares a read exemption"
        end

        check_read_exemption(name, read_exemption)
        declare(name, :frame, reason, contents: contents, read_exemption: read_exemption,
                                      memos: memos && Array(memos).freeze)
      end

      # Declares a Table slot and returns its index. A `bound` table's stores live with their owners, so the slot holds
      # nothing a run could release. A table a computation fills on a miss names the miss's `MemoAudit.key_audit` label
      # as `computed`. `entries` names the table's entry protocol ({StoreEntries}, the default).
      def table(name, reason:, run_scoped: false, read_through: false, bound: false, computed: nil,
                entries: StoreEntries)
        raise ArgumentError, "#{name}: a bound table holds no run-scoped value" if bound && run_scoped
        unless %i[entry put container].all? { |method| entries.respond_to?(method) }
          raise ArgumentError, "#{name}: entries must answer entry, put and container"
        end

        declare(name, :table, reason, run_scoped: run_scoped, read_through: read_through, bound: bound,
                                      computed: computed, entries: entries)
      end

      # Declares a Resource slot and returns its index.
      def resource(name, reason:, read_exemption: nil, run_scoped: false)
        check_read_exemption(name, read_exemption)
        declare(name, :resource, reason, read_exemption: read_exemption, run_scoped: run_scoped)
      end

      # Declares a Memo slot and returns its index. `audit` names the `MemoAudit.check` labels its hits go through;
      # a spec (`spec/rigor/typing_state_memo_audit_spec.rb`) holds every Memo to them, or to its stage-2 ratchet.
      def memo(name, reason:, run_scoped: false, audit: nil)
        labels = Array(audit)
        declare(name, :memo, reason, run_scoped: run_scoped, audit: labels.empty? ? nil : labels)
      end

      # Declares that `owner`'s instances fill each of `ivars` in place, or assign it lazily, as an extensional cache
      # keyed on all its inputs: a Memo that lives outside a slot. `reason` says why it is extensional. G4 accepts
      # what such a field holds without walking it, and accepts an unfrozen `owner` whose other fields keep their
      # objects.
      def memo_field(owner, *ivars, reason:)
        raise ArgumentError, "#{owner}: memo_field names at least one field" if ivars.empty?

        ivars.each { |ivar| declare_field(owner, ivar, :memo, reason, nil) }
        nil
      end

      # Declares that `owner`'s instance variable `ivar` holds a store of the bound Table `slot` (an index from
      # {.table} with `bound: true`), whose entries are journaled through the slot.
      def store_field(owner, ivar, slot)
        declared = @slots.fetch(slot)
        raise ArgumentError, "#{declared.name}: only a bound table has stores in fields" unless declared.bound

        declare_field(owner, ivar, :store, declared.reason, declared.name)
      end

      # Every declared slot, in declaration order (a slot's index is its position).
      attr_reader :slots

      # Every field declared with {.memo_field} or {.store_field}, as `Field` values.
      attr_reader :fields

      # The slot declared as `name`. For specs and diagnostics; the hot path reads by index.
      def slot(name)
        @slots.find { |slot| slot.name == name } || raise(KeyError, "no typing-state slot #{name.inspect}")
      end

      # The calling thread's state, created on first use. The `is_a?` test types the answer as a {State} for Rigor's
      # own analysis of its callers, where a bare `Thread.current[]` read is `Dynamic`.
      def current
        state = Thread.current[STATE_KEY]
        return state if state.is_a?(State)

        Thread.current[STATE_KEY] = State.new
      end

      # Empties every run-scoped slot on the calling thread, the TypingState half of {RunScopedSlots.release}.
      def release_run_scoped
        state = Thread.current[STATE_KEY]
        state&.release(@run_scoped)
        nil
      end

      private

      def check_read_exemption(name, read_exemption)
        return if read_exemption.nil? || READ_EXEMPTIONS.include?(read_exemption)

        raise ArgumentError, "#{name}: read_exemption must be one of #{READ_EXEMPTIONS.inspect} or nil"
      end

      def declare_field(owner, ivar, kind, reason, slot_name)
        raise ArgumentError, "#{owner}##{ivar}: a field is an instance variable" unless ivar.to_s.start_with?("@")
        raise ArgumentError, "#{owner}##{ivar}: a field names why it is its kind" if reason.to_s.strip.empty?
        if @fields.any? { |field| field.owner.equal?(owner) && field.ivar == ivar }
          raise ArgumentError, "#{owner}##{ivar} is already declared"
        end

        field = Field.new(owner: owner, ivar: ivar, kind: kind, slot: slot_name, reason: reason.dup.freeze)
        @fields = Ractor.make_shareable([*@fields, field])
        nil
      end

      def declare(name, kind, reason, run_scoped: false, read_exemption: nil, contents: nil, read_through: false, # rubocop:disable Metrics/ParameterLists
                  bound: false, audit: nil, memos: nil, computed: nil, entries: nil)
        if @slots.any? { |slot| slot.name == name }
          raise ArgumentError, "typing-state slot #{name.inspect} is already declared"
        end
        raise ArgumentError, "#{name}: a slot names why it is its kind" if reason.to_s.strip.empty?

        index = @slots.size
        slot = Slot.new(name: name, kind: kind, index: index, reason: reason.dup.freeze, run_scoped: run_scoped,
                        read_exemption: read_exemption, contents: contents, read_through: read_through, bound: bound,
                        audit: audit, memos: memos, computed: computed, entries: entries)
        @slots = Ractor.make_shareable([*@slots, slot])
        @run_scoped = [*@run_scoped, index].freeze if run_scoped
        index
      end
    end

    # ADR-129 WD3 — a {State}'s reach into the Table entries its journal names: reading one ({#entry}), splitting a
    # capture's records into the slices an entry keeps ({#slices}), validating a read slice ({#stale_read}), replaying a
    # write slice ({#replay}), and the priors windows that note what each write replaced ({#open_priors}).
    module Slices
      # The value the Table `slot` holds at `key`, a journal record's key (`[store, key]` for a bound table), or
      # {ABSENT}.
      def entry(slot, key)
        declared = TypingState.slots[slot]
        return declared.entries.entry(key[0], key[1]) if declared.bound

        declared.entries.entry(@values[slot], key)
      end

      # Splits a capture's records ({#close_capture}) into the slices a stored entry keeps (WD3), as a frozen pair:
      # - the read slice, four entries per read `(slot, key, observed, own)`: every read of a key the computation had
      #   not written yet (a read of its own write is internal). `own` is the value the computation last wrote at that
      #   key when the table is a read-through cache and the read observed {ABSENT}, else an internal marker;
      # - the write slice, three entries per write `(slot, key, value)`, in order.
      def slices(records)
        return EMPTY_SLICES if records.empty?

        reads = []
        writes = []
        written = nil
        index = 0
        while index < records.size
          slot = records[index + 1]
          key = records[index + 2]
          value = records[index + 3]
          if records[index] == :write
            writes.push(slot, key, value)
            (written ||= KeyIndex.new).store(slot, key, value)
          elsif written.nil? || !written.key?(slot, key)
            reads.push(slot, key, value, NONE)
          end
          index += 4
        end
        attach_own_writes(reads, written) if written
        [reads.freeze, writes.freeze].freeze
      end

      # The slot of the first read in `reads` (a read slice, {#slices}) that no longer holds: the table holds a value
      # other than the one observed, by identity, {ABSENT} included, unless the table is a read-through cache, the
      # read observed {ABSENT} and the table now holds what the computation itself wrote there. nil when all hold.
      def stale_read(reads)
        index = 0
        while index < reads.size
          return reads[index] unless read_holds?(reads, index)

          index += 4
        end
        nil
      end

      # Every slot with a read in `reads` that no longer holds ({#stale_read}), each once, in first-failure order.
      def stale_slots(reads)
        slots = []
        index = 0
        while index < reads.size
          slot = reads[index]
          slots << slot unless slots.include?(slot) || read_holds?(reads, index)
          index += 4
        end
        slots
      end

      # Replays `writes` (a write slice, {#slices}) in order, through each table's entry protocol, journaling each write
      # as its writer would (WD3: the replay is itself journaled).
      def replay(writes)
        index = 0
        while index < writes.size
          slot = writes[index]
          key = writes[index + 1]
          value = writes[index + 2]
          note_prior(slot, key, NONE) if @priors
          put(slot, key, value)
          @journal.push(:write, slot, key, value) unless @marks.empty?
          index += 3
        end
        nil
      end

      # Opens a priors window: until {#close_priors}, the first write of each Table entry notes the value it replaced.
      # Windows nest, and a write is noted in every open window that has not seen its key. A window opens only inside
      # a capture, since some writers log only while one is open, and closes before that capture does.
      def open_priors
        raise ArgumentError, "a priors window opens inside a capture" unless capturing?

        (@priors ||= []) << [KeyIndex.new, []]
        nil
      end

      # Closes the innermost priors window and answers what it noted, three entries per entry `(slot, key, prior)` in
      # first-write order, {ABSENT} for an entry the table did not hold.
      def close_priors
        _, noted = @priors.pop
        @priors = nil if @priors.empty?
        noted.freeze
      end

      private

      # Stores `value` at `key` (a journal record's key) in the Table `slot`, creating an unbound table's store.
      def put(slot, key, value)
        declared = TypingState.slots[slot]
        return declared.entries.put(key[0], key[1], value) if declared.bound

        entries = declared.entries
        entries.put(entries.container(self, slot), key, value)
      end

      def read_holds?(reads, index)
        current = entry(reads[index], reads[index + 1])
        return true if current.equal?(reads[index + 2])

        own = reads[index + 3]
        !NONE.equal?(own) && current.equal?(own)
      end

      # Gives each read-through table's ABSENT read in `reads` the value the computation last wrote at its key.
      def attach_own_writes(reads, written)
        index = 0
        while index < reads.size
          slot = reads[index]
          key = reads[index + 1]
          if ABSENT.equal?(reads[index + 2]) && TypingState.slots[slot].read_through && written.key?(slot, key)
            reads[index + 3] = written.fetch(slot, key)
          end
          index += 4
        end
      end

      # Notes in every open priors window that has not seen `key` the value `slot` holds there now, or `prior` when the
      # writer passed it.
      def note_prior(slot, key, prior)
        @priors.each do |seen, noted|
          next if seen.key?(slot, key)

          prior = entry(slot, key) if NONE.equal?(prior)
          seen.store(slot, key, true)
          noted.push(slot, key, prior)
        end
      end
    end

    # One thread's typing state: the slot values, the state id (WD2), and the journal (WD3).
    #
    # **The state id** is an integer that names the installed Frame values. Every install takes a fresh one, and the
    # frame restores the saved one on the way out. Because Frame values are frozen, equal ids mean equal frames: no
    # interning or hashing. An id-determined Resource (WD3) keeps that property: the guard stack's push and pop each
    # take a fresh id ({#push}, {#pop}), and a rewrite in place ({#rewrite}) also moves the **epoch**, so a frame
    # that saw one exits to a fresh id rather than to its saved one, which named the contents before the rewrite.
    #
    # **The journal** is one flat array of Table reads and writes, four entries per record (`:read` or `:write`, the
    # slot, the key, the value or {ABSENT}). A capture is a start mark in it plus a refusal flag. Records are kept
    # only while a capture is open, and the journal empties when the outermost capture closes.
    class State
      include Slices

      attr_reader :id

      def initialize
        @values = []
        @id = 0
        @last_id = 0
        @epoch = 0
        @journal = []
        @marks = []
        @refused = []
        @priors = nil
      end

      # A Frame or Memo read, or a Table's container.
      def [](slot) = @values[slot]

      # A Frame read only to decide whether to install it at a constant for the extent that follows (the return memo
      # turning the key-presence walk off): whichever way it goes, that extent reads the constant, so the key audit
      # ({KeyAudit}) does not note it. Any other read goes through {#[]}.
      def forcing_read(slot) = @values[slot]

      # A Frame read as a term of a memo key (ADR-129 WD1's key audit): the value {#[]} answers. Under the key audit
      # ({KeyAudit}) the read is also noted, so the audit compares what the key carries with what its miss read.
      def key_frame(slot) = @values[slot]

      # The state id read as a term of a memo key: it names every installed Frame value (WD2), so a key carrying it
      # carries every Frame.
      def key_state_id = @id

      # A Memo write, or a Table's container (an entry's own write is {#log_write}).
      def []=(slot, value)
        @values[slot] = value
      end

      # Runs the block with `value` installed in the Frame `slot`, under a fresh state id, and restores both.
      def with(slot, value)
        values = @values
        previous = values[slot]
        saved_id = @id
        saved_epoch = @epoch
        values[slot] = value
        @id = (@last_id += 1)
        begin
          yield
        ensure
          values[slot] = previous
          @id = @epoch == saved_epoch ? saved_id : (@last_id += 1)
        end
      end

      # {#with} for two Frames installed together, under one fresh id.
      def with_pair(slot, value, other, other_value)
        values = @values
        previous = values[slot]
        other_previous = values[other]
        saved_id = @id
        saved_epoch = @epoch
        values[slot] = value
        values[other] = other_value
        @id = (@last_id += 1)
        begin
          yield
        ensure
          values[slot] = previous
          values[other] = other_previous
          @id = @epoch == saved_epoch ? saved_id : (@last_id += 1)
        end
      end

      # {#with} for nil installed in each Frame of `slots` (a frozen Array), under one fresh id.
      def without(slots)
        values = @values
        previous = slots.map { |slot| values[slot] }
        saved_id = @id
        saved_epoch = @epoch
        slots.each { |slot| values[slot] = nil }
        @id = (@last_id += 1)
        begin
          yield
        ensure
          index = 0
          while index < slots.size
            values[slots[index]] = previous[index]
            index += 1
          end
          @id = @epoch == saved_epoch ? saved_id : (@last_id += 1)
        end
      end

      # A Resource write, a read the slot does not exempt, or a write to a `contents: :resource` Frame's container:
      # refuses every open capture (the `any` rule, WD3).
      def touch(_slot)
        refused = @refused
        refused.fill(true) unless refused.empty?
        nil
      end

      # A Resource read the slot does not exempt.
      def read(slot)
        touch(slot)
        @values[slot]
      end

      # A Resource write.
      def write(slot, value)
        touch(slot)
        @values[slot] = value
      end

      # The Resource container in `slot`, created by the block on first use: a read the slot does not exempt, and a
      # write when it creates. Callers mutate the container in place after this touch.
      def acquire(slot)
        touch(slot)
        values = @values
        values[slot] || (values[slot] = yield)
      end

      # Appends `value` to the append-only Resource log in `slot`, creating it on first use: a write.
      def append(slot, value)
        touch(slot)
        (@values[slot] ||= []) << value
      end

      # The id-determined Resource stack in `slot`, created empty on first use. Reading it is exempt (WD3: its value
      # is fixed while the id is), and creating it changes no contents; {#push} and {#pop} are its writes.
      def stack(slot) = @values[slot] ||= []

      # Pushes `value` onto the id-determined Resource stack in `slot`, creating it on first use: a write, under a
      # fresh id.
      def push(slot, value)
        touch(slot)
        @id = (@last_id += 1)
        (@values[slot] ||= []) << value
      end

      # Pops the id-determined Resource stack in `slot`: a write, under a fresh id. The stack holds what it held
      # before the matching {#push}, so the epoch stays.
      def pop(slot)
        touch(slot)
        @id = (@last_id += 1)
        @values[slot].pop
      end

      # The contents of the id-determined `slot` (a Resource, or a `contents: :resource` Frame's container) were
      # rewritten in place: a write, under a fresh id, and a new epoch, so no frame open now restores an id that
      # named the old contents.
      def rewrite(slot)
        touch(slot)
        @epoch += 1
        @id = (@last_id += 1)
        nil
      end

      # The `ObjectSpace::WeakKeyMap` a Table or Memo `slot` holds, created on first use.
      def weak_key_map(slot) = @values[slot] ||= ObjectSpace::WeakKeyMap.new

      # Logs a Table read of `key` in `slot` that observed `value` ({ABSENT} for a miss), while a capture is open.
      def log_read(slot, key, value)
        @journal.push(:read, slot, key, value) unless @marks.empty?
        nil
      end

      # Logs a Table write of `value` at `key` in `slot`, while a capture is open. A writer logs before it stores, so
      # while a priors window is open ({#open_priors}) the value the write replaces is still there to note; a writer
      # that knows it (a set-only add, whose prior is {ABSENT}) passes it as `prior` and may log after.
      def log_write(slot, key, value, prior = NONE)
        note_prior(slot, key, prior) if @priors
        @journal.push(:write, slot, key, value) unless @marks.empty?
        nil
      end

      # Logs a read of `key` in `store`, one of the bound Table `slot`'s stores, that observed `value` ({ABSENT} for a
      # miss), while a capture is open. The record's key is the frozen pair `[store, key]`, built only then, so a run
      # with no capture open allocates nothing.
      def log_bound_read(slot, store, key, value)
        @journal.push(:read, slot, [store, key].freeze, value) unless @marks.empty?
        nil
      end

      # Logs a write of `value` at `key` in `store`, one of the bound Table `slot`'s stores, while a capture is open,
      # before the store changes or with the replaced value as `prior` ({#log_write}).
      def log_bound_write(slot, store, key, value, prior = NONE)
        return if @marks.empty?

        pair = [store, key].freeze
        note_prior(slot, pair, prior) if @priors
        @journal.push(:write, slot, pair, value)
        nil
      end

      # Opens a capture over the journal from here; the innermost open capture closes first.
      def open_capture
        @marks << @journal.size
        @refused << false
        nil
      end

      # Closes the innermost capture and returns `[refused, records]`: whether a touch refused it, and the journal
      # records logged while it was open, nested captures' included, as a frozen flat array.
      def close_capture
        mark = @marks.pop
        refused = @refused.pop
        records = @journal[mark..].freeze
        @journal.clear if @marks.empty?
        [refused, records]
      end

      # Whether a capture is open.
      def capturing? = !@marks.empty?

      # Whether a priors window is open ({#open_priors}).
      def noting_priors? = !@priors.nil?

      # Empties the slots at `indices` ({TypingState.release_run_scoped}).
      def release(indices)
        values = @values
        indices.each { |index| values[index] = nil }
        nil
      end

      # The names of the slots holding a value other than nil or an empty collection: what a finished run left
      # behind. For specs.
      def holding
        TypingState.slots.filter_map do |slot|
          value = @values[slot.index]
          slot.name unless value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end
      end
    end

    # A set of Table entries named by journal record keys, with a value each: the stores of a bound table by
    # identity (`[store, key]` pairs are never hashed whole, since `Array#hash` would hash a Hash store by its
    # contents), the keys by `eql?` ({StoreEntries}).
    class KeyIndex
      def initialize
        @tables = {}
      end

      def key?(slot, key)
        keys = keys_for(slot, key, false)
        !keys.nil? && keys.key?(entry_key(slot, key))
      end

      def fetch(slot, key) = keys_for(slot, key, false).fetch(entry_key(slot, key))

      def store(slot, key, value)
        keys_for(slot, key, true)[entry_key(slot, key)] = value
      end

      private

      def entry_key(slot, key) = TypingState.slots[slot].bound ? key[1] : key

      def keys_for(slot, key, create)
        tables = @tables
        if TypingState.slots[slot].bound
          stores = tables[slot] || (create ? (tables[slot] = {}.compare_by_identity) : nil)
          return nil if stores.nil?

          stores[key[0]] || (create ? (stores[key[0]] = {}) : nil)
        else
          tables[slot] || (create ? (tables[slot] = {}) : nil)
        end
      end
    end

    # ADR-129 WD2's ELIDE, measured by stage 3's shadow only: a second id that, unlike the state id, stays put when an
    # install puts back the value the slot already holds (`equal?`), so two frames that differ only by such an install
    # share it. Every other install, every id-determined Resource change and every rewrite moves it exactly as the
    # state id moves, so equal ELIDE ids still name equal Frame values. `TypeOfMemo` extends a thread's state with this
    # module when the measurement is on and keys on {#elide_id}; the state id, which other memos key on, is unchanged.
    module ElideId
      attr_reader :elide_id

      def self.extended(state) = state.restart_elide_id

      # A fresh ELIDE id, naming the Frame values installed now.
      def restart_elide_id
        @last_elide_id = (@last_elide_id || 0) + 1
        @elide_id = @last_elide_id
        nil
      end

      def with(slot, value)
        values = @values
        elide_install(values[slot].equal?(value)) { super }
      end

      def with_pair(slot, value, other, other_value)
        values = @values
        elide_install(values[slot].equal?(value) && values[other].equal?(other_value)) { super }
      end

      def without(slots)
        values = @values
        elide_install(slots.all? { |slot| values[slot].nil? }) { super }
      end

      def push(slot, value)
        result = super
        @elide_id = (@last_elide_id += 1)
        result
      end

      def pop(slot)
        result = super
        @elide_id = (@last_elide_id += 1)
        result
      end

      def rewrite(slot)
        super
        @elide_id = (@last_elide_id += 1)
        nil
      end

      private

      # Runs the block, an install, under a fresh ELIDE id unless the install puts back what the slots hold, and
      # restores the id on the way out unless an id-determined Resource was rewritten inside it.
      def elide_install(same)
        saved = @elide_id
        saved_epoch = @epoch
        @elide_id = (@last_elide_id += 1) unless same
        begin
          yield
        ensure
          @elide_id = @epoch == saved_epoch ? saved : (@last_elide_id += 1)
        end
      end
    end

    # ADR-129 WD1's key audit, on one {State}: `MemoAudit` extends a thread's state with this module the first time an
    # audited run reaches a memo miss, so a run with the audit off reads a slot through the plain {State#[]}.
    #
    # While a miss computation runs ({#open_key_audit} .. {#close_key_audit}, nested for a miss inside a miss) every
    # Frame read is noted on each open audit, except a read of a Frame installed since that audit opened: the
    # computation installed it itself, so it is internal (the return memo's `with_return_sink`). A read an inner audit
    # declares a known gap reaches the audits around it as that gap, named through the inner audit's label: the outer
    # value is computed from the inner one. {#collect_key_terms} notes the Frames a key builder reads through
    # {State#key_frame} and {State#key_state_id}.
    module KeyAudit
      # The key term {State#key_state_id} notes: the id names every installed Frame.
      STATE_ID = :state_id

      def self.extended(state) = state.send(:start_key_audit)

      def [](slot)
        note_frame_read(slot) unless @key_audits.empty?
        super
      end

      def key_frame(slot)
        @key_terms&.push(slot)
        note_frame_read(slot) unless @key_audits.empty?
        super
      end

      def key_state_id
        @key_terms&.push(STATE_ID)
        super
      end

      def with(slot, value)
        @key_installs.push(slot)
        begin
          super
        ensure
          @key_installs.pop
        end
      end

      def with_pair(slot, value, other, other_value)
        installs = @key_installs
        installs.push(slot, other)
        begin
          super
        ensure
          installs.pop(2)
        end
      end

      def without(slots)
        installs = @key_installs
        installs.concat(slots)
        begin
          super
        ensure
          installs.pop(slots.size)
        end
      end

      # Runs the block, a key builder, and remembers the key it answers with the Frame terms it read, for the
      # {#key_terms_for} of the miss that follows. Answers the key.
      def collect_key_terms
        saved = @key_terms
        terms = @key_terms = []
        key = yield
        @last_key = [key, terms.uniq.freeze]
        key
      ensure
        @key_terms = saved
      end

      # The Frame terms (slot indices, or {STATE_ID}) the key builder of `key` read, or an empty list when `key` is not
      # the last key {#collect_key_terms} built (a memo whose key reads no Frame passes nil).
      def key_terms_for(key)
        last = @last_key
        last && !key.nil? && last[0].equal?(key) ? last[1] : EMPTY_TERMS
      end

      # Opens the audit of the miss computation `label` names, whose site declares `gaps` (slot name => reason).
      def open_key_audit(label, gaps)
        @key_audits.push([@key_installs.size, {}, label, gaps])
        nil
      end

      # Closes the innermost audit and answers what its computation read from outside it: `slot => true` for a read of
      # its own, or `slot => [inner label, reason]` for one an audit nested in it declared a gap.
      def close_key_audit
        @key_audits.pop[1]
      end

      EMPTY_TERMS = [].freeze
      private_constant :EMPTY_TERMS

      private

      def start_key_audit
        @key_audits = []
        @key_installs = []
        @key_terms = nil
        @last_key = nil
      end

      # Innermost audit first: an audit whose computation installed the slot, and every audit around it, read it
      # internally.
      def note_frame_read(slot)
        declared = TypingState.slots[slot]
        return unless declared.kind == :frame

        at = @key_installs.rindex(slot)
        audits = @key_audits
        gap = nil
        index = audits.size - 1
        while index >= 0
          mark, reads, label, gaps = audits[index]
          break if at && at >= mark

          if gap
            reads[slot] ||= gap
          else
            reads[slot] = true
            reason = gaps[declared.name]
            gap = [label, reason].freeze if reason
          end
          index -= 1
        end
      end
    end
  end
end
