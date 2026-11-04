# frozen_string_literal: true

module Rigor
  module Inference
    # ADR-129 WD1–WD3 — the one owner of the mutable state typing reads and writes.
    #
    # Every piece of that state is a **slot** declared here with one of four kinds, where its owner names it
    # (`RETURN_SINK = TypingState.frame(:return_sink, …)`), and a deny-by-default static spec
    # (`spec/rigor/inference/typing_state_closure_spec.rb`, ADR-129's G3) rejects any other state in a file it
    # covers. The kind decides how a future `type_of` memo treats the slot, so the memo needs no knowledge of any
    # particular one:
    #
    # - **Frame** ({.frame}): an input installed for a dynamic extent with {State#with}, restored exactly on the way
    #   out, and frozen while installed. A frame whose installed object is a container mutated in place (a jump sink,
    #   the key-presence walk) declares `contents: :resource`: the installation is the Frame, and each mutation of
    #   the contents is a Resource touch ({State#touch}, {State#rewrite}).
    # - **Table** ({.table}): a keyed store typing writes and may read back. Its reads and writes are logged to the
    #   journal ({State#log_read}, {State#log_write}) while a capture is open. A table that answers what reading
    #   ABSENT would have computed declares `read_through: true` (WD1).
    # - **Resource** ({.resource}): state consumed or rewritten in place, or read as a delta. A write refuses every
    #   open capture (the `any` rule, WD3); so does a read, unless the slot declares one of WD3's two read exemptions
    #   (`:id_determined`, `:delta_internal`).
    # - **Memo** ({.memo}): an extensional cache keyed on all its inputs. Unlogged.
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
      # - `run_scoped`: a Table or Memo whose contents belong to one analysis run, emptied by
      #   {.release_run_scoped} when the run ends ({RunScopedSlots.release}).
      # - `read_exemption`: a Resource, or a `contents: :resource` Frame's contents, whose reads do not refuse (WD3).
      # - `contents`: `:resource` for a Frame whose installed container is mutated in place.
      # - `read_through`: a Table that is a read-through cache of the computation's own value (WD1).
      Slot = Data.define(:name, :kind, :index, :reason, :run_scoped, :read_exemption, :contents, :read_through)

      # A Table read of a key the table does not hold logs this rather than nil, so a stored nil and a miss differ.
      ABSENT = Object.new.freeze

      STATE_KEY = :__rigor_typing_state__
      private_constant :STATE_KEY

      # The registry and the run-scoped indices, each replaced by a frozen copy on every declaration so a non-main
      # Ractor can read them. Declarations run at require time, on the main Ractor.
      @slots = [].freeze
      @run_scoped = [].freeze

      class << self
        # Declares a Frame slot and returns its index. A `contents: :resource` frame may declare a read exemption for
        # reads of its contents.
        def frame(name, reason:, contents: nil, read_exemption: nil)
          raise ArgumentError, "#{name}: contents must be :resource or nil" unless [nil, :resource].include?(contents)
          if read_exemption && contents.nil?
            raise ArgumentError, "#{name}: only a contents: :resource frame declares a read exemption"
          end

          check_read_exemption(name, read_exemption)
          declare(name, :frame, reason, contents: contents, read_exemption: read_exemption)
        end

        # Declares a Table slot and returns its index.
        def table(name, reason:, run_scoped: false, read_through: false)
          declare(name, :table, reason, run_scoped: run_scoped, read_through: read_through)
        end

        # Declares a Resource slot and returns its index.
        def resource(name, reason:, read_exemption: nil)
          check_read_exemption(name, read_exemption)
          declare(name, :resource, reason, read_exemption: read_exemption)
        end

        # Declares a Memo slot and returns its index.
        def memo(name, reason:, run_scoped: false)
          declare(name, :memo, reason, run_scoped: run_scoped)
        end

        # Every declared slot, in declaration order (a slot's index is its position).
        attr_reader :slots

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

        def declare(name, kind, reason, run_scoped: false, read_exemption: nil, contents: nil, read_through: false)
          if @slots.any? { |slot| slot.name == name }
            raise ArgumentError, "typing-state slot #{name.inspect} is already declared"
          end
          raise ArgumentError, "#{name}: a slot names why it is its kind" if reason.to_s.strip.empty?

          index = @slots.size
          slot = Slot.new(name: name, kind: kind, index: index, reason: reason.dup.freeze, run_scoped: run_scoped,
                          read_exemption: read_exemption, contents: contents, read_through: read_through)
          @slots = Ractor.make_shareable([*@slots, slot])
          @run_scoped = [*@run_scoped, index].freeze if run_scoped
          index
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
        attr_reader :id

        def initialize
          @values = []
          @id = 0
          @last_id = 0
          @epoch = 0
          @journal = []
          @marks = []
          @refused = []
        end

        # A Frame or Memo read, or a Table's container.
        def [](slot) = @values[slot]

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

        # Logs a Table write of `value` at `key` in `slot`, while a capture is open.
        def log_write(slot, key, value)
          @journal.push(:write, slot, key, value) unless @marks.empty?
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
    end
  end
end
