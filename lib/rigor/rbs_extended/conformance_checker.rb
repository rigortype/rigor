# frozen_string_literal: true

require_relative "../rbs_extended"

module Rigor
  module RbsExtended
    # Verifies every `rigor:v1:conforms-to <Interface>` class- /
    # module-level directive in the loaded RBS environment (spec:
    # `docs/type-specification/rbs-extended.md` § "Explicit
    # conformance directive"). For each annotated class, the
    # directive asserts the class satisfies the named structural
    # interface as a *checked design assertion* — independent of
    # whether any current call site exercises that requirement.
    # Multiple directives on one class combine as an intersection:
    # each interface is checked independently.
    #
    # ## Conservative, presence-based first cut
    #
    # The check reports only the interface methods the class
    # provably does NOT provide anywhere in its RBS-resolved method
    # set (own, inherited, included). A missing required method is a
    # *definitive* non-conformance — there is no false positive in
    # flagging it. Signature compatibility (parameter contravariance
    # / return covariance) is deliberately deferred to a follow-up
    # slice: comparing signatures has a known false-positive surface
    # on imprecise inferred signatures, and the
    # never-frighten-working-code discipline outranks catching the
    # rarer signature-skew case in v1. A class that provides every
    # required name therefore type-checks clean.
    #
    # ## Output records (both drained by {Rigor::Analysis::Runner})
    #
    # - `Unsatisfied` — the class is missing one or more required
    #   interface methods. Surfaces as
    #   `rbs_extended.unsatisfied-conformance`.
    # - `UnresolvedInterface` — the named interface is not loaded
    #   (a typo, or the defining library / `sig` set is not on the
    #   RBS load path). Surfaces as `dynamic.rbs-extended.unresolved`
    #   `:info`, the same fail-soft channel the other directive
    #   parsers use, so a bad name never silently disables the
    #   author's assertion.
    #
    # Fail-soft throughout: a class whose own definition cannot be
    # built (RBS error) is skipped rather than reported, matching
    # the rest of the RBS::Extended surface.
    module ConformanceChecker
      Unsatisfied = Data.define(:class_name, :interface_name, :missing_methods, :location)
      UnresolvedInterface = Data.define(:class_name, :interface_name, :location)

      module_function

      # Scans `rbs_loader` for `conforms-to` directives and returns
      # the failure / unresolved records in source order. Returns an
      # empty array when no directive is present, the loader is nil,
      # or the env failed to build (the loader's iterators are
      # themselves fail-soft).
      def scan(rbs_loader)
        return [] if rbs_loader.nil?

        results = []
        rbs_loader.each_class_decl_annotation_with_name do |class_name, string, location|
          interface_name = RbsExtended.parse_conforms_to_annotation(string)
          next if interface_name.nil?

          record = check_one(rbs_loader, class_name, interface_name, location)
          results << record if record
        end
        results
      end

      def check_one(rbs_loader, class_name, interface_name, location)
        required = rbs_loader.interface_method_names(interface_name)
        if required.nil?
          return UnresolvedInterface.new(
            class_name: normalize(class_name),
            interface_name: interface_name,
            location: location
          )
        end

        provided = rbs_loader.instance_method_names(class_name)
        # The class's own definition failed to build — fail-soft, no
        # diagnostic (we can't prove non-conformance).
        return nil if provided.nil?

        missing = required - provided
        return nil if missing.empty?

        Unsatisfied.new(
          class_name: normalize(class_name),
          interface_name: interface_name,
          missing_methods: missing,
          location: location
        )
      end

      def normalize(class_name)
        class_name.to_s.sub(/\A::/, "")
      end
    end
  end
end
