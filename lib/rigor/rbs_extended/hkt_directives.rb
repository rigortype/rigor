# frozen_string_literal: true

require_relative "../inference/hkt_registry"
require_relative "../inference/hkt_body_parser"

module Rigor
  module RbsExtended
    # ADR-20 § "Decision D6" parser for the two new HKT
    # directives that live in `.rbs` files at module / class
    # scope:
    #
    # - `%a{rigor:v1:hkt_register: uri=<uri> arity=<int>
    #   variance=<v1>,<v2>,... bound=<class_name_or_untyped>}` —
    #   registers a defunctionalised type-constructor URI
    #   together with its arity, per-position variance, and
    #   erasure bound.
    # - `%a{rigor:v1:hkt_define: uri=<uri> params=<P1>,<P2>,...
    #   body=<body_text>}` — binds the URI to a type-function
    #   body that {HktBodyParser} parses into an
    #   {HktBody::Union} tree.
    #
    # ## Payload format
    #
    # **Space-separated `key=value` pairs.** The format is
    # constrained by RBS's `%a{...}` annotation grammar, which
    # does NOT accept arbitrary nested punctuation (a JSON
    # payload with quotes / nested braces will fail RBS
    # parsing). Each value is a bare token: no quoting, no
    # escaping. Values that contain spaces or `=` signs MUST
    # be encoded via the `body=` key, which is special-cased
    # to gobble everything from `body=` to the end of the
    # payload — see `parse_define`.
    #
    # Example annotations (write inside a class / module
    # declaration so the annotation attaches to the decl
    # RBS parses):
    #
    #   %a{rigor:v1:hkt_register: uri=json::value arity=1
    #     variance=out bound=untyped}
    #   %a{rigor:v1:hkt_define: uri=json::value params=K
    #     body=nil | true | false | Integer | Float | String |
    #          Array[App[json::value, K]] |
    #          Hash[K, App[json::value, K]]}
    #   module JsonOverlay
    #   end
    #
    # ## Bound vocabulary
    #
    # - `untyped` resolves to `Rigor::Type::Combinator.untyped`
    #   (i.e. `Dynamic[Top]`, the ADR-20 WD2 default).
    # - A bare class name (`String`, `Integer`, …) resolves
    #   through `name_scope.nominal_for_name(...)` when
    #   supplied, falling back to a raw `Rigor::Type::Nominal`
    #   otherwise.
    # - Anything else falls back to `untyped` and emits an
    #   `:info` diagnostic via the supplied reporter (fail-soft
    #   so an unrecognised bound never crashes the loader).
    #
    # Richer bound forms (parameterised generics, unions,
    # refinements) wait for a follow-up slice's expression
    # parser.
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

        kvs = parse_kv_payload(payload, body_key: nil)

        uri = symbolize_uri(kvs["uri"], reporter: reporter, source_location: source_location)
        return nil if uri.nil?

        arity = coerce_arity(kvs["arity"], reporter: reporter, source_location: source_location)
        return nil if arity.nil?

        variance = coerce_variance(kvs["variance"], arity, reporter: reporter, source_location: source_location)
        return nil if variance.nil?

        bound = resolve_bound(
          kvs["bound"] || DEFAULT_BOUND_LITERAL,
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

        kvs = parse_kv_payload(payload, body_key: "body")

        uri = symbolize_uri(kvs["uri"], reporter: reporter, source_location: source_location)
        return nil if uri.nil?

        params = coerce_params(kvs["params"], reporter: reporter, source_location: source_location)
        return nil if params.nil?

        body = kvs["body"]
        unless body.is_a?(String)
          record_hkt_error(reporter, "hkt_define: missing body=", source_location)
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
        string.each_char do |ch|
          case ch
          when "{" then depth += 1
          when "}"
            depth -= 1
            return false if depth.negative?
          end
        end
        depth.zero?
      end

      # Parses a space-separated `key=value [key=value ...]`
      # payload into a Hash. When `body_key` is supplied AND
      # that key appears, everything from `<body_key>=` to
      # the end of the payload becomes the value (body
      # contents typically include spaces, `|`, `[]` etc.
      # that the simple tokenizer cannot otherwise carry).
      KV_KEY_PATTERN = /(?<![\w.])([a-z_]\w*)=/
      private_constant :KV_KEY_PATTERN

      def parse_kv_payload(payload, body_key:)
        result = {}
        # Find every `<key>=` boundary; each value runs to
        # the next boundary or end of string.
        markers = []
        payload.scan(KV_KEY_PATTERN) { markers << [::Regexp.last_match[1], ::Regexp.last_match.end(0)] }
        markers.each_with_index do |(key, value_start), i|
          if body_key && key == body_key
            result[key] = payload[value_start..].to_s.strip
            break
          end

          value_end = markers[i + 1] ? markers[i + 1][1] - markers[i + 1][0].size - 1 : payload.size
          result[key] = payload[value_start...value_end].to_s.strip
        end
        result
      end

      # ADR-20 slice 2b — parse the body String into an
      # `HktBody::*` tree via {Inference::HktBodyParser.parse}.
      # On parse failure: emit a fail-soft `:info` reporter
      # entry and return `nil` so the resulting Definition
      # keeps its `body` String slot but `body_tree` stays
      # absent (the reducer falls back to `app.bound` at call
      # time per ADR-20 D5).
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

      def symbolize_uri(raw, reporter:, source_location:)
        if raw.nil? || raw.empty?
          record_hkt_error(reporter, "uri= is required", source_location)
          return nil
        end
        unless raw.include?(Type::App::URI_SEPARATOR)
          record_hkt_error(
            reporter,
            "uri must be namespaced as `a::b` per ADR-20 WD1, got #{raw.inspect}",
            source_location
          )
          return nil
        end

        raw.to_sym
      end

      def coerce_arity(raw, reporter:, source_location:)
        if raw && /\A\d+\z/.match?(raw) && raw.to_i.positive?
          raw.to_i
        else
          record_hkt_error(reporter, "arity must be a positive Integer, got #{raw.inspect}", source_location)
          nil
        end
      end

      def coerce_variance(raw, arity, reporter:, source_location:)
        # Omitted variance defaults to `[:inv] * arity` per ADR-20 WD4.
        variance =
          if raw.nil? || raw.empty?
            Array.new(arity, DEFAULT_VARIANCE)
          else
            raw.split(",").map { |v| v.strip.to_sym }
          end

        unless variance.size == arity
          record_hkt_error(reporter, "variance length #{variance.size} does not match arity #{arity}", source_location)
          return nil
        end

        unless variance.all? { |v| %i[out in inv].include?(v) }
          record_hkt_error(
            reporter,
            "variance entries must be `out` / `in` / `inv`, got #{variance.inspect}",
            source_location
          )
          return nil
        end

        variance
      end

      def coerce_params(raw, reporter:, source_location:)
        if raw.nil? || raw.empty?
          record_hkt_error(reporter, "params= is required (comma-separated UCName list)", source_location)
          return nil
        end

        raw.split(",").map { |p| p.strip.to_sym }
      end

      def resolve_bound(raw, name_scope:, reporter:, source_location:)
        return Type::Combinator.untyped if raw.nil? || raw.strip.empty?
        return Type::Combinator.untyped if raw.strip == DEFAULT_BOUND_LITERAL

        class_name = raw.strip
        if /\A(?:::)?(?:[A-Z]\w*)(?:::[A-Z]\w*)*\z/.match?(class_name)
          normalized = class_name.sub(/\A::/, "")
          return Type::Nominal.new(normalized) if name_scope.nil?

          if name_scope.respond_to?(:nominal_for_name)
            resolved = name_scope.nominal_for_name(normalized)
            return resolved if resolved
          end
          return Type::Nominal.new(normalized)
        end

        record_hkt_error(
          reporter,
          "bound `#{raw}` not recognised (accepts `untyped` or a bare class name); falling back to `untyped`",
          source_location
        )
        Type::Combinator.untyped
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
