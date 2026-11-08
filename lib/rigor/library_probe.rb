# frozen_string_literal: true

module Rigor
  # Issue #2961 — answers what `RBS::EnvironmentLoader#has_library?(version: nil)` answers, for the
  # {ConfigAudit} library warnings. The CLI has not loaded `rbs` when that audit runs, and loading it costs
  # ~90 ms on the warm boot-slim path, so without a loaded `rbs` this probes the filesystem instead: a gem's
  # `sig/` directory, or a release-versioned directory under the bundled rbs gem's `stdlib/<name>/`
  # (`Repository::GemRBS#load!`). A probe that cannot place the rbs gem answers true: it never warns when unsure.
  module LibraryProbe
    module_function

    # @return [#call] lib name -> Boolean
    def predicate
      if defined?(::RBS::EnvironmentLoader)
        return ->(lib) { ::RBS::EnvironmentLoader.new.has_library?(library: lib, version: nil) }
      end

      stdlib = stdlib_root
      return ->(_lib) { true } if stdlib.nil?

      ->(lib) { gem_sig_dir?(lib) || stdlib_library?(stdlib, lib) }
    end

    def stdlib_root
      dir = File.join(Gem::Specification.find_by_name("rbs").gem_dir, "stdlib")
      File.directory?(dir) ? dir : nil
    rescue Gem::LoadError
      nil
    end

    def gem_sig_dir?(name)
      File.directory?(File.join(Gem::Specification.find_by_name(name).gem_dir, "sig"))
    rescue Gem::MissingSpecError
      false
    rescue Gem::LoadError
      true
    end

    def stdlib_library?(stdlib, name)
      return false if name.include?("/") || name.include?("\0")

      Dir.children(File.join(stdlib, name)).any? do |child|
        Gem::Version.correct?(child) && !Gem::Version.create(child).prerelease?
      end
    rescue SystemCallError
      false
    end
  end
end
