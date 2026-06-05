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
        interface_def = resolve_interface(rbs_loader, class_name, interface_name)
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
      # Also checks arity divergence and keyword-requiredness divergence
      # (positional-type comparison only was the initial scope; these
      # extend it to the cases that cause runtime ArgumentError).
      def signature_mismatch(required_method, provided_method)
        return nil unless required_method.method_types.size == 1
        return nil unless provided_method.method_types.size == 1

        return_detail(required_method, provided_method) ||
          param_detail(required_method, provided_method) ||
          arity_detail(required_method, provided_method) ||
          keyword_detail(required_method, provided_method)
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

      # Checks positional-count divergence — cases that would cause a
      # runtime `ArgumentError` even when every declared type matches.
      # Skipped when either side has a rest parameter (`*args`) since
      # that makes the arity range unbounded. Two violation shapes:
      # (a) provided requires MORE positionals than the interface allows
      #     (caller passes ≤ interface total → provided raises);
      # (b) provided accepts FEWER positionals than the interface requires
      #     (caller passes ≥ interface required → provided raises).
      def arity_detail(required_method, provided_method)
        req_func = required_method.method_types.first.type
        prov_func = provided_method.method_types.first.type
        return nil unless req_func.respond_to?(:required_positionals)
        return nil unless prov_func.respond_to?(:required_positionals)

        req_req  = req_func.required_positionals.size
        req_opt  = req_func.optional_positionals.size
        prov_req = prov_func.required_positionals.size
        prov_opt = prov_func.required_positionals.size + prov_func.optional_positionals.size

        # (a) provided requires too many — callers may not pass enough
        if req_func.rest_positionals.nil? && prov_req > req_req + req_opt
          return "requires #{prov_req} positional argument#{'s' if prov_req != 1} " \
                 "but the interface allows at most #{req_req + req_opt}"
        end

        # (b) provided accepts too few — callers will pass more than provided can handle
        if prov_func.rest_positionals.nil? && req_req > prov_opt
          return "accepts at most #{prov_opt} positional argument#{'s' if prov_opt != 1} " \
                 "but the interface requires at least #{req_req}"
        end

        nil
      end

      # Checks keyword-requiredness divergence.
      # (a) A keyword the interface requires that the provided method does
      #     not accept at all → callers will pass it, provided will raise.
      # (b) A keyword the provided method requires that the interface does
      #     not mention → callers following the interface won't pass it,
      #     provided will raise.
      # Skipped when either side has a keyword rest (`**kwargs`).
      def keyword_detail(required_method, provided_method)
        req_func  = required_method.method_types.first.type
        prov_func = provided_method.method_types.first.type
        return nil unless req_func.respond_to?(:required_keywords)
        return nil unless prov_func.respond_to?(:required_keywords)
        return nil unless req_func.rest_keywords.nil? && prov_func.rest_keywords.nil?

        prov_accepted = prov_func.required_keywords.keys + prov_func.optional_keywords.keys
        req_accepted  = req_func.required_keywords.keys  + req_func.optional_keywords.keys

        # (a) interface-required keyword not accepted by provided
        not_accepted = req_func.required_keywords.keys - prov_accepted
        if not_accepted.any?
          listed = not_accepted.sort.map { |k| "`#{k}:`" }.join(", ")
          noun = not_accepted.size == 1 ? "keyword" : "keywords"
          return "does not accept required #{noun} #{listed}"
        end

        # (b) provided requires keyword not in interface contract
        extra_required = prov_func.required_keywords.keys - req_accepted
        if extra_required.any?
          listed = extra_required.sort.map { |k| "`#{k}:`" }.join(", ")
          noun = extra_required.size == 1 ? "keyword" : "keywords"
          return "requires #{noun} #{listed} not declared by the interface"
        end

        nil
      end

      def positional_param_types(method_def)
        func = method_def.method_types.first.type
        return nil unless func.respond_to?(:required_positionals)

        (func.required_positionals + func.optional_positionals).map { |param| translate(param.type) }
      end

      # Resolves the (possibly namespace-relative) `interface_name` against
      # the declaring class's namespace chain, mirroring Ruby constant
      # lookup: `conforms-to _Foo` inside `Bar::Baz` tries `Bar::Baz::_Foo`,
      # `Bar::_Foo`, then top-level `_Foo` (longest prefix first). Returns
      # the first interface definition that resolves, or nil. (A leading
      # `::` is already stripped by the parser, so an intended-absolute name
      # still resolves via the trailing top-level candidate.)
      def resolve_interface(rbs_loader, class_name, interface_name)
        candidate_interface_names(class_name, interface_name).each do |candidate|
          defn = rbs_loader.interface_definition(candidate)
          return defn if defn
        end
        nil
      end

      def candidate_interface_names(class_name, interface_name)
        prefixes = namespace_prefixes(class_name)
        prefixes.map { |prefix| "#{prefix}::#{interface_name}" } + [interface_name]
      end

      # Namespace prefixes of a qualified name, longest first:
      # `"Bar::Baz"` → `["Bar::Baz", "Bar"]`. Covers both the
      # `class Bar::Baz` and the `module Bar; class Baz` nesting shapes
      # (a superset of `Module.nesting`, which the directive's resolved
      # class name does not record).
      def namespace_prefixes(class_name)
        parts = normalize(class_name).split("::")
        (1..parts.size).to_a.reverse.map { |count| parts.first(count).join("::") }
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
