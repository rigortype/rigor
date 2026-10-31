# frozen_string_literal: true

require_relative "../configuration_error"
require_relative "../rooted_glob"

module Rigor
  class Environment
    # Issue #2517 — a core signature directory chosen IN PLACE OF the `rbs` gem's own `core/` (`core_root:` in
    # `.rigor.yml`). The caller is a provider such as rbs-shifter, which rewrites upstream core for an older
    # CRuby (`Array#rfind` gone, `String#strip` without arguments); Rigor accepts the directory and passes it to
    # `RBS::EnvironmentLoader.new(core_root:)`, so the default core is never loaded beside it.
    #
    # An explicit choice is never second-guessed by a fallback: a directory that is missing, unreadable or holds
    # no signature, and an environment that fails to build from it, raise {CoreRootError} instead of analysing
    # against the default core or against a degraded `Dynamic[top]` environment. Both would report a project as
    # clean for the very APIs the selection exists to reject.
    module CoreRoot
      module_function

      # @param path — the configured directory, already resolved against the config file's directory.
      # @return the absolute directory as a frozen String (`Ractor.shareable?`, so a frozen loader stays shareable).
      # @raise CoreRootError — the directory cannot serve as a core.
      def validate!(path)
        absolute = File.expand_path(path.to_s)
        reason = invalid_reason(absolute)
        raise CoreRootError, "core_root: #{absolute.inspect} #{reason}" if reason

        absolute.dup.freeze
      end

      # A selected core inside a signature root, or one containing it, loads its files twice — once as core and once
      # as project signatures — and every class it declares then fails to build on its duplicated methods.
      #
      # @param core_root — a {.validate!}d directory.
      # @param signature_paths — the project's own signature roots.
      # @raise CoreRootError — the two overlap.
      def reject_overlap!(core_root, signature_paths)
        core = File.join(real_path(core_root), "")
        Array(signature_paths).each do |path|
          root = File.join(real_path(path), "")
          next unless core.start_with?(root) || root.start_with?(core)

          raise CoreRootError, "core_root: #{core_root.inspect} overlaps the signature path #{path.to_s.inspect}, so " \
                               "its signatures would load twice; move the core outside the project's signature paths"
        end
      end

      # Compared resolved, because the project-signature walk does not follow a symlinked directory: a `sig/core`
      # link to a core kept elsewhere loads once, as core, and must not be rejected. A path that does not exist yet
      # resolves through its nearest existing ancestor, so the two sides of a comparison are spelled alike.
      def real_path(path)
        absolute = File.expand_path(path.to_s)
        missing = []
        until File.exist?(absolute) || File.dirname(absolute) == absolute
          missing.unshift(File.basename(absolute))
          absolute = File.dirname(absolute)
        end
        File.join(File.realpath(absolute), *missing)
      rescue SystemCallError
        File.expand_path(path.to_s)
      end

      def invalid_reason(absolute)
        return "does not exist" unless File.exist?(absolute)
        return "is not a directory" unless File.directory?(absolute)
        return "is not readable" unless File.readable?(absolute)

        "contains no .rbs signature file" if RootedGlob.glob(absolute, "**/*.rbs").empty?
      end
    end

    # The selected core cannot be used. A {ConfigurationError}, so the CLI reports it as one `rigor:` line with
    # the usage exit code rather than as a crash.
    class CoreRootError < ConfigurationError
    end
  end
end
