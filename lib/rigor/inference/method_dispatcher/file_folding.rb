# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # IO / File support — the pure-path-manipulation tier.
      #
      # File and IO carry a lot of side-effecting surface (filesystem
      # reads, descriptor mutations, line iteration) the analyzer
      # cannot fold. But several `File` class methods are pure
      # functions over their path-string arguments — they do NOT
      # touch the filesystem and do NOT depend on the current
      # working directory. Folding them on `Constant<String>`
      # arguments is safe and lets the inference engine carry the
      # exact path string downstream.
      #
      # Hardcoded for now. The future Enumerable-aware tier (or
      # Symbol/String reflection through capability roles) is the
      # right home long-term, but the IO/File surface is a small,
      # stable set so the table stays maintainable.
      #
      # See [ADR-5 — robustness principle](docs/adr/5-robustness-principle.md)
      # clause 1: a strict-as-proven return on these path methods
      # tightens the downstream chain (`File.basename(p).end_with?(".rb")`,
      # `File.extname(p) == ".rb"`, …). The parameter side stays the
      # RBS-declared `_ToPath` because real-world callers pass Pathname
      # / TempFile / String alike.
      module FileFolding
        module_function

        # File class methods that:
        # - are pure over their string-typed arguments,
        # - do not consult the filesystem or the current working
        #   directory,
        # - return a String (or in the case of `split`, a 2-element
        #   String tuple).
        FILE_PURE_CLASS_METHODS = Set[
          :basename,
          :dirname,
          :extname,
          :join,
          :split,
          :absolute_path?
        ].freeze
        private_constant :FILE_PURE_CLASS_METHODS

        # @return [Rigor::Type, nil] folded result, or nil to defer
        #   to the next dispatcher tier.
        def try_dispatch(receiver:, method_name:, args:)
          return nil unless dispatch_target?(receiver)
          return nil unless FILE_PURE_CLASS_METHODS.include?(method_name)

          string_args = constant_string_args(args)
          return nil if string_args.nil?

          fold_class_method(method_name, string_args)
        end

        # Receiver MUST be `Singleton[File]` — the class object for
        # File. `Constant[File]` is theoretically possible but the
        # analyzer represents the class object as Singleton.
        def dispatch_target?(receiver)
          receiver.is_a?(Type::Singleton) && receiver.class_name == "File"
        end

        # Returns the array of underlying String values when every
        # argument is a `Constant<String>` (or a `Constant<Symbol>`,
        # which `File.basename` etc. accept via implicit conversion);
        # nil otherwise.
        def constant_string_args(args)
          return [] if args.empty?
          return nil unless args.all? { |arg| constant_string_arg?(arg) }

          args.map { |arg| arg.value.to_s }
        end

        def constant_string_arg?(arg)
          arg.is_a?(Type::Constant) && (arg.value.is_a?(String) || arg.value.is_a?(Symbol))
        end

        def fold_class_method(method_name, string_args)
          result = File.public_send(method_name, *string_args)
          wrap_result(result)
        rescue StandardError
          nil
        end

        def wrap_result(result)
          case result
          when String, true, false
            Type::Combinator.constant_of(result)
          when Array
            return nil unless result.all?(String)

            Type::Combinator.tuple_of(*result.map { |s| Type::Combinator.constant_of(s) })
          end
        end
      end
    end
  end
end
