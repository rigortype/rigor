# frozen_string_literal: true

require "digest"

require_relative "entry_points"
require_relative "label_set"
require_relative "registry"

module Rigor
  module Effects
    # The loaded plugins' effect contributions, compiled once per process into the tables the scan and the
    # snapshot read (ADR-103 WD2 / WD6 / WD10 / WD14; #387).
    #
    # A plugin's manifest states its contribution declaratively — `effect_labels:`, `effect_attributions:`,
    # `effect_edges:`, `effect_entry_points:`, all frozen value objects. Nothing here re-reads a manifest at
    # scan time: the per-call lookup is two Hash reads and, for a class-name row, a walk up a superclass
    # table that is a Hash read per level.
    #
    # **Nothing builds one unless collection is on.** {Plugin::Registry#effect_contributions} is itself
    # lazy — a plugin MAY compute its rows from project facts, and rigor-activejob does — and this class is
    # what turns the result into indices. {.build} is called from exactly one place on each side of the fork
    # boundary, behind `configuration.effects_enabled?`, so a `rigor check` with no `effects:` block neither
    # allocates one nor lets a plugin read a file for it.
    #
    # ## Two matching rules, because the framework has two shapes
    #
    # A **class-name** row (`ActiveRecord::Base#save`) matches through the project's inheritance chain:
    # `user.save` on a `User < ApplicationRecord < ActiveRecord::Base` is the whole point, and matching the
    # exact owner (which is what {Catalog} does, correctly, for Ruby's core) would find nothing. The chain
    # walked is the **project's own** superclass table — the cross-file discovery pre-pass's
    # `discovered_superclasses`, the same table `ExpressionTyper` walks for an unresolved implicit-self
    # call. It stops where the project stops, which is exactly right: `ApplicationRecord < ActiveRecord::Base`
    # is a line in `app/models/application_record.rb`, and a class that never names a framework base in
    # project source is not one.
    #
    # A **receiver-path** row (`Rails.cache#read`) matches the receiver *expression* as written. `Rails.cache`
    # returns an adapter-dependent object by design — memory, Redis, the filesystem — so there is no receiver
    # class for a class-name row to key on, and the only stable handle is the path the programmer typed.
    #
    # ## What is deliberately not consulted
    #
    # The RBS ancestor chain. A gem's shipped signatures do carry `class User < ApplicationRecord`-shaped
    # ancestry when the project generates RBS for its models, but reading it here would make a row's reach a
    # function of whether the project happens to run `rbs prototype` — a plugin contribution that appears and
    # disappears with an unrelated tool. The project's own `class … <` lines are the fact; a project whose
    # models are declared only in RBS gets no plugin attribution and no taint, which is the fail-quiet
    # direction.
    class PluginFacts
      # How far the superclass walk climbs before giving up. A project hierarchy deeper than this is either
      # pathological or cyclic, and a cycle is possible in a project's *as-written* table.
      ANCESTRY_CAP = 24

      NO_ROWS = {}.freeze
      private_constant :NO_ROWS

      # One compiled attribution row.
      #
      # `discharge` is the RESOLVED grant, not the manifest's request: {.build} has already demoted a
      # non-first-party plugin's `true` to `false` and recorded a warning, so nothing downstream has to
      # re-ask who may discharge.
      Row = Data.define(:key, :labels, :narrow, :discharge, :within, :taint, :plugin_id) do
        def discharge? = discharge
      end

      # One compiled framework-edge strategy: the base class a plugin pointed the engine at, and which
      # plugin pointed.
      Edge = Data.define(:target, :receiver, :selector, :plugin_id)

      def self.empty
        @empty ||= new(contributions: [], superclasses: NO_ROWS)
      end

      # @param plugin_registry [Rigor::Plugin::Registry, nil]
      # @param superclasses [Hash{String=>String,Array<String>}] the project's as-written superclass table
      #   (`Scope::DiscoveryIndex#discovered_superclasses`). Empty is legal and simply means no row matches
      #   through inheritance.
      def self.build(plugin_registry, superclasses: NO_ROWS)
        contributions = plugin_registry&.effect_contributions || []
        return empty if contributions.empty?

        new(contributions: contributions, superclasses: superclasses)
      rescue StandardError
        empty
      end

      # Human-readable notes about contributions that were accepted only in part — a third-party plugin's
      # `discharge: true` demoted, a label root refused. Surfaced by `rigor effects`; never a diagnostic,
      # because a plugin the user chose is not the project's mistake to be flagged for.
      attr_reader :warnings

      # `{owner => [labels]}` — what {#extend_registry} folds into the run's vocabulary.
      attr_reader :labels_by_owner

      # Every `effect_entry_points:` preset across the loaded set, in registration order.
      attr_reader :entry_points

      def initialize(contributions:, superclasses:)
        @warnings = []
        @class_rows = {}
        @path_rows = {}
        @self_rows = {}
        @result_rows = {}
        @edges = []
        @labels_by_owner = {}
        @entry_points = []
        contributions.each { |contribution| absorb(contribution) }
        @superclasses = superclasses || NO_ROWS
        @ancestry = {}
        @digest = compute_digest
        finalize
      end

      # A content digest of every compiled plugin fact — labels, attributions, edges and presets, each with
      # the plugin that contributed it. {Identity} folds it in, so upgrading a plugin whose rows moved
      # invalidates the effects slot exactly as a re-audited `data/effects/core.yml` row does. Deliberately
      # independent of the project's superclass table, which is a *project* input the diagnostics identity
      # already covers.
      attr_reader :digest

      def empty?
        !attributions? && @edges.empty? && @labels_by_owner.empty? && @entry_points.empty?
      end

      # Whether any attribution row exists at all — the scan's fast path, asked once per call site.
      def attributions?
        !@class_rows.empty? || !@path_rows.empty? || !@self_rows.empty? || !@result_rows.empty?
      end

      def edges?
        !@edges.empty?
      end

      # The row colouring `owner`'s `selector`, found on `owner` itself or on a project ancestor of it.
      #
      # @param owner [String, nil] the receiver's class name as the syntax or the typer named it
      # @param singleton [Boolean] whether the call is `Owner.selector`
      # @return [Row, nil]
      def class_row(owner, singleton, selector)
        return nil if owner.nil? || @class_rows.empty?

        bucket = @class_rows[singleton]
        return nil if bucket.nil?

        ancestry(owner).each do |candidate|
          row = bucket[candidate]&.[](selector)
          return row if row
        end
        nil
      end

      # The row colouring `path`'s `selector`, where `path` is a receiver expression (`"Rails.cache"`).
      # Exact — a receiver path names one object and has no ancestry to walk.
      def path_row(path, selector)
        return nil if path.nil? || @path_rows.empty?

        @path_rows[path]&.[](selector)
      end

      # The row colouring `path`'s `selector` for a receiver rooted at implicit self (`"self.flash.now"`),
      # inside a unit whose class is `owner_class`. Answers nil when the row's `within:` class is not on
      # `owner_class`'s project ancestry — a receiver-less `session` outside a controller is a different
      # `session`.
      def self_path_row(path, selector, owner_class)
        return nil if path.nil? || @self_rows.empty?

        row = @self_rows[path]&.[](selector)
        return nil if row.nil?
        return nil unless descends_from?(owner_class, row.within)

        row
      end

      # The row colouring `selector` on the RESULT of a call to `producer` (or to a project ancestor of it):
      # `UserMailer.welcome(u).deliver_now`, `WelcomeJob.set(wait: 1.hour).perform_later`. The lazy object
      # in between has no declared type; the class that made it is written in the source.
      def result_row(producer, selector)
        return nil if producer.nil? || @result_rows.empty?

        ancestry(producer).each do |candidate|
          row = @result_rows[candidate]&.[](selector)
          return row if row
        end
        nil
      end

      # The framework-edge strategies of one kind, e.g. every `:activerecord_callbacks` base class the
      # loaded plugins named.
      def edges_for(target)
        @edges.select { |edge| edge.target == target }
      end

      # Whether `class_name` is `ancestor`, or reaches it through the project's own `class … <` lines.
      def descends_from?(class_name, ancestor)
        return false if class_name.nil?

        ancestry(class_name).include?(ancestor)
      end

      # `registry` extended with every plugin's `effect_labels:`, each under its own owner so
      # {Registry#with} enforces root ownership per plugin rather than for the set as a whole. A refusal is
      # recorded as a warning and that plugin's labels are dropped; the rest of the run keeps its
      # vocabulary, because one plugin overreaching must not un-name another's labels.
      def extend_registry(registry)
        @labels_by_owner.each do |owner, labels|
          registry = registry.with(labels: labels, owner: owner)
        rescue Registry::Error => e
          @warnings << "effect labels from #{owner.inspect} were not registered: #{e.message}"
        end
        registry
      end

      private

      def absorb(contribution)
        note_root_demotion(contribution)
        (@labels_by_owner[contribution.owner] ||= []).concat(contribution.labels)
        contribution.attributions.each { |entry| absorb_attribution(contribution, entry) }
        contribution.edges.each do |entry|
          @edges << Edge.new(target: entry.target, receiver: entry.receiver, selector: entry.method,
                             plugin_id: contribution.id)
        end
        @entry_points.concat(contribution.entry_points)
      end

      # ADR-103 WD2 — a plugin that asked to own a framework root and is not one the engine bundles keeps
      # the root named after itself. Worth saying out loud: the labels still register, just under a
      # different root, and a silent rename would look to the author like the labels vanished.
      def note_root_demotion(contribution)
        return if contribution.requested_root.nil? || contribution.requested_root == contribution.owner

        @warnings << "plugin #{contribution.id.inspect} is not bundled with the engine and may not open " \
                     "the effect-label root #{contribution.requested_root.inspect}; its labels open " \
                     "#{contribution.owner.inspect} instead"
      end

      def absorb_attribution(contribution, entry)
        row = Row.new(key: entry.key, labels: LabelSet.new(entry.labels), narrow: entry.narrow,
                      discharge: discharge_granted?(contribution, entry), within: entry.within,
                      taint: entry.taint, plugin_id: contribution.id)
        (bucket_for(entry)[entry.receiver] ||= {})[entry.method.to_s] = row
      end

      # Which index a row lands in, from its receiver spelling.
      def bucket_for(entry)
        return @self_rows if entry.self_path?
        return @path_rows if entry.receiver_path?
        return @result_rows if entry.on_result

        @class_rows[entry.singleton] ||= {}
      end

      # ADR-103 WD6 — discharge is a grant, and the granting fact is "the engine bundles this plugin".
      def discharge_granted?(contribution, entry)
        return false unless entry.discharge
        return true if contribution.discharge_allowed

        @warnings << "plugin #{contribution.id.inspect} is not bundled with the engine; its " \
                     "#{entry.key} attribution does not discharge the call site's taint"
        false
      end

      # `[class_name, …ancestors]`, memoised per class. Cycle-guarded and capped: the table is *as written*,
      # so a project can spell one that loops.
      def ancestry(class_name)
        @ancestry[class_name] ||= begin
          chain = []
          seen = Set.new
          current = class_name
          while current && seen.add?(current) && chain.length < ANCESTRY_CAP
            chain << current
            current = Array(@superclasses[current]).first
          end
          chain.freeze
        end
      end

      def compute_digest
        payload = [
          @labels_by_owner.sort.map { |owner, labels| [owner, labels.sort] },
          @class_rows.keys.sort_by { |singleton| singleton ? 1 : 0 }
                          .map { |singleton| [singleton, sorted(@class_rows[singleton])] },
          sorted(@path_rows), sorted(@self_rows), sorted(@result_rows),
          @edges.map { |edge| [edge.target.to_s, edge.receiver, edge.selector.to_s, edge.plugin_id] }.sort,
          @entry_points.map(&:to_h).sort_by { |preset| preset["name"] }
        ]
        Digest::SHA256.hexdigest(payload.inspect)
      end

      # ADR-103 WD14 — `effects.snapshot.reach: [rails]` adopts a preset BY NAME, so the names have to be
      # registered somewhere between plugin load and snapshot build. Here is that somewhere: this object is
      # built once per process from the loaded plugin set, which is exactly the condition the registration
      # needs. {EntryPoints.register} is idempotent for an identical glob set, so a second run in one
      # process is a no-op; two plugins claiming one name with DIFFERENT globs is a genuine conflict and
      # becomes a warning rather than taking the run down over a `reach:` key nobody may have used.
      def register_entry_points
        return if @entry_points.empty?

        EntryPoints.register_all(@entry_points)
      rescue EntryPoints::Error => e
        @warnings << "entry-point preset not registered: #{e.message}"
      end

      def sorted(bucket)
        bucket.sort.map do |receiver, rows|
          [receiver,
           rows.sort.map do |selector, row|
             [selector, row.labels.to_a, row.narrow, row.discharge, row.within, row.taint]
           end]
        end
      end

      def finalize
        @class_rows.each_value { |bucket| bucket.each_value(&:freeze) }
        @class_rows.each_value(&:freeze)
        @class_rows.freeze
        @path_rows.each_value(&:freeze)
        @path_rows.freeze
        @self_rows.each_value(&:freeze)
        @self_rows.freeze
        @result_rows.each_value(&:freeze)
        @result_rows.freeze
        @edges.freeze
        @labels_by_owner.each_value(&:uniq!)
        @labels_by_owner.reject! { |_, labels| labels.empty? }
        @labels_by_owner.freeze
        @entry_points.freeze
        register_entry_points
        # `@warnings` and `@ancestry` stay mutable: the first collects the registry-extension refusals that
        # can only be known when a vocabulary is folded, and the second is a per-process memo. The object is
        # therefore not frozen — it is process-local by construction (each fork-pool worker builds its own),
        # and nothing marshals it.
      end
    end
  end
end
