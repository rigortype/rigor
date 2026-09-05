# frozen_string_literal: true

require_relative "file_collection"
require_relative "label_set"
require_relative "origin"
require_relative "summary"

module Rigor
  module Effects
    # The framework **edges** a plugin declared, materialised as effect units on the framework class itself
    # (ADR-103 WD10; design note § 11.2 "Framework edges"; #387).
    #
    # `user.save` runs `User`'s `before_save :normalize`; `WelcomeJob.perform_now` runs
    # `WelcomeJob#perform`; `UserMailer.welcome(u)` runs `UserMailer#welcome`. Each is real, synchronous,
    # in-process control flow that the *syntax* does not contain, so without the plugin the caller's
    # summary stops one hop short of the code that actually runs.
    #
    # ## Why units on the class rather than edges at the call site
    #
    # The call site is in another file. `app/controllers/users_controller.rb` writes `@user.save` and knows
    # nothing about `User`'s callbacks — those are in `app/models/user.rb`, and a per-file collection window
    # sees one file at a time. Synthesising `User#save` **where `User` is declared**, with edges to the
    # callback methods, moves the framework knowledge to the file that has it and leaves the call site an
    # ordinary edge. The propagator then resolves `(User, :instance, "save")` to the synthetic unit exactly
    # as it resolves any other, ancestry and closed-world override join included — no second mechanism, no
    # cross-file harvest, and a `save` on a subclass picks up that subclass's own callbacks for free.
    #
    # A project that defines `User#save` itself simply joins with the synthetic unit, which is the honest
    # reading: an override still runs the callbacks unless it skips them.
    #
    # ## What is deliberately not here
    #
    # `perform_later` → `perform`. The deferred body runs in another process on another stack, and ADR-103
    # WD4 fixes attribution to the code rather than to the clock: the enqueue is the effect, and the job's
    # body belongs to the job's own entry point. {Plugin::EffectEdge::TARGETS} has no spelling for it.
    module FrameworkUnits
      IO_DB_READ = LabelSet.new(["io.db.read"]).freeze
      private_constant :IO_DB_READ

      # ActiveRecord's class-body callback macros, grouped by which persistence selectors run them. The
      # grouping is coarse on purpose: an effect summary is an **upper bound**, and the cost of attributing
      # a `before_create` to `save` (which does run it, when the record is new) is nothing, while the cost of
      # a group fine enough to be wrong somewhere is a missing effect.
      VALIDATION_MACROS = %w[validate before_validation after_validation].freeze

      SAVE_MACROS = %w[
        before_save around_save after_save before_create around_create after_create
        before_update around_update after_update after_touch
        before_commit after_commit after_rollback
        after_create_commit after_update_commit after_save_commit
      ].freeze

      DESTROY_MACROS = %w[
        before_destroy around_destroy after_destroy after_destroy_commit after_commit after_rollback
      ].freeze

      # Macros whose literal symbol arguments name methods on the same class. Everything the strategy reads.
      CALLBACK_MACROS = (VALIDATION_MACROS + SAVE_MACROS + DESTROY_MACROS).uniq.freeze

      # The uniqueness validator is a `SELECT` before the write — the one validation whose effect a reviewer
      # is entitled to see in a summary. Both spellings Rails accepts.
      UNIQUENESS_MACRO = "validates_uniqueness_of"
      VALIDATES_MACRO = "validates"
      UNIQUENESS_OPTION = "uniqueness"

      # Which selectors run which group. `create` / `create!` are the singleton twins of `save`.
      SAVE_TRIGGERS = %w[save save! update update! update_attribute touch increment! decrement!].freeze
      DESTROY_TRIGGERS = %w[destroy destroy! delete].freeze
      VALIDATION_TRIGGERS = %w[valid? invalid? validate!].freeze
      SINGLETON_SAVE_TRIGGERS = %w[create create!].freeze

      # `initialize` is not a mailer action, and neither is a method a plugin would want double-counted.
      NON_ACTION_METHODS = %w[initialize].to_set.freeze

      module_function

      # Every synthetic unit `class_name` earns, as `[key, Summary, edges]` triples.
      #
      # @rbs instance_methods: Array[String] -- The instance methods the class body defines, in source order
      # @rbs macros: Hash[String, Array[String]] --
      #   Receiver-less class-body calls to their literal symbol arguments, as the scanner harvested them
      # @rbs uniqueness: bool -- Whether the class body declares a uniqueness validator
      # @rbs own_units: Hash[String, bool] --
      #   The units the class body itself defines, keyed by the suffix a synthetic key carries (`"#save"`,
      #   `".create"`), each mapped to whether that body reaches `super`. Read by {.framework_row} and by nothing
      #   else.
      def synthesize(class_name:, instance_methods:, macros:, uniqueness:, plugin_facts:, own_units: {})
        units = []
        plugin_facts.edges_for(:activerecord_callbacks).each do |edge|
          next unless plugin_facts.descends_from?(class_name, edge.receiver)

          units.concat(active_record_units(class_name, macros, uniqueness, plugin_facts, own_units))
        end
        plugin_facts.edges_for(:perform_now).each do |edge|
          next unless plugin_facts.descends_from?(class_name, edge.receiver)

          # `selector` (the edge's `method:`) names the synthesised selector, defaulting to
          # `perform_now`. The one other value it
          # ever takes is `perform_later` — and ONLY from a plugin that has read the project's own
          # `queue_adapter = :inline`, where Rails really does run the job on the caller's stack. That is a
          # project fact narrowing a transport, not a general edge (ADR-103 WD4).
          units << unit("#{class_name}.#{edge.selector || :perform_now}", [edge_to(class_name, "perform")])
        end
        plugin_facts.edges_for(:mailer_body).each do |edge|
          next unless plugin_facts.descends_from?(class_name, edge.receiver)

          units.concat(mailer_units(class_name, instance_methods))
        end
        units
      end

      # `save` and friends, edged to the callbacks the class body declared. A trigger with no callbacks and
      # no uniqueness validator is NOT synthesised: an empty unit would put `User#save` in the snapshot for
      # every model in the project and say nothing.
      def active_record_units(class_name, macros, uniqueness, plugin_facts, own_units)
        validation = callbacks(macros, VALIDATION_MACROS)
        save = validation + callbacks(macros, SAVE_MACROS)
        destroy = callbacks(macros, DESTROY_MACROS)
        read = uniqueness ? uniqueness_summary(class_name) : nil
        context = { plugin_facts: plugin_facts, own_units: own_units }

        units = []
        units.concat(triggers(class_name, SAVE_TRIGGERS, save, read, singleton: false, **context))
        units.concat(triggers(class_name, SINGLETON_SAVE_TRIGGERS, save, read, singleton: true, **context))
        units.concat(triggers(class_name, VALIDATION_TRIGGERS, validation, read, singleton: false, **context))
        units.concat(triggers(class_name, DESTROY_TRIGGERS, destroy, nil, singleton: false, **context))
        units
      end

      # ActionMailer's class-method-to-instance mapping: `UserMailer.welcome(u)` instantiates the mailer and
      # runs `#welcome`. One synthetic singleton twin per instance method the mailer defines.
      def mailer_units(class_name, instance_methods)
        instance_methods.reject { |name| NON_ACTION_METHODS.include?(name) }.uniq.map do |name|
          unit("#{class_name}.#{name}", [edge_to(class_name, name)])
        end
      end

      # A synthesised trigger exists only when the class body earned it — see {.active_record_units} — but
      # once it exists it stands for the whole of `save`, so it carries the framework's own claim about the
      # selector as well as the callbacks (#440).
      def triggers(class_name, selectors, targets, read, singleton:, plugin_facts:, own_units:)
        return [] if targets.empty? && read.nil?

        edges = targets.map { |target| edge_to(class_name, target) }
        selectors.map do |selector|
          row = framework_row(class_name, selector, singleton, plugin_facts, own_units)
          unit("#{class_name}#{singleton ? '.' : '#'}#{selector}", edges,
               declared_bundles(read, row), causes(row))
        end
      end

      # What the loaded plugins say `class_name`'s `selector` itself does — `ActiveRecord::Base#save` is
      # `io.db.write` — read off the very table a call site reads (#440).
      #
      # Without it the synthetic unit carried the validator's `SELECT` and nothing else, so a model with a
      # `before_save` or a uniqueness validator reported `AuthSource#save: ≤ io.db.read`: the write was
      # attributed at every *call site* and never on the row that names the method, which is the row a
      # reviewer reads. A `narrow:` row is skipped, because narrowing reads an argument at a call site and
      # there is no call site here.
      def framework_row(class_name, selector, singleton, plugin_facts, own_units)
        return nil if replaced?(own_units, selector, singleton)

        row = plugin_facts.class_row(class_name, singleton, selector)
        return nil if row.nil? || row.narrow || row.labels.empty?

        row
      end

      # Whether the class spelled the selector out itself and never reaches `super`. Such a body REPLACED
      # the framework's implementation, so the framework's claim no longer describes what runs: a
      # `def save = false` that persists nothing must keep reporting nothing. A body that does reach
      # `super` keeps the claim, which is the case the exemption exists to not break.
      def replaced?(own_units, selector, singleton)
        key = "#{singleton ? '.' : '#'}#{selector}"
        own_units.key?(key) && !own_units[key]
      end

      def declared_bundles(read, row)
        bundles = read ? read.dup : {}
        bundles[Origin.plugin(row.key)] = row.labels if row
        bundles
      end

      # Mirrors {UnitScan#attribute_plugin}: a row may discharge and still taint, and a row from a plugin
      # the engine does not bundle is a claim that leaves the unit non-exhaustive.
      def causes(row)
        return [] if row.nil?

        list = []
        list << [row.taint, row.key] if row.taint
        list << ["plugin-attribution", row.key] unless row.discharge?
        list
      end

      def callbacks(macros, names)
        names.flat_map { |name| macros[name] || [] }.uniq
      end

      # The uniqueness validator's own query. It rides the DECLARED lane with no taint, exactly as every
      # other first-party plugin contribution does (ADR-103 WD6): the plugin read the app's own
      # `validates … uniqueness: true` and knows what Rails does with it, but the analyzer did not read a
      # body, so this is a trusted claim rather than a proof.
      def uniqueness_summary(class_name)
        { Origin.plugin("#{class_name}:uniqueness-validator") => IO_DB_READ }
      end

      def unit(key, edges, declared = nil, causes = [])
        summary = Summary.new(declared_bundles: declared || {}, exhaustive: causes.empty?, causes: causes)
        [key, summary, edges]
      end

      def edge_to(class_name, selector)
        FileCollection::Edge.new(receiver_class: class_name, kind: :instance, selector: selector,
                                 self_call: false)
      end

      private_class_method :active_record_units, :mailer_units, :triggers, :framework_row, :replaced?,
                           :declared_bundles, :causes, :callbacks, :uniqueness_summary, :unit, :edge_to
    end
  end
end
