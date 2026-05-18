# frozen_string_literal: true

require "json"
require_relative "../inference/hkt_registry"
require_relative "../inference/hkt_body_parser"

module Rigor
  module RbsExtended
    # ADR-20 § "Decision D6" parser for the two new HKT
    # directives that live in `.rbs` files at module / class
    # scope:
    #
    # - `%a{rigor:v1:hkt_register: <JSON-flow payload>}` —
    #   registers a defunctionalised type-constructor URI
    #   together with its arity, per-position variance, and
    #   erasure bound.
    # - `%a{rigor:v1:hkt_define: <JSON-flow payload>}` —
    #   binds the URI to a type-function body the Slice 2
    #   evaluator will reduce against.
    #
    # Slice 1 ships pure parser functions that take the
    # directive payload text and produce
    # `Rigor::Inference::HktRegistry::Registration` /
    # `Rigor::Inference::HktRegistry::Definition` value
    # objects. The integration that *walks* RBS annotations off
    # a loaded environment and populates an `HktRegistry`
    # instance is deferred to a follow-up slice — the parsers
    # here are deliberately decoupled from RBS loading so
    # downstream slices and tests can drive them directly.
    #
    # Payload format is **JSON flow** (a strict subset of YAML
    # flow). The deliberate choice avoids YAML's aliasing /
    # tag-resolution surprises while keeping the single-line
    # discipline RBS annotations work best with. Multi-line
    # bodies inside `hkt_define` MUST be encoded as a single
    # JSON string with escaped newlines for Slice 1; Slice 2
    # may introduce a heredoc-style continuation marker if
    # demand surfaces.
    #
    # Bound vocabulary in Slice 1 is intentionally narrow:
    # - `"untyped"` resolves to `Rigor::Type::Combinator.untyped`
    #   (i.e. `Dynamic[Top]`, the ADR-20 WD2 default).
    # - A bare class name (`"String"`, `"Integer"`, …) resolves
    #   through `name_scope.resolve(...)` when supplied, falling
    #   back to a raw `Rigor::Type::Nominal` otherwise.
    # - Anything else falls back to `untyped` and emits an
    #   `:info` diagnostic via the supplied reporter (fail-soft
    #   so an unrecognised bound never crashes the loader).
    # Richer bound forms (parameterised generics, unions,
    # refinements) wait for Slice 2's expression parser.
    module HktDirectives
      module_function

      REGISTER_DIRECTIVE = "rigor:v1:hkt_register:"
      DEFINE_DIRECTIVE   = "rigor:v1:hkt_define:"

      DEFAULT_VARIANCE = :inv
      DEFAULT_BOUND_LITERAL = "untyped"

      # Parses one `%a{rigor:v1:hkt_register: ...}` payload
      # string and returns a `Registration`, or `nil` when the
      # string is not an hkt_register directive (so callers can
      # walk a list of annotations without each having to
      # pre-filter).
      def parse_register(string, name_scope: nil, reporter: nil, source_location: nil)
        payload = extract_payload(string, REGISTER_DIRECTIVE)
        return nil if payload.nil?

        data = parse_json_payload(payload, reporter: reporter, source_location: source_location)
        return nil if data.nil?

        uri = symbolize_uri(data["uri"], reporter: reporter, source_location: source_location)
        return nil if uri.nil?

        arity = coerce_arity(data["arity"], reporter: reporter, source_location: source_location)
        return nil if arity.nil?

        variance = coerce_variance(data["variance"], arity, reporter: reporter, source_location: source_location)
        return nil if variance.nil?

        bound = resolve_bound(
          data["bound"] || DEFAULT_BOUND_LITERAL,
          name_scope: name_scope,
          reporter: reporter,
          source_location: source_location
        )

        Inference::HktRegistry::Registration.new(
          uri: uri,
          arity: arity,
          variance: variance,
          bound: bound
        )
      rescue ArgumentError => e
        record_hkt_error(reporter, "hkt_register: #{e.message}", source_location)
        nil
      end

      # Parses one `%a{rigor:v1:hkt_define: ...}` payload
      # string and returns a `Definition`, or `nil` when the
      # string is not an hkt_define directive.
      def parse_define(string, reporter: nil, source_location: nil)
        payload = extract_payload(string, DEFINE_DIRECTIVE)
        return nil if payload.nil?

        data = parse_json_payload(payload, reporter: reporter, source_location: source_location)
        return nil if data.nil?

        uri = symbolize_uri(data["uri"], reporter: reporter, source_location: source_location)
        return nil if uri.nil?

        params_raw = data["params"]
        unless params_raw.is_a?(Array)
          record_hkt_error(reporter, "hkt_define: params must be an Array, got #{params_raw.class}", source_location)
          return nil
        end

        params = params_raw.map(&:to_sym)

        body = data["body"]
        unless body.is_a?(String)
          record_hkt_error(reporter, "hkt_define: body must be a String, got #{body.class}", source_location)
          return nil
        end

        body_tree = parse_body_tree(body, params, reporter: reporter, source_location: source_location)

        Inference::HktRegistry::Definition.new(
          uri: uri,
          params: params,
          body: body,
          body_tree: body_tree,
          source_path: source_path_of(source_location),
          source_line: source_line_of(source_location)
        )
      rescue ArgumentError => e
        record_hkt_error(reporter, "hkt_define: #{e.message}", source_location)
        nil
      end

      def extract_payload(string, directive)
        return nil if string.nil?

        idx = string.index(directive)
        return nil if idx.nil?

        payload = string[(idx + directive.size)..].to_s.strip
        # Strip trailing `}` of the wrapping `%a{...}` form if
        # the caller passed the raw annotation string. The
        # parser also accepts a pre-extracted payload.
        payload = payload.sub(/\}\z/, "") if payload.end_with?("}") && !balanced_braces?(payload)
        payload.empty? ? nil : payload
      end

      def balanced_braces?(string)
        depth = 0
        in_string = false
        escape = false
        string.each_char do |ch|
          if escape
            escape = false
            next
          end
          case ch
          when "\\"
            escape = true if in_string
          when "\""
            in_string = !in_string
          when "{"
            depth += 1 unless in_string
          when "}"
            depth -= 1 unless in_string
            return false if depth.negative?
          end
        end
        depth.zero?
      end

      def parse_json_payload(payload, reporter:, source_location:)
        JSON.parse(payload)
      rescue JSON::ParserError => e
        record_hkt_error(reporter, "JSON payload parse error: #{e.message}", source_location)
        nil
      end

      def symbolize_uri(raw, reporter:, source_location:)
        unless raw.is_a?(String)
          record_hkt_error(reporter, "uri must be a String, got #{raw.class}", source_location)
          return nil
        end
        unless raw.include?(Type::App::URI_SEPARATOR)
          record_hkt_error(reporter, "uri must be namespaced as `a::b` per ADR-20 WD1, got #{raw.inspect}",
                           source_location)
          return nil
        end

        raw.to_sym
      end

      def coerce_arity(raw, reporter:, source_location:)
        if raw.is_a?(Integer) && raw.positive?
          raw
        else
          record_hkt_error(reporter, "arity must be a positive Integer, got #{raw.inspect}", source_location)
          nil
        end
      end

      def coerce_variance(raw, arity, reporter:, source_location:)
        # Omitted variance defaults to `[:inv] * arity` per ADR-20 WD4.
        variance =
          if raw.nil?
            Array.new(arity, DEFAULT_VARIANCE)
          elsif raw.is_a?(Array)
            raw.map(&:to_sym)
          else
            record_hkt_error(reporter, "variance must be an Array, got #{raw.class}", source_location)
            return nil
          end

        unless variance.size == arity
          record_hkt_error(reporter, "variance length #{variance.size} does not match arity #{arity}", source_location)
          return nil
        end

        unless variance.all? { |v| %i[out in inv].include?(v) }
          record_hkt_error(reporter, "variance entries must be `out` / `in` / `inv`, got #{variance.inspect}",
                           source_location)
          return nil
        end

        variance
      end

      def resolve_bound(raw, name_scope:, reporter:, source_location:)
        return Type::Combinator.untyped unless raw.is_a?(String)
        return Type::Combinator.untyped if raw.strip == DEFAULT_BOUND_LITERAL

        # Bare class name resolution. Slice 1 keeps this narrow:
        # symbol-shaped tokens are tried as nominal class names
        # via name_scope; everything else falls back to `untyped`.
        class_name = raw.strip
        if /\A(?:::)?(?:[A-Z]\w*)(?:::[A-Z]\w*)*\z/.match?(class_name)
          normalized = class_name.sub(/\A::/, "")
          return Type::Nominal.new(normalized) if name_scope.nil?

          resolved =
            if name_scope.respond_to?(:nominal_for_name)
              name_scope.nominal_for_name(normalized)
            elsif name_scope.respond_to?(:resolve)
              name_scope.resolve(normalized)
            end
          return resolved if resolved

          return Type::Nominal.new(normalized)
        end

        record_hkt_error(
          reporter,
          "bound `#{raw}` not recognised (Slice 1 accepts `untyped` or a bare class name); " \
          "falling back to `untyped`",
          source_location
        )
        Type::Combinator.untyped
      end

      # ADR-20 slice 2b — parse the body String into an
      # `HktBody::*` tree via {Inference::HktBodyParser.parse}.
      # On parse failure: emit a fail-soft `:info` reporter
      # entry and return `nil` so the resulting Definition
      # keeps its `body` String slot but `body_tree` stays
      # absent (the reducer falls back to `app.bound` at call
      # time per ADR-20 D5). The body String can still be
      # consumed by future slices' richer grammars without
      # the registration being lost.
      def parse_body_tree(body, params, reporter:, source_location:)
        return nil if body.nil? || body.empty?

        Inference::HktBodyParser.parse(body, params: params)
      rescue Inference::HktBodyParser::ParseError => e
        record_hkt_error(reporter, "hkt_define body parse error: #{e.message}", source_location)
        nil
      rescue ArgumentError => e
        record_hkt_error(reporter, "hkt_define body construction error: #{e.message}", source_location)
        nil
      end

      def source_path_of(source_location)
        return nil if source_location.nil?

        source_location.respond_to?(:name) ? source_location.name : nil
      end

      def source_line_of(source_location)
        return nil if source_location.nil?

        source_location.respond_to?(:start_line) ? source_location.start_line : nil
      end

      def record_hkt_error(reporter, message, source_location)
        return if reporter.nil?

        if reporter.respond_to?(:record)
          reporter.record(directive: "hkt", message: message, source_location: source_location)
        elsif reporter.respond_to?(:<<)
          reporter << { directive: "hkt", message: message, source_location: source_location }
        end
      end
    end
  end
end
