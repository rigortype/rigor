# frozen_string_literal: true

require "uri"
require_relative "../../type"
require_relative "singleton_folding"

module Rigor
  module Inference
    module MethodDispatcher
      # Folds `URI` module-function calls on statically known string constants.
      #
      # `URI.encode_www_form_component` / `decode_www_form_component` and the newer `encode_uri_component`
      # / `decode_uri_component` are pure, deterministic functions over their string inputs. When the
      # argument is a `Constant[String]`, the analyzer can evaluate the call at inference time and return
      # the concrete `Constant[String]` result.
      #
      # === Supported methods
      #
      # * `encode_www_form_component(str)` / `decode_www_form_component(str)` — RFC 3986 percent-encode /
      #   decode. Returns `Constant[String]`.
      # * `encode_uri_component(str)` / `decode_uri_component(str)` — Same encoding but may preserve
      #   additional reserved chars (Ruby 3.2+). Returns `Constant[String]`.
      # * `encode_www_form(enum)` — the whole-form encoder, over a `Tuple` of `[key, value]` `Tuple`s (an
      #   array literal) or a `HashShape` (a hash literal) whose keys and values are all `Constant`.
      #   Returns `Constant[String]`.
      # * `decode_www_form(str)` — the inverse, over a `Constant[String]`. Returns a `Tuple` of two-element
      #   `Tuple[Constant[String], Constant[String]]` pairs rather than the RBS tier's
      #   `Array[[String, String]]`, so a destructuring read of a known form gets the concrete strings.
      # * `extract(str)` — the URIs a constant string contains, as a `Tuple` of `Constant[String]` rather
      #   than `Array[String]`. Single-argument form only (see {.fold_extract}).
      #
      # === Deliberately NOT folded
      #
      # `URI.parse` and `URI.join` are the two remaining gaps in this module's coverage note, and both are
      # declined on the repo's own existing rule rather than on judgement: they return `URI::Generic` and
      # friends, which are absent from `ConstantFolding::FOLDABLE_CONSTANT_CLASSES`, so there is no
      # `Constant[…]` for this tier to produce. Narrowing `URI.parse`'s ten-arm return union to the one
      # scheme class a constant string selects WOULD be a real precision win, but it makes a gradually-valid
      # dispatch precise and can therefore surface a diagnostic that does not fire today — which puts it in
      # the bucket-3 / P0 category, not in this FP-safe fold category ([#121](
      # https://github.com/rigortype/rigor/issues/121)).
      #
      # === Non-constant / unsupported cases
      #
      # Returns `nil` (deferring to the next dispatcher tier) when:
      # - the receiver is not `Singleton[URI]`,
      # - an argument is not the constant shape the method's fold requires,
      # - the method is not in the supported set.
      module URIFolding
        URI_COMPONENT_METHODS = Set[
          :encode_www_form_component, :decode_www_form_component,
          :encode_uri_component, :decode_uri_component
        ].freeze
        private_constant :URI_COMPONENT_METHODS

        # A form long enough to suggest generated or accumulated data rather than a literal a reader wrote;
        # past it the folded `Constant[String]` stops being useful in a diagnostic and only costs memory.
        # Mirrors the byte ceiling `ShapeDispatch`'s own `tuple_join` fold applies for the same reason.
        FORM_PAIR_LIMIT = 64
        private_constant :FORM_PAIR_LIMIT

        module_function

        # @return [Rigor::Type, nil] folded result, or nil to defer.
        def try_dispatch(context)
          receiver = context.receiver
          method_name = context.method_name
          args = context.args
          return nil unless SingletonFolding.receiver?(receiver, "URI")
          return fold_encode_www_form(args) if method_name == :encode_www_form
          return fold_decode_www_form(args) if method_name == :decode_www_form
          return fold_extract(args) if method_name == :extract
          return nil unless URI_COMPONENT_METHODS.include?(method_name)

          fold_uri_call(method_name, args)
        end

        # `URI.encode_www_form(enum)` — deterministic over its whole input, so it folds only when EVERY key
        # and value is already a `Constant`. One non-constant pair declines the whole call: a partially
        # known form has no `Constant[String]` to stand for it.
        def fold_encode_www_form(args)
          return nil unless args.size == 1

          pairs = form_pairs(args.first)
          return nil if pairs.nil? || pairs.size > FORM_PAIR_LIMIT

          Type::Combinator.constant_of(URI.encode_www_form(pairs))
        rescue StandardError
          nil
        end

        # The `[key, value]` pairs of a literal form argument, or nil when the shape is not fully known:
        # a `Tuple` of two-element `Tuple`s (the array-of-pairs spelling) or a `HashShape` (the hash
        # spelling). `HashShape` pairs are read only when the shape is CLOSED and carries no optional key —
        # an open or partially-optional shape describes a hash whose real contents this fold cannot see.
        def form_pairs(arg)
          case arg
          when Type::Tuple then tuple_form_pairs(arg)
          when Type::HashShape then hash_form_pairs(arg)
          end
        end

        def tuple_form_pairs(tuple)
          tuple.elements.map do |element|
            return nil unless element.is_a?(Type::Tuple) && element.elements.size == 2
            return nil unless element.elements.all?(Type::Constant)

            element.elements.map(&:value)
          end
        end

        def hash_form_pairs(shape)
          return nil unless shape.closed? && shape.optional_keys.empty?

          shape.pairs.map do |key, value|
            return nil unless value.is_a?(Type::Constant)

            [key, value.value]
          end
        end

        # `URI.decode_www_form(str)` — the pair list of a constant form, as a `Tuple` of two-element
        # `Tuple`s so a destructuring read (`k, v = URI.decode_www_form(s).first`) reaches the concrete
        # strings instead of the RBS tier's `Array[[String, String]]`.
        def fold_decode_www_form(args)
          return nil unless args.size == 1

          str = SingletonFolding.constant_string(args.first)
          return nil if str.nil?

          pairs = URI.decode_www_form(str)
          return nil if pairs.size > FORM_PAIR_LIMIT

          Type::Combinator.tuple_of(*pairs.map { |key, value| constant_pair(key, value) })
        rescue StandardError
          nil
        end

        def constant_pair(key, value)
          Type::Combinator.tuple_of(Type::Combinator.constant_of(key), Type::Combinator.constant_of(value))
        end

        # `URI.extract(str)` — the URIs a constant string contains, as a `Tuple` of `Constant[String]`
        # instead of the RBS tier's `Array[String]`. Only the single-argument form folds: the optional
        # second argument is a schema FILTER, and honouring it means reproducing `URI.extract`'s own
        # argument handling rather than the one call this fold makes, so it declines instead.
        #
        # Ruby emits an obsolescence warning for this method under `$VERBOSE`; the fold calls it with
        # warnings silenced, because a warning about the ANALYZED program's API choice must not appear on
        # the analyzer's own stderr, where a reader would attribute it to Rigor.
        def fold_extract(args)
          return nil unless args.size == 1

          str = SingletonFolding.constant_string(args.first)
          return nil if str.nil?

          found = silence_warnings { URI.extract(str) }
          return nil if found.nil? || found.size > FORM_PAIR_LIMIT

          Type::Combinator.tuple_of(*found.map { |uri| Type::Combinator.constant_of(uri) })
        rescue StandardError
          nil
        end

        def silence_warnings
          previous = $VERBOSE
          $VERBOSE = nil
          yield
        ensure
          $VERBOSE = previous
        end

        def fold_uri_call(method_name, args)
          return nil unless args.size == 1

          str = SingletonFolding.constant_string(args.first)
          return nil if str.nil?

          Type::Combinator.constant_of(URI.public_send(method_name, str))
        rescue StandardError
          nil
        end
      end
    end
  end
end
