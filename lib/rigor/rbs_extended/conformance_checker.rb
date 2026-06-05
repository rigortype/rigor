# frozen_string_literal: true

require_relative "../rbs_extended"
require_relative "../inference/rbs_type_translator"

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
    # ## Two checked tiers
    #
    # 1. **Presence** (FP-free): an interface method the class provably does
    #    NOT provide anywhere in its RBS-resolved method set (own, inherited,
    #    included) is a definitive non-conformance.
    # 2. **Signature compatibility** (covariant return / contravariant
    #    params): for a method the class DOES provide, the provided RBS
    #    signature must be a behavioural subtype of the interface's required
    #    one. Both sides are *authored* RBS (the class in `signature_paths:`
    #    RBS, the interface in a loaded `sig`/library), so this is the same
    #    FP-safe both-sides-authored construction as the
    #    [ADR-35](../../../docs/adr/35-override-signature-compatibility.md)
    #    `def.override-*` rules — not the inferred-signature comparison whose
    #    FP risk justified deferring it. Conservative: single-method-type
    #    (non-overloaded) signatures only, `Dynamic[Top]` positions skipped,
    #    fires only on a proven `accepts(...).no?` violation.
    #
    # ## Output records (all drained by {Rigor::Analysis::Runner})
    #
    # - `Unsatisfied` — the class is missing one or more required interface
    #   methods. Surfaces as `rbs_extended.unsatisfied-conformance`.
    # - `IncompatibleSignature` — a provided method's signature violates the
    #   interface contract (return widened, or a parameter narrowed). Same
    #   rule, signature-specific message.
    # - `UnresolvedInterface` — the named interface is not loaded (a typo, or
    #   the defining library / `sig` set is not on the RBS load path).
    #   Surfaces as `dynamic.rbs-extended.unresolved` `:info`, the fail-soft
    #   channel the other directive parsers use, so a bad name never silently
    #   disables the author's assertion.
    #
    # Fail-soft throughout: a class whose own definition cannot be built (RBS
    # error) is skipped rather than reported.
    module ConformanceChecker
      Unsatisfied = Data.define(:class_name, :interface_name, :missing_methods, :location)
      IncompatibleSignature = Data.define(:class_name, :interface_name, :method_name, :detail, :location)
      UnresolvedInterface = Data.define(:class_name, :interface_name, :location)

      module_function

      # Scans `rbs_loader` for `conforms-to` directives and returns the
      # failure / unresolved records in source order. Returns an empty array
      # when no directive is present, the loader is nil, or the env failed to
      # build (the loader's iterators are themselves fail-soft).
      def scan(rbs_loader)
        return [] if rbs_loader.nil?

        results = []
        rbs_loader.each_class_decl_annotation_with_name do |class_name, string, location|
          interface_name = RbsExtended.parse_conforms_to_annotation(string)
          next if interface_name.nil?

          results.concat(check_one(rbs_loader, class_name, interface_name, location))
        end
        results
      end

      # @return [Array] zero or more records for one (class, interface) pair.
      def check_one(rbs_loader, class_name, interface_name, location)
        interface_def = rbs_loader.interface_definition(interface_name)
        if interface_def.nil?
          return [UnresolvedInterface.new(
            class_name: normalize(class_name), interface_name: interface_name, location: location
          )]
        end

        class_def = rbs_loader.instance_definition(class_name)
        return [] if class_def.nil? # fail-soft: cannot prove non-conformance

        required = interface_def.methods
        provided = class_def.methods
        records = []
        collect_missing(records, class_name, interface_name, required, provided, location)
        collect_incompatible(records, class_name, interface_name, required, provided, location)
        records
      end

      def collect_missing(records, class_name, interface_name, required, provided, location)
        missing = required.keys - provided.keys
        return if missing.empty?

        records << Unsatisfied.new(
          class_name: normalize(class_name), interface_name: interface_name,
          missing_methods: missing, location: location
        )
      end

      def collect_incompatible(records, class_name, interface_name, required, provided, location)
        (required.keys & provided.keys).each do |method_name|
          detail = signature_mismatch(required[method_name], provided[method_name])
          next if detail.nil?

          records << IncompatibleSignature.new(
            class_name: normalize(class_name), interface_name: interface_name,
            method_name: method_name, detail: detail, location: location
          )
        end
      end

      # Returns a human-readable mismatch detail when `provided` is NOT a
      # behavioural subtype of the `required` (interface) signature, else
      # nil. Mirrors the ADR-35 override checks: covariant return,
      # contravariant params, single method type only, `Dynamic[Top]`
      # positions skipped (fires only on a proven `accepts(...).no?`).
      def signature_mismatch(required_method, provided_method)
        return nil unless required_method.method_types.size == 1
        return nil unless provided_method.method_types.size == 1

        return_detail(required_method, provided_method) ||
          param_detail(required_method, provided_method)
      end

      def return_detail(required_method, provided_method)
        req = translate(required_method.method_types.first.type.return_type)
        prov = translate(provided_method.method_types.first.type.return_type)
        return nil if req.nil? || prov.nil?
        return nil if dynamic_top?(req) || dynamic_top?(prov)
        return nil unless req.accepts(prov).no?

        "return type #{prov.describe(:short)} is not a subtype of the required #{req.describe(:short)}"
      end

      def param_detail(required_method, provided_method)
        req = positional_param_types(required_method)
        prov = positional_param_types(provided_method)
        return nil if req.nil? || prov.nil?

        [req.size, prov.size].min.times do |i|
          rp = req[i]
          pp = prov[i]
          next if rp.nil? || pp.nil? || dynamic_top?(rp) || dynamic_top?(pp)
          next unless pp.accepts(rp).no?

          return "parameter #{i + 1} type #{pp.describe(:short)} does not accept the " \
                 "required #{rp.describe(:short)}"
        end
        nil
      end

      def positional_param_types(method_def)
        func = method_def.method_types.first.type
        return nil unless func.respond_to?(:required_positionals)

        (func.required_positionals + func.optional_positionals).map { |param| translate(param.type) }
      end

      def translate(rbs_type)
        Inference::RbsTypeTranslator.translate(rbs_type, self_type: nil, instance_type: nil, type_vars: {})
      rescue StandardError
        nil
      end

      def dynamic_top?(type)
        type.is_a?(Type::Dynamic) || (type.respond_to?(:top?) && type.top?.yes?)
      end

      def normalize(class_name)
        class_name.to_s.sub(/\A::/, "")
      end
    end
  end
end
