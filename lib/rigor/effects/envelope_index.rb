# frozen_string_literal: true

require_relative "config_envelopes"
require_relative "envelope"
require_relative "method_key"
require_relative "registry"
require_relative "signature_sources"

module Rigor
  module Effects
    # The envelopes a **call site** may import as a `≤` bound, looked up by the callee the typer named
    # (ADR-103 WD6; #386; normative in `docs/type-specification/effect-labels.md` § The declared lane at
    # call sites).
    #
    # {EnvelopeCheck} asks "what bounds THIS method's body?" and answers it from the project's own
    # declarations alone, because that is the stratum a contract can be checked against. This index asks
    # the other question — "what does the thing I am calling promise?" — and so reads one stratum more:
    # an **accepted signature**'s annotation, from the built RBS environment. WD6's trust ladder puts
    # both on the discharging side, and the two questions are kept in two objects because only the first
    # one may ever produce a finding.
    #
    # Four sources, nearest-first, exactly the check's precedence with the accepted stratum appended:
    #
    #     per-method annotation  >  class-level annotation  >  `effects.envelopes:`  >  accepted signature
    #
    # The carrier is **nominal**: the lookup is by the receiver's *static* class name as the typer
    # projected it (or, for an implicit-self call, by the unit's own class), never by walking ancestors.
    # A structural interface erases to `Dynamic[top]` today and has nothing to attach a bound to
    # ([ADR-103](../../../docs/adr/103-effect-labels.md) WD6); an inherited envelope reaches an override
    # through `effect.liskov-widened` instead, which is a judgment rather than an import.
    #
    # Two bounds of the slice, both deliberate:
    #
    # - An `effects.envelopes:` entry selected by **`match:`** does not participate here. A path glob is
    #   a fact about where a class is *defined*, which a per-file collection window cannot see without
    #   the whole-project class-source table; `namespace:` needs only the name and does participate. The
    #   entry still bounds its own classes' methods for {EnvelopeCheck} and the Liskov check.
    # - Lookup is by the *exact* owner. `repo.find` on a receiver typed `PgRepo` does not import
    #   `Repo#find`'s bound.
    #
    # Values are Marshal-clean ({Envelope} over frozen Strings and {LabelSet}s), because the index is
    # built per process — the parent and each fork-pool worker build their own from the same
    # configuration and the same signature content, so the two agree without a channel to keep in sync.
    class EnvelopeIndex
      NO_ENVELOPES = {}.freeze
      private_constant :NO_ENVELOPES

      NO_ENTRIES = [].freeze
      private_constant :NO_ENTRIES

      # The index a run with no declaration of any kind uses — and the fail-soft answer for a build that
      # raised. Every lookup on it is one `empty?` read.
      def self.empty
        @empty ||= new
      end

      # Reads every stratum this index serves, once per process.
      #
      # @param configuration [Rigor::Configuration]
      # @param plugin_facts [Rigor::Effects::PluginFacts, nil] the loaded plugins' effect contributions
      #   (#387); their `effect_labels:` join the vocabulary an annotation is read against, so a gem's
      #   `%a{rigor:v1:effect rails.activejob.enqueue}` resolves rather than reading as unknown.
      # @param environment [Rigor::Environment, nil] the run's environment. Its loader supplies the
      #   rbs-inline / plugin `virtual_rbs` buffers and the built RBS environment the accepted stratum is
      #   read from; without one, both are simply absent (the fail-quiet direction — a missing `≤` bound
      #   costs precision, never a finding).
      # @return [EnvelopeIndex]
      def self.build(configuration:, environment: nil, plugin_facts: nil)
        # Required here rather than at the top of the file: the reader pulls in the whole
        # `RbsExtended` surface, and this build runs only under an `effects:` block.
        require_relative "../rbs_extended/envelope_scanner"

        registry = Registry.for_configuration(configuration, plugin_facts: plugin_facts)
        loader = environment&.rbs_loader
        scan = RbsExtended::EnvelopeScanner.scan(
          sources: SignatureSources.collect(
            signature_paths: configuration.signature_paths, virtual_rbs: loader&.virtual_rbs
          ),
          registry: registry
        )
        new(
          method_envelopes: scan.method_envelopes, class_envelopes: scan.class_envelopes,
          config_entries: ConfigEnvelopes.build(entries: configuration.effects_envelopes, registry: registry),
          accepted: accepted_for(loader, registry)
        )
      rescue StandardError
        empty
      end

      # The accepted stratum — every `%a{pure}` / `%a{rigor:v1:effect …}` on a method definition in the
      # **built** RBS environment: a gem's shipped signatures, Rigor's bundled overlays, core RBS.
      #
      # It is read-only by construction. Nothing here can bound a project method's body, because the
      # contract check ({EnvelopeCheck}) reads {RbsExtended::EnvelopeScanner}'s project-source tables and
      # never this one; what an accepted signature can do is state what a call into it promises. The
      # project's own signatures are in the built environment too and therefore appear here as well —
      # harmlessly, since the project strata are consulted first and both discharge.
      def self.accepted_for(loader, registry)
        return NO_ENVELOPES if loader.nil?

        RbsExtended::EnvelopeScanner.from_loader(loader: loader, registry: registry)
      rescue StandardError
        NO_ENVELOPES
      end
      private_class_method :accepted_for

      def initialize(method_envelopes: NO_ENVELOPES, class_envelopes: NO_ENVELOPES,
                     config_entries: NO_ENTRIES, accepted: NO_ENVELOPES)
        @method_envelopes = method_envelopes.freeze
        @class_envelopes = class_envelopes.freeze
        @config_entries = config_entries.reject { |entry| entry.namespace.nil? }.freeze
        @accepted = accepted.freeze
        @config_cache = {}
        freeze
      end

      # Whether no stratum has anything to say. The scan's fast path: a project with no envelope of any
      # kind pays one predicate per call site and nothing else.
      def empty?
        @method_envelopes.empty? && @class_envelopes.empty? && @config_entries.empty? && @accepted.empty?
      end

      # The envelope bounding `owner`'s `selector`, or nil.
      #
      # @param owner [String] the receiver's static class name, as the typer projected it
      # @param singleton [Boolean] whether the call is `Owner.selector` rather than `Owner#selector`
      # @param selector [String]
      # @return [Envelope, nil] never a ⊤ envelope: a bound that bounds nothing is not a bound, and
      #   importing it would both add nothing and discharge a taint on the strength of a typo.
      def [](owner, singleton, selector)
        return nil if owner.nil? || empty?

        key = "#{owner}#{singleton ? '.' : '#'}#{selector}"
        envelope = @method_envelopes[key] || @class_envelopes[owner] || config_envelope(owner) ||
                   @accepted[key]
        return nil if envelope.nil? || envelope.top?

        envelope
      end

      private

      # The first `namespace:` entry selecting `owner`, memoised per class name — one call site's owner
      # is asked for once per site and a project has a handful of entries.
      def config_envelope(owner)
        return nil if @config_entries.empty?

        if @config_cache.key?(owner)
          @config_cache[owner]
        else
          entry = @config_entries.find { |candidate| ConfigEnvelopes.namespace_match?(candidate.namespace, owner) }
          @config_cache[owner] = entry && ConfigEnvelopes.envelope_for(entry, owner)
        end
      end
    end
  end
end
