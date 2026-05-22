# frozen_string_literal: true

require "uri"
require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Folds `URI` module-function calls on statically known
      # string constants.
      #
      # `URI.encode_www_form_component` / `decode_www_form_component`
      # and the newer `encode_uri_component` / `decode_uri_component`
      # are pure, deterministic functions over their string inputs.
      # When the argument is a `Constant[String]`, the analyzer can
      # evaluate the call at inference time and return the concrete
      # `Constant[String]` result.
      #
      # === Supported methods
      #
      # * `encode_www_form_component(str)` / `decode_www_form_component(str)` —
      #   RFC 3986 percent-encode / decode. Returns `Constant[String]`.
      # * `encode_uri_component(str)` / `decode_uri_component(str)` —
      #   Same encoding but may preserve additional reserved chars
      #   (Ruby 3.2+). Returns `Constant[String]`.
      #
      # === Non-constant / unsupported cases
      #
      # Returns `nil` (deferring to the next dispatcher tier) when:
      # - the receiver is not `Singleton[URI]`,
      # - the first argument is not a `Constant[String]`,
      # - the method is not in the supported set.
      module URIFolding
        URI_COMPONENT_METHODS = Set[
          :encode_www_form_component, :decode_www_form_component,
          :encode_uri_component, :decode_uri_component
        ].freeze
        private_constant :URI_COMPONENT_METHODS

        module_function

        # @return [Rigor::Type, nil] folded result, or nil to defer.
        def try_dispatch(receiver:, method_name:, args:)
          return nil unless dispatch_target?(receiver)
          return nil unless URI_COMPONENT_METHODS.include?(method_name)

          fold_uri_call(method_name, args)
        end

        def dispatch_target?(receiver)
          receiver.is_a?(Type::Singleton) && receiver.class_name == "URI"
        end

        def fold_uri_call(method_name, args)
          return nil unless args.size == 1

          arg = args.first
          return nil unless arg.is_a?(Type::Constant) && arg.value.is_a?(String)

          Type::Combinator.constant_of(URI.public_send(method_name, arg.value))
        rescue StandardError
          nil
        end
      end
    end
  end
end
