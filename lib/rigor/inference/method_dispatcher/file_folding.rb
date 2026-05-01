# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # IO / File support — the pure-path-manipulation tier.
      #
      # File and IO carry a lot of side-effecting surface (filesystem
      # reads, descriptor mutations, line iteration) the analyzer
      # cannot fold. Several `File` class methods, however, are
      # functions over their path-string arguments — they do NOT
      # touch the filesystem and do NOT depend on the current
      # working directory.
      #
      # Folding them is platform-sensitive: every recognised method
      # ([:basename, :dirname, :extname, :join, :split,
      # :absolute_path?]) reads `File::SEPARATOR` /
      # `File::ALT_SEPARATOR` and produces different answers on
      # Windows vs POSIX hosts. The Ruby process running the
      # analyzer hosts ONE platform; folding to a `Constant<String>`
      # would silently bake that platform's answer into the
      # analyzer's result and mis-report it on a host with a
      # different separator policy.
      #
      # Default policy (`fold_platform_specific_paths == false`):
      # decline the fold so the RBS tier answers with `Nominal[String]`
      # / `Tuple[Nominal[String], Nominal[String]]` / `bool`. That is
      # the platform-agnostic envelope — every concrete answer the
      # method could legally return on any platform fits inside it.
      # The future `non-empty-string` refinement carrier (see
      # [imported-built-in-types.md](../../../../../docs/type-specification/imported-built-in-types.md))
      # will tighten the basename/dirname/join cases further without
      # leaking platform specifics; today we leave them at the
      # nominal envelope.
      #
      # Opt-in policy (`fold_platform_specific_paths == true`):
      # the analyzer trusts that its host platform matches the
      # callers' deployment target and folds to a precise
      # `Constant<String>`. Single-platform projects (most internal
      # tooling, Rails apps deployed to Linux containers) can
      # enable this in `.rigor.yml`:
      #
      #   fold_platform_specific_paths: true
      #
      # The runner reads this on startup (`Rigor::Analysis::Runner`)
      # and writes the flag here. Tests toggle the flag explicitly.
      #
      # See [ADR-5 — robustness principle](../../../../../docs/adr/5-robustness-principle.md):
      # the platform-agnostic default is clause-1 of the principle
      # applied with the constraint that "as strict as can be
      # *correctness-preservingly* proved" excludes Constants whose
      # value is host-specific.
      module FileFolding
        # File class methods that the analyzer can fold *when the
        # fold is platform-safe to perform*. Today every entry is
        # platform-sensitive (every one observes `File::SEPARATOR`
        # or `File::ALT_SEPARATOR`); the gate below requires the
        # opt-in flag for any of them to fire.
        FILE_PURE_CLASS_METHODS = Set[
          :basename,
          :dirname,
          :extname,
          :join,
          :split,
          :absolute_path?
        ].freeze
        private_constant :FILE_PURE_CLASS_METHODS

        # Methods whose result depends on host directory-separator
        # semantics (`/` on POSIX, `/` AND `\` on Windows, drive
        # letters, UNC paths). Folding these would bake the
        # analyzer-host's platform into the inferred type. The opt-
        # in flag below controls whether to do it anyway.
        PLATFORM_DEPENDENT_METHODS = Set[
          :basename, :dirname, :extname, :join, :split, :absolute_path?
        ].freeze
        private_constant :PLATFORM_DEPENDENT_METHODS

        class << self
          # Module-global flag. The runner sets it from
          # `Rigor::Configuration#fold_platform_specific_paths`.
          # Tests toggle it directly.
          attr_accessor :fold_platform_specific_paths
        end
        self.fold_platform_specific_paths = false

        module_function

        # @return [Rigor::Type, nil] folded result, or nil to defer
        #   to the next dispatcher tier.
        def try_dispatch(receiver:, method_name:, args:)
          return nil unless dispatch_target?(receiver)
          return nil unless FILE_PURE_CLASS_METHODS.include?(method_name)
          return nil if platform_specific_skip?(method_name)

          string_args = constant_string_args(args)
          return nil if string_args.nil?

          fold_class_method(method_name, string_args)
        end

        def platform_specific_skip?(method_name)
          PLATFORM_DEPENDENT_METHODS.include?(method_name) &&
            !FileFolding.fold_platform_specific_paths
        end

        def dispatch_target?(receiver)
          receiver.is_a?(Type::Singleton) && receiver.class_name == "File"
        end

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
