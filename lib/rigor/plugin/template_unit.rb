# frozen_string_literal: true

require "digest"

module Rigor
  module Plugin
    # One **template unit** — a non-Ruby source file a plugin compiled into Ruby, handed to the engine to
    # be parsed and typed like a file (ADR-16 Tier D, revived by #392 as this seam; design note
    # `docs/design/20260816-effect-labels.md` § 11.3).
    #
    # ADR-16's Tier D declared `external_files:` — "files evaluated as if their body were pasted at a
    # declared call site, with `self` typed as a declared class" — and ADR-60 WD1 removed it for want of a
    # consumer. What Tier D lacked, and what this carries, is a **source transform with a line map** ahead
    # of parsing: the file on disk is not Ruby, so the engine analyses `ruby_source` and reports at the
    # template's own lines.
    #
    # A unit is pure data. The plugin's transform runs ONCE, on the parent, before any analysis; nothing
    # here is a callable, so the unit survives `Marshal` into a fork-pool worker exactly as the macro
    # substrate's value objects do.
    #
    # - `logical_name` — the name the unit is keyed by, independent of the handler: `users/show.html`, not
    #   `users/show.html.erb`. Becomes the `view:<logical_name>` effect-unit key, so an ERB → Haml rewrite
    #   is not a rename.
    # - `path` — the template file as the user wrote it. Every diagnostic and every source trace names it.
    # - `ruby_source` — the compiled Ruby the engine parses.
    # - `line_map` — `{ ruby_source line => template line }`, 1-based. A line the map does not mention
    #   anchors at the nearest mapped line before it, and at line 1 when there is none. **An EMPTY map is
    #   the identity, not "no positions"**: every compiled line reports at its own number and the columns
    #   pass through untouched. That is correct only for a transform that emits nothing the template did
    #   not contain — a transform that prepends so much as one preamble line and omits the map reports
    #   every finding off by that many lines. Omit it only for a byte-preserving transform.
    # - `self_type` — the fully-qualified class the body's `self` is typed as, or nil for a bare body.
    # - `locals` — `{ name => type name }`, the parameters the render site passes.
    # - `ivar_seeds` — `{ "@name" => type name }`, the assigns the rendering action set.
    # - `transform_id` — the compiler's identity (`"erubi-1.13"`). Joins the unit digest, so re-compiling
    #   with a different compiler re-analyses. Defaults to the declaring plugin's `id@version`.
    #
    # A type name that resolves to nothing is not an error here: the engine falls back to `Dynamic`, which
    # taints honestly rather than fabricating a type the plugin could not justify (ADR-5).
    class TemplateUnit
      # Bumped whenever the engine changes what it synthesises from a unit — the seeding rules, the
      # scope binding, the effect-unit key spelling. It rides the unit digest, so a change here
      # invalidates every cached run that analysed a unit, exactly as a changed transform does.
      SYNTHESIS_VERSION = 1

      # The prefix an effect-unit key carries for a template unit. Deliberately not a {Effects::MethodKey}
      # shape: a view has no owner class and no selector, and spelling one would put a method in the
      # snapshot that no call site can name.
      KEY_PREFIX = "view:"

      IVAR_NAME = /\A@[A-Za-z_][A-Za-z0-9_]*\z/
      private_constant :IVAR_NAME

      LOCAL_NAME = /\A[a-z_][A-Za-z0-9_]*\z/
      private_constant :LOCAL_NAME

      attr_reader :logical_name, :path, :ruby_source, :line_map, :self_type, :locals, :ivar_seeds,
                  :transform_id

      # Every field is one declared property of the unit; grouping them behind a context object would only
      # move the same list into a second value class.
      def initialize(logical_name:, path:, ruby_source:, line_map: {}, self_type: nil, locals: {}, # rubocop:disable Metrics/ParameterLists
                     ivar_seeds: {}, transform_id: nil)
        @logical_name = validate_string!("logical_name", logical_name)
        @path = validate_string!("path", path)
        @ruby_source = validate_source!(ruby_source)
        @line_map = validate_line_map!(line_map)
        @self_type = self_type.nil? ? nil : validate_string!("self_type", self_type)
        @locals = validate_bindings!("locals", locals, LOCAL_NAME)
        @ivar_seeds = validate_bindings!("ivar_seeds", ivar_seeds, IVAR_NAME)
        @transform_id = transform_id.nil? ? nil : validate_string!("transform_id", transform_id)
        freeze
      end

      # The effect-unit key and the snapshot key: `view:users/show.html`.
      def unit_key
        "#{KEY_PREFIX}#{@logical_name}"
      end

      # The unit's cache identity — **source bytes + transform id + synthesis version**, the triple
      # `docs/internal-spec/cache.md` § computed-value keys asks a synthesised input to carry. The
      # template's own bytes are deliberately NOT in it: the engine analyses `ruby_source`, and two
      # templates that compile to the same Ruby have the same answer.
      #
      # @param fallback_transform_id — the declaring plugin's `id@version`, used when the unit
      #   named no transform of its own.
      def digest(fallback_transform_id = nil)
        Digest::SHA256.hexdigest(
          [
            "source:#{@ruby_source}",
            "transform:#{@transform_id || fallback_transform_id || 'unknown'}",
            "synthesis:#{SYNTHESIS_VERSION}"
          ].join("\x00")
        )
      end

      # The template line a `ruby_source` line reports at. Falls back to the nearest mapped line before it
      # — a synthesised prologue or a buffer-append the compiler emitted between two template lines still
      # points into the template rather than past its end — and to line 1 when the map says nothing at all.
      def template_line(ruby_line)
        return ruby_line if @line_map.empty?
        return @line_map[ruby_line] if @line_map.key?(ruby_line)

        before = @line_map.keys.select { |line| line < ruby_line }
        before.empty? ? 1 : @line_map[before.max]
      end

      def to_h
        {
          "logical_name" => @logical_name, "path" => @path, "ruby_source" => @ruby_source,
          "line_map" => @line_map, "self_type" => @self_type, "locals" => @locals,
          "ivar_seeds" => @ivar_seeds, "transform_id" => @transform_id
        }
      end

      def ==(other)
        other.is_a?(TemplateUnit) && other.to_h == to_h
      end
      alias eql? ==

      def hash
        [self.class, to_h].hash
      end

      private

      def validate_string!(field, value)
        text = value.to_s
        raise ArgumentError, "TemplateUnit #{field} must be a non-empty String" if text.empty?

        text.dup.freeze
      end

      def validate_source!(value)
        raise ArgumentError, "TemplateUnit ruby_source must be a String" unless value.is_a?(String)

        value.dup.freeze
      end

      # 1-based on both sides. A zero or negative line is a compiler bug the engine would turn into a
      # diagnostic positioned off the top of the file, so it is refused at construction.
      def validate_line_map!(value)
        raise ArgumentError, "TemplateUnit line_map must be a Hash" unless value.is_a?(Hash)

        value.to_h do |from, to|
          unless from.is_a?(Integer) && to.is_a?(Integer) && from.positive? && to.positive?
            raise ArgumentError, "TemplateUnit line_map must map positive Integer to positive Integer"
          end

          [from, to]
        end.freeze
      end

      def validate_bindings!(field, value, pattern)
        raise ArgumentError, "TemplateUnit #{field} must be a Hash" unless value.is_a?(Hash)

        value.to_h do |name, type_name|
          key = name.to_s
          raise ArgumentError, "TemplateUnit #{field} key #{key.inspect} is malformed" unless key.match?(pattern)

          [key.dup.freeze, validate_string!("#{field} value", type_name)]
        end.freeze
      end
    end
  end
end
