# frozen_string_literal: true

module TypingStateReachability
  # Analyses `paths` in one sequential run with no cache and walks a sample of its `ExpressionTyper#type_of` calls.
  # The calls are counted per analysed file (the typed scope's `source_path`), and a file's call is sampled when its
  # count is `offset` modulo `stride`, so one file's sample does not shift when another file types more or less. Every
  # memo holder seen is checked once more when the run ends ({Walker#finish}).
  def self.sample(paths, stride:, offset: 0, &run)
    walker = Walker.new
    counts = Hash.new(0)
    trace = TracePoint.new(:call) do |point|
      scope = point.self.instance_variable_get(:@scope)
      count = (counts[scope.source_path] += 1)
      walker.sample(scope, Rigor::TypingState.current) if count % stride == offset
    end
    configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => paths, "workers" => 0))
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    trace.enable(target: Rigor::Inference::ExpressionTyper.instance_method(:type_of)) do
      run ? run.call(runner) : runner.run(paths)
    end
    walker.finish
  end

  # ADR-129 G4 — walks the object graph a `type_of` call can reach, from its scope and from the thread's TypingState
  # slot values, and reports every mutable object no declaration accounts for. Used by
  # `spec/rigor/typing_state_reachability_spec.rb`.
  #
  # How a reached object is read:
  # - an immediate, a module, a Prism object or an RBS object is accepted and not walked ({SKIPPED_NAMESPACES}). A
  #   module is a leaf: its class-level instance variables are G3's to flag (`typing_state_closure_spec.rb`);
  # - a Proc or a Method is a finding whether frozen or not: what it closes over (its binding, its receiver) is not
  #   walked, so it needs a row saying what it captures. A Hash's `default_proc` is walked as one of its children;
  # - a frozen object is accepted, and its contents are walked;
  # - what a Memo holds (a {Rigor::TypingState.memo_field}, a Memo slot, a Frame's declared `memos:` member) and what a
  #   Resource holds (a Resource slot, a `contents: :resource` Frame's installed value) is accepted and not walked:
  #   a Memo's purity is `MemoAudit`'s to check, and every touch of a Resource refuses the capture;
  # - the container of a Table (a Table slot's value, a {Rigor::TypingState.store_field}, a `contents: :table`
  #   Frame's installed value) is accepted, and its entries are walked: a hit validates and replays entries by
  #   identity, so an entry mutated in place would escape the journal;
  # - an unfrozen object of a class that declares a memo field (a **memo holder**) is accepted, and its other fields
  #   are walked; each must keep the object it held when the holder was first reached, checked at every later sample
  #   and once more by {#finish}, or it is reported as `reassigned`;
  # - anything else unfrozen is a finding.
  #
  # A finding is keyed by its **field**: the instance variable (or Data or Struct member, or slot) of the nearest
  # non-container object that holds it. It carries the classes found there and the first path that reached it. What a
  # Memo or a Resource holds is accepted whole, so an object first reached through an ordinary field is not reported
  # when that object, or one it was reached through, is accepted whole or as a Table container in the same sample.
  class Walker
    # Library object graphs typing reads but does not own: Prism's parse results (a node is accepted outright, ADR-129
    # G4) and RBS's environment and definitions, which `RbsLoader`'s Memo fields hold and which would dominate the
    # walk.
    SKIPPED_NAMESPACES = %w[Prism:: RBS::].freeze

    CONTAINERS = [Hash, Array, Set].freeze
    MAX_PATH = 12

    Finding = Struct.new(:classes, :path)

    # `observed` is every field label the walk passed through, whatever it held: a ratchet row is stale only when its
    # field is never observed, since whether a field holds something mutable at a given sample is sparse evidence.
    attr_reader :findings, :samples, :visits, :observed

    # `fields` and `slots` default to the declared {Rigor::TypingState.fields} and {Rigor::TypingState.slots}; the
    # walker's own examples pass their own.
    def initialize(fields: Rigor::TypingState.fields, slots: Rigor::TypingState.slots)
      @fields = fields.group_by(&:owner)
      @slots = slots
      @field_cache = {}.compare_by_identity
      @skip_cache = {}.compare_by_identity
      @deep_frozen = {}.compare_by_identity
      @snapshots = {}.compare_by_identity
      @findings = {}
      @observed = Set.new
      @samples = 0
      @visits = 0
    end

    # Walks one sample: the typer's scope, and the slot values of the thread's TypingState.
    def sample(scope, state)
      @samples += 1
      @visited = {}.compare_by_identity
      @accepted = {}.compare_by_identity
      @whole = {}.compare_by_identity
      @pending = {}.compare_by_identity
      @stack = []
      visit(scope, "scope", ["scope"])
      @slots.each { |slot| visit_slot(slot, state[slot.index]) }
      @pending.each do |object, (field, path, ancestors)|
        next if @accepted.key?(object) || @whole.key?(object) || ancestors.any? { |ancestor| @whole.key?(ancestor) }

        report(field, object.class, path)
      end
    end

    # Compares every memo holder seen with the fields it held when first reached, so a field assigned after that is
    # reported whatever the sampling phase was.
    def finish
      @snapshots.each { |holder, (before, path)| check_reassigned(holder, before, path) }
      self
    end

    private

    def visit_slot(slot, value)
      return if value.nil?

      label = "slot :#{slot.name}"
      @observed << label
      case slot_mode(slot)
      when :whole then accept(value)
      when :table then visit_table(value, label, [label])
      else visit_frame(slot, value, label)
      end
    end

    def slot_mode(slot)
      return :whole if %i[memo resource].include?(slot.kind) || slot.contents == :resource
      return :table if slot.kind == :table || slot.contents == :table

      :frame
    end

    # A Frame's installed value is walked like any other object, except the members or keys it declares as Memos.
    def visit_frame(slot, value, label)
      memos = slot.memos
      return visit(value, label, [label]) if memos.nil?

      @visits += 1
      report_unless_frozen(value, label, [label])
      each_child(value, label) do |child, child_field, _kind, step|
        @observed << child_field
        memos.include?(step.delete_prefix(".").to_sym) ? accept(child) : visit(child, child_field, [label, step])
      end
    end

    # A Table's container is accepted (an object, or a plain container); its entries are walked.
    def visit_table(container, field, path)
      @accepted[container] = true
      @visits += 1
      @stack.push(container)
      each_child(container, field) do |child, child_field, _kind, step|
        @observed << child_field
        visit(child, child_field, [*path, step])
      end
      @stack.pop
    end

    def accept(object)
      @whole[object] = true unless immediate?(object)
    end

    # Returns true when nothing mutable is reachable from `object`. A frozen object found so is remembered for good:
    # a frozen object never thaws, and its references never change. Inside a cycle an object's answer is optimistic
    # until the cycle closes, so an object whose subtree met an open cycle is remembered as `:tainted`: a later visit
    # in the same sample passes the taint on, and it is never cached across samples.
    def visit(object, field, path) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
      return true if immediate?(object) || @deep_frozen.key?(object)

      seen = @visited[object]
      if seen == :open
        @cycle = true
        return true
      end
      unless seen.nil?
        @cycle = true if seen == :tainted
        return seen != :shallow
      end
      return true if skipped?(object.class)

      if object.is_a?(Proc) || object.is_a?(Method)
        record_closure(object, field, path)
        return false
      end

      @visits += 1
      @visited[object] = :open
      immutable = object.frozen?
      report_unless_frozen(object, field, path) unless immutable || memo_holder?(object, path)

      deep = immutable
      outer_cycle = @cycle
      @cycle = false
      @stack.push(object)
      each_child(object, field) do |child, child_field, kind, step|
        child_path = path.size < MAX_PATH ? [*path, step] : path
        @observed << child_field
        case kind
        when :memo
          accept(child)
          deep = false
        when :store
          visit_table(child, child_field, child_path) unless immediate?(child)
          deep = false
        else
          deep = false unless visit(child, child_field, child_path)
        end
      end
      @stack.pop
      cycle_free = !@cycle
      @cycle = outer_cycle || @cycle
      @visited[object] = if deep
                           cycle_free ? :deep : :tainted
                         else
                           :shallow
                         end
      @deep_frozen[object] = true if deep && immutable && cycle_free
      deep
    end

    # A Proc or a Method: reported, never walked.
    def record_closure(object, field, path)
      @visits += 1
      @visited[object] = :shallow
      @pending[object] ||= [field, path, @stack.dup]
      nil
    end

    def report_unless_frozen(object, field, path)
      @pending[object] ||= [field, path, @stack.dup] unless object.frozen?
    end

    # Yields each child with the field that holds it, the declared kind of that field (`:memo`, `:store` or nil) and a
    # path step.
    def each_child(object, field)
      case object
      when Hash
        yield object.default_proc, field, nil, ".default_proc" if object.default_proc
        object.each do |key, value|
          yield key, field, nil, "{}"
          yield value, field, nil, (key.is_a?(Symbol) ? ".#{key}" : "[]")
        end
      when Array, Set then object.each { |value| yield value, field, nil, "[]" }
      when String then nil
      when Struct, Data
        name = class_name(object.class)
        object.to_h.each { |member, value| yield value, "#{name}##{member}", nil, ".#{member}" }
      else
        name = class_name(object.class)
        declared = fields_of(object.class)
        object.instance_variables.each do |ivar|
          yield object.instance_variable_get(ivar), "#{name}##{ivar}", declared[ivar]&.kind, "#{name}##{ivar}"
        end
      end
    end

    # An unfrozen object whose class declares a memo field is accepted; each of its undeclared instance variables
    # must hold the object it held when the holder was first reached, or it is reported as reassigned.
    def memo_holder?(object, path)
      declared = fields_of(object.class)
      return false unless declared.each_value.any? { |field| field.kind == :memo }

      before, = (@snapshots[object] ||= [undeclared_fields(object, declared), path])
      check_reassigned(object, before, path)
      true
    end

    def undeclared_fields(object, declared)
      object.instance_variables.reject { |ivar| declared.key?(ivar) }
            .to_h { |ivar| [ivar, object.instance_variable_get(ivar)] }
    end

    def check_reassigned(object, before, path)
      name = class_name(object.class)
      current = undeclared_fields(object, fields_of(object.class))
      (before.keys | current.keys).each do |ivar|
        next if before.key?(ivar) && current.key?(ivar) && before[ivar].equal?(current[ivar])

        report("#{name}##{ivar}", :reassigned, [*path, "#{name}##{ivar}"])
      end
    end

    def report(field, klass, path)
      finding = (@findings[field] ||= Finding.new(Set.new, path.join(" > ")))
      finding.classes << (klass.is_a?(Symbol) ? klass.to_s : class_name(klass))
    end

    def immediate?(object)
      case object
      when Integer, Float, Symbol, NilClass, TrueClass, FalseClass, Module then true
      else false
      end
    end

    def class_name(klass) = klass.name || klass.inspect

    def fields_of(klass)
      @field_cache[klass] ||= klass.ancestors.flat_map { |ancestor| @fields.fetch(ancestor, []) }
                                   .to_h { |field| [field.ivar, field] }
    end

    def skipped?(klass)
      return @skip_cache[klass] if @skip_cache.key?(klass)

      name = klass.name.to_s
      @skip_cache[klass] = SKIPPED_NAMESPACES.any? { |prefix| name.start_with?(prefix) }
    end
  end
end
