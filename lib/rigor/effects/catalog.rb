# frozen_string_literal: true

require "digest"
require "yaml"

require_relative "../inference/mutation_widening"
require_relative "label_set"
require_relative "mutation_classifier"
require_relative "narrowing"

module Rigor
  module Effects
    # The built-in effect catalogue — which core-library methods colour a summary, and with what
    # (ADR-103 WD3 / WD14; the data is `data/effects/core.yml`, the contract is
    # `docs/internal-spec/effect-summaries.md` § The catalogue).
    #
    # **The loader is deliberately dumb.** Every audit decision lives in the data file's `why:` lines;
    # nothing here decides what a method does. What this class adds over `YAML.safe_load` is three
    # things the data cannot express on its own:
    #
    # 1. **Per-class default postures.** A class the catalogue lists answers its posture's labels for a
    #    method it does not row, so the reading of Ruby's enormous core surface does not depend on the
    #    catalogue being complete. A class the catalogue does NOT list answers nil — contribute nothing,
    #    do not taint — which stays the reading for project and gem classes.
    # 2. **Argument-dependent narrowing.** A row's `narrow:` names a {Narrowing} handler, which reads
    #    the call's own argument literals.
    # 3. **Mutator sets by reference.** A value class names `mutators: array | hash | string` and the
    #    loader resolves it to the set the widening rules and the mutation classifier already maintain,
    #    so the two can never drift. The YAML never re-spells a mutator list.
    #
    # What this is **not** is a re-reading of `data/builtins/ruby_core/*.yml`'s `purity:` facet. That
    # facet answers fold-safety in the C-dispatch sense — `Random#rand` is `leaf`, `Array#push` is
    # `leaf` — and reading it as effect freedom would be wrong in both directions (ADR-103 WD3). This
    # loader never opens `data/builtins`, and a spec asserts it.
    class Catalog
      class Error < StandardError
      end

      DATA_PATH = File.expand_path("../../../data/effects/core.yml", __dir__)

      # The mutator sets a value class may name, by reference. Adding a name here is the only way a
      # class gets one — the data file may not spell a selector list of its own.
      MUTATOR_SETS = {
        "array" => Inference::MutationWidening::ARRAY_MUTATORS,
        "hash" => Inference::MutationWidening::HASH_MUTATORS,
        "string" => MutationClassifier::STRING_MUTATORS
      }.freeze

      NO_MUTATORS = Set[].freeze
      private_constant :NO_MUTATORS

      # What the catalogue answers for one call.
      #
      # `labels` may be empty two ways, and the difference matters: a ∅ **row** says the catalogue knows
      # this call and knows it contributes nothing (which is what stops `Thread.new` from reading as an
      # unresolved call while its block joins the enclosing method by containment), while a ∅ **posture**
      # says only that the class is a value class. Both stop the caller treating the call as unresolved;
      # only the posture keeps a project edge, because a project may reopen a core class.
      class Entry < Data.define(:labels, :mutates_receiver, :from_posture)
        def posture?
          from_posture
        end

        def mutates_receiver?
          mutates_receiver
        end
      end

      # One row of the data file, resolved. `entry` is the row's own unnarrowed {Entry}, built at load
      # time: the lookup sits inside the effect scan's walk, and every un-narrowed row hit in a project
      # answers the same value.
      Row = Data.define(:labels, :narrow, :mutates_receiver, :entry)
      private_constant :Row

      # One class of the data file, resolved: its two method buckets, its posture's labels, its mutator
      # set, and the two memoised posture {Entry}s (allocated once rather than per call — the lookup
      # sits inside the effect scan's walk).
      class ClassEntry
        attr_reader :instance_methods, :singleton_methods, :posture_labels, :singleton_posture_labels,
                    :mutators, :object

        def initialize(instance_methods:, singleton_methods:, posture_labels:, singleton_posture_labels:,
                       mutators:, object:)
          @instance_methods = instance_methods
          @singleton_methods = singleton_methods
          @posture_labels = posture_labels
          @singleton_posture_labels = singleton_posture_labels
          @mutators = mutators
          @object = object
          @entries = {
            [false, false] => Entry.new(labels: posture_labels, mutates_receiver: false, from_posture: true),
            [false, true] => Entry.new(labels: posture_labels, mutates_receiver: true, from_posture: true),
            [true, false] => Entry.new(labels: singleton_posture_labels, mutates_receiver: false,
                                       from_posture: true)
          }.freeze
          freeze
        end

        def object?
          @object
        end

        # Memoised rather than built per call — the lookup sits inside the effect scan's walk. Only the
        # instance side can be a receiver mutation, so the singleton side needs one entry.
        def posture_entry(singleton, mutating)
          @entries[[singleton, !singleton && mutating]]
        end
      end

      # The shipped catalogue. Memoised: the YAML parse is a once-per-process cost, paid on the first
      # collecting run rather than at `require "rigor"`, and inherited as-is across the fork pool
      # (workers fork after load, and nothing here ever crosses a Marshal boundary — a `FileCollection`
      # carries `LabelSet`s and Strings, never a catalogue reference).
      def self.default
        @default ||= load_file(DATA_PATH)
      end

      # Build a catalogue from a catalogue-shaped YAML file. A missing or unreadable file degrades to an
      # empty catalogue rather than raising, matching {Registry.load_file} and the built-in catalogues'
      # posture for a bare install that opted data out: every call then reads as uncatalogued, which is
      # fail-open. A file that IS present but malformed raises — that is a packaging bug, not a choice.
      def self.load_file(path)
        raw = File.exist?(path) ? YAML.safe_load_file(path) : nil
        raw = {} unless raw.is_a?(Hash)
        new(
          defaults: raw["defaults"] || {}, classes: raw["classes"] || {},
          universal: raw["universal"] || [], schema: raw.fetch("schema", 0),
          digest: file_digest(path)
        )
      end

      # A content digest of the catalogue file, so {#identity} moves when a row's audit decision moves.
      # `schema:` alone cannot carry that: it is bumped for a shape change, and the whole point of the
      # data file is that rows are edited without one. An absent file digests as `"absent"`, matching
      # {load_file}'s fail-open posture for a bare install that opted data out.
      def self.file_digest(path)
        File.file?(path) ? Digest::SHA256.file(path).hexdigest : "absent"
      rescue StandardError
        "unreadable"
      end
      private_class_method :file_digest

      attr_reader :schema, :digest

      def initialize(defaults:, classes:, universal: [], schema: 0, digest: "unknown")
        @schema = schema
        @digest = digest.to_s.freeze
        @postures = build_postures(defaults)
        @universal = universal.to_set(&:to_s).freeze
        @classes = build_classes(classes)
        @object_constants = @classes.select { |_, entry| entry.object? }.keys.to_set.freeze
        freeze
      end

      # What the effects cache identity records this catalogue as (#382, {Effects::Identity}): the schema
      # AND the content digest, so a re-audited row invalidates persisted summaries the same way a shape
      # change does.
      def identity
        "#{@schema}:#{@digest}"
      end

      # Every catalogued class name, sorted — the surface a spec walks.
      def class_names
        @classes.keys.sort
      end

      def class_entry(owner)
        @classes[owner]
      end

      # Whether `name` is a constant that names an OBJECT rather than a class, so a call on it spells
      # `ENV#[]` and not `ENV.[]`.
      def object_constant?(name)
        @object_constants.include?(name)
      end

      # What `owner#name` (or `owner.name`, with `singleton:`) contributes, or nil when the catalogue
      # has nothing to say — which is not a taint, and leaves the caller to treat the call as ordinary.
      #
      # `call_node` is the Prism call, consulted only by a row that carries a `narrow:` handler.
      # `posture:` false asks for a ROW ONLY, which is how the collector suppresses the class default
      # where it would be wrong: an implicit-self call spells `Kernel#name`, and defaulting every
      # unqualified call in a project body to `io` would colour the world.
      def lookup(owner, name, singleton: false, call_node: nil, posture: true)
        entry = @classes[owner]
        return nil if entry.nil?

        bucket = singleton ? entry.singleton_methods : entry.instance_methods
        row = bucket[name]
        return row_entry(row, call_node) if row
        return UNIVERSAL if @universal.include?(name)
        return nil unless posture

        entry.posture_entry(singleton, entry.mutators.include?(name))
      end

      # An `Object`-level selector that exists on every receiver and touches nothing. Answered as a row
      # rather than a posture, because it IS a statement about the selector.
      UNIVERSAL = Entry.new(labels: LabelSet::EMPTY, mutates_receiver: false, from_posture: false)

      private

      # A narrowed row's own `effects:` is its **unnarrowed** answer — the upper bound the handler
      # degrades to — so a caller that has no call node still gets a sound reading rather than ∅.
      def row_entry(row, call_node)
        return row.entry unless row.narrow && call_node

        Entry.new(labels: Narrowing.apply(row.narrow, call_node), mutates_receiver: row.mutates_receiver,
                  from_posture: false)
      end

      def build_postures(defaults)
        defaults.to_h { |name, labels| [name.to_s, LabelSet.new(Array(labels).map(&:to_s))] }.freeze
      end

      def build_classes(classes)
        classes.to_h { |name, body| [name.to_s, build_class(name.to_s, body || {})] }.freeze
      end

      def build_class(name, body)
        mutators = resolve_mutators(name, body["mutators"])
        ClassEntry.new(
          instance_methods: build_rows(name, body["methods"], mutators),
          singleton_methods: build_rows(name, body["singleton_methods"], nil),
          posture_labels: resolve_posture(name, body["posture"]),
          singleton_posture_labels: resolve_posture(name, body["singleton_posture"] || body["posture"]),
          mutators: mutators,
          object: body["kind"] == "object"
        )
      end

      def resolve_posture(class_name, posture)
        return LabelSet::EMPTY if posture.nil?

        @postures[posture.to_s] ||
          raise(Error, "#{class_name}: unknown posture #{posture.inspect}; add it to the catalogue's defaults:")
      end

      def resolve_mutators(class_name, named)
        return NO_MUTATORS if named.nil?

        set = MUTATOR_SETS[named.to_s] ||
              raise(Error, "#{class_name}: unknown mutator set #{named.inspect}")
        set.to_set(&:to_s).freeze
      end

      def build_rows(class_name, rows, mutators)
        return EMPTY_ROWS if rows.nil?

        rows.to_h do |name, body|
          key = name.to_s
          [key, build_row("#{class_name}##{key}", body || {}, mutators&.include?(key) == true)]
        end.freeze
      end

      def build_row(key, body, in_mutator_set)
        narrow = body["narrow"]&.to_s
        raise Error, "#{key}: unknown narrowing handler #{narrow.inspect}" if narrow && !Narrowing.known?(narrow)
        raise Error, "#{key}: every catalogue row needs a `why:` justification" if body["why"].to_s.empty?

        labels = LabelSet.new(Array(body["effects"]).map(&:to_s))
        mutates_receiver = body["mutates"].to_s == "receiver" || in_mutator_set
        Row.new(
          labels: labels,
          narrow: narrow,
          mutates_receiver: mutates_receiver,
          entry: Entry.new(labels: labels, mutates_receiver: mutates_receiver, from_posture: false)
        )
      end

      EMPTY_ROWS = {}.freeze
      private_constant :EMPTY_ROWS
    end
  end
end
