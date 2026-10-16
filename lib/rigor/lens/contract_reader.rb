# frozen_string_literal: true

require_relative "slot"
require_relative "../reflection"

module Rigor
  module Lens
    # Reads a member's own RBS declaration into overloads with per-slot provenance (docs/internal-spec/lens.md
    # § Members). A declaration the member inherits is not its contract; one written for its own class is, whether
    # it comes from `sig/`, an inline comment, a plugin or a library.
    class ContractReader
      INFERRED_RETURN = "rigor:v1:inferred-return"
      INFERRED_SIGNATURE = "rigor:v1:inferred-signature"

      # `overloads` hold `{rbs, params, block, return}`; a return the contract leaves to inference is nil there,
      # with `return_inferred` set. `buffers` are the declaring buffer names.
      Contract = Data.define(:overloads, :provenance, :path, :return_inferred, :buffers)

      def initialize(provenance)
        @provenance = provenance
      end

      # The member's contract, or nil when it has none of its own. `name` is the Ruby method name.
      def read(owner, scope, name, lookup_scope)
        method = lookup(owner, scope, name, lookup_scope)
        defs = method ? method.defs.select { |definition| definition.defined_in.to_s.delete_prefix("::") == owner } : []
        return nil if defs.empty?

        annotations = annotations_of(method, defs)
        return nil if annotations.include?(INFERRED_SIGNATURE)

        contract(defs, annotations)
      rescue StandardError
        unreadable("definition_build_failed", [])
      end

      # The declared type of the constant `name` (qualified), as a slot with its declaration's provenance, or nil
      # when no RBS or inline declaration names it.
      def read_constant(name, environment)
        declaration = environment&.rbs_loader&.constant_declaration(name)
        return nil if declaration.nil?

        type, buffer = declaration
        provenance, path = @provenance.classify(buffer)
        return Slot.unavailable("not_computed") if provenance.nil?

        Slot.from_rbs(type, provenance, path)
      rescue StandardError
        Slot.unavailable("not_computed")
      end

      private

      def contract(defs, annotations)
        buffers = defs.map { |definition| buffer_name(definition) }
        classified = buffers.map { |buffer| @provenance.classify(buffer) }
        return unreadable("not_computed", buffers) if classified.include?(nil)

        return_inferred = annotations.include?(INFERRED_RETURN)
        authored = annotations.select do |string|
          string.start_with?("rigor:v1:") && !string.start_with?(INFERRED_RETURN)
        end
        # Each overload carries the provenance of the declaration it came from: a `sig/` overload extending a
        # library declaration reads `sig`, the library one `library`.
        overloads = defs.zip(classified).map do |definition, (provenance, path)|
          overload(definition.type, provenance, path, return_inferred, authored)
        end
        provenance, path = classified.first
        Contract.new(overloads: overloads, provenance: provenance, path: path,
                     return_inferred: return_inferred, buffers: buffers)
      end

      # The method's and its own declarations' annotation strings: the plugin's defaulted-slot marks and authored
      # `%a{…}`.
      def annotations_of(method, defs)
        strings = method.annotations.map(&:string) + defs.flat_map { |definition| definition.annotations.map(&:string) }
        strings.map(&:strip).uniq
      end

      def buffer_name(definition)
        location = definition.member&.location
        location ? location.buffer&.name.to_s : ""
      end

      def lookup(owner, scope, name, lookup_scope)
        if scope == :singleton
          Reflection.singleton_method_definition(owner, name.to_sym, scope: lookup_scope)
        else
          Reflection.instance_method_definition(owner, name.to_sym, scope: lookup_scope)
        end
      end

      # A declaration Rigor cannot read: its buffer name did not survive the environment cache
      # (`not_computed`), or building the member's definition failed (`definition_build_failed`). The member has a
      # contract, so it is not inferred; every slot is unavailable, and so are its parameters (`params: null`).
      def unreadable(reason, buffers)
        Contract.new(overloads: [{ "rbs" => nil, "params" => nil, "block" => nil,
                                   "return" => Slot.unavailable(reason) }],
                     provenance: nil, path: nil, return_inferred: false, buffers: buffers)
      end

      def overload(method_type, provenance, path, return_inferred, annotations)
        function = method_type.type
        params = function.respond_to?(:required_positionals) ? params_of(function, provenance, path) : nil
        block = method_type.block && { "required" => method_type.block.required,
                                       "type" => Slot.from_rbs(block_type(method_type.block), provenance, path) }
        prefix = annotations.map { |string| "%a{#{string}} " }.join
        return_slot = return_inferred ? nil : Slot.from_rbs(function.return_type.to_s, provenance, path)
        { "rbs" => "#{prefix}#{method_type}", "params" => params, "block" => block, "return" => return_slot,
          "return_rbs" => function.return_type.to_s }
      end

      # A block's function type as `RBS::MethodType#to_s` spells it inside the braces (`(Integer) -> void`, with a
      # `[self: T]` binding when declared). `RBS::Types::Function` has no `to_s` of its own.
      def block_type(block)
        self_binding = ::RBS::Types::SelfTypeBindingHelper.self_type_binding_to_s(block.self_type)
        "(#{block.type.param_to_s}) #{self_binding}-> #{block.type.return_to_s}"
      end

      def params_of(function, provenance, path)
        (positional_params(function) + keyword_params(function)).map do |kind, name, param|
          { "name" => name&.to_s, "kind" => kind, "type" => Slot.from_rbs(param.type.to_s, provenance, path) }
        end
      end

      def positional_params(function)
        function.required_positionals.map { |param| ["required", param.name, param] } +
          function.optional_positionals.map { |param| ["optional", param.name, param] } +
          [function.rest_positionals].compact.map { |param| ["rest", param.name, param] } +
          function.trailing_positionals.map { |param| ["post", param.name, param] }
      end

      def keyword_params(function)
        function.required_keywords.map { |name, param| ["keyreq", name, param] } +
          function.optional_keywords.map { |name, param| ["key", name, param] } +
          [function.rest_keywords].compact.map { |param| ["keyrest", param.name, param] }
      end
    end
  end
end
