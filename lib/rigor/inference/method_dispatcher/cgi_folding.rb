# frozen_string_literal: true

require "cgi/util"
require_relative "../../type"
require_relative "singleton_folding"

module Rigor
  module Inference
    module MethodDispatcher
      # Folds `CGI` module-function calls on statically known
      # string constants.
      #
      # `CGI.escapeHTML` / `CGI.unescapeHTML` and related methods
      # are pure, deterministic functions over their string inputs.
      # When the argument is a `Constant[String]`, the analyzer can
      # evaluate the call at inference time and return the concrete
      # `Constant[String]` result.
      #
      # === Supported methods
      #
      # * `escapeHTML(str)` / `escape_html(str)` / `h(str)` —
      #   HTML-escape. Returns `Constant[String]`.
      # * `unescapeHTML(str)` / `unescape_html(str)` —
      #   HTML-unescape. Returns `Constant[String]`.
      # * `escape(str)` / `unescape(str)` —
      #   URL-encode / decode (`application/x-www-form-urlencoded`).
      #   Returns `Constant[String]`.
      # * `escapeURIComponent(str)` / `escape_uri_component(str)`,
      #   `unescapeURIComponent(str)` / `unescape_uri_component(str)` —
      #   URI-component percent-encode / decode. Returns `Constant[String]`.
      # * `escapeElement(str, *elements)` / `escape_element(str, *elements)`,
      #   `unescapeElement(str, *elements)` / `unescape_element(str, *elements)` —
      #   element-level escape / unescape (first arg is the string,
      #   remaining args are element names). Returns `Constant[String]`.
      #
      # === Non-constant / unsupported cases
      #
      # Returns `nil` (deferring to the next dispatcher tier) when:
      # - the receiver is not `Singleton[CGI]`,
      # - the first argument is not a `Constant[String]`,
      # - the method is not in the supported set.
      module CGIFolding
        CGI_HTML_ESCAPE_METHODS = Set[:escapeHTML, :escape_html, :h].freeze
        CGI_HTML_UNESCAPE_METHODS = Set[:unescapeHTML, :unescape_html].freeze
        CGI_URL_ESCAPE_METHODS = Set[:escape, :unescape].freeze
        CGI_URI_ESCAPE_METHODS = Set[
          :escapeURIComponent, :escape_uri_component,
          :unescapeURIComponent, :unescape_uri_component
        ].freeze
        CGI_ELEMENT_ESCAPE_METHODS = Set[
          :escapeElement, :escape_element,
          :unescapeElement, :unescape_element
        ].freeze
        CGI_ALL_ESCAPE_METHODS = (
          CGI_HTML_ESCAPE_METHODS | CGI_HTML_UNESCAPE_METHODS |
          CGI_URL_ESCAPE_METHODS | CGI_URI_ESCAPE_METHODS |
          CGI_ELEMENT_ESCAPE_METHODS
        ).freeze

        private_constant :CGI_HTML_ESCAPE_METHODS, :CGI_HTML_UNESCAPE_METHODS,
                         :CGI_URL_ESCAPE_METHODS, :CGI_URI_ESCAPE_METHODS,
                         :CGI_ELEMENT_ESCAPE_METHODS, :CGI_ALL_ESCAPE_METHODS

        module_function

        # @return [Rigor::Type, nil] folded result, or nil to defer.
        def try_dispatch(receiver:, method_name:, args:)
          return nil unless SingletonFolding.receiver?(receiver, "CGI")
          return nil unless CGI_ALL_ESCAPE_METHODS.include?(method_name)

          fold_cgi_call(method_name, args)
        end

        def fold_cgi_call(method_name, args)
          return nil if args.empty?

          str = SingletonFolding.constant_string(args.first)
          return nil if str.nil?

          if CGI_ELEMENT_ESCAPE_METHODS.include?(method_name)
            fold_cgi_element(method_name, str, args.drop(1))
          else
            Type::Combinator.constant_of(CGI.public_send(method_name, str))
          end
        rescue StandardError
          nil
        end

        # `CGI.escapeElement(str, "elem1", "elem2", ...)` — element-
        # level escape / unescape. The remaining args after the first
        # must be `Constant[String]` element names.
        def fold_cgi_element(method_name, str, element_args)
          elements = element_args.map do |arg|
            value = SingletonFolding.constant_string(arg)
            return nil if value.nil?

            value
          end

          Type::Combinator.constant_of(CGI.public_send(method_name, str, *elements))
        rescue StandardError
          nil
        end
      end
    end
  end
end
