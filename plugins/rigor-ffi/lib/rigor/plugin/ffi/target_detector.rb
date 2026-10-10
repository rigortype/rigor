# frozen_string_literal: true

module Rigor
  module Plugin
    class FFI < Base
      # Issue #1652 — given the plugin's {Rigor::Plugin::IoBoundary} (`io:`), every read goes through it, so the
      # files the target was detected from are dependency rows of every cache built on the run. The
      # `--incremental` run-result slot and the plain run-result cache serve an unchanged run without loading
      # this plugin, and see a target flip only through those rows. `io: nil` reads the filesystem directly.
      module TargetDetector
        module_function

        EXTCONF_GLOB = "ext/**/extconf.rb"

        # Detects whether the project targets ffx or the classic ffi gem per WD6.
        def detect(root:, config: {}, io: nil)
          explicit = config["target"] || config[:target]
          return explicit.to_sym if explicit && explicit != "auto"

          return :ffx if extconf_uses_ffx?(root, io)
          return :ffx if lockfile_has_ffx?(root, io)

          :ffi
        end

        def extconf_uses_ffx?(root, io = nil)
          return false if root.nil?

          extconfs = io ? io.glob(root.to_s, EXTCONF_GLOB) : Dir.glob(File.join(root.to_s, EXTCONF_GLOB))
          extconfs.any? do |extconf|
            read_text(extconf, io).include?("FFX.create_makefile")
          rescue SystemCallError
            false
          end
        end

        def lockfile_has_ffx?(root, io = nil)
          return false if root.nil?

          lockfile = File.join(root.to_s, "Gemfile.lock")
          return false unless io ? io.file?(lockfile) : File.file?(lockfile)

          read_text(lockfile, io).each_line.any? { |line| line.match?(/^\s{4}ffx\s/) }
        rescue SystemCallError
          false
        end

        # A path outside the boundary's trust policy is refused there and read directly here: the target does
        # not depend on the policy, and the boundary has noted the refusal (ADR-2 accepts that such a read
        # leaves no row). Only a root outside every read root reaches it: a `root:` configured elsewhere, or a
        # path spelled through a symlink (#959). Each extconf glob match is read here, not just listed: the
        # glob's row records membership only, and this read's row carries an edit.
        def read_text(path, io)
          return File.read(path) if io.nil?

          io.read_file(path)
        rescue Rigor::Plugin::AccessDeniedError
          File.read(path)
        end
      end
    end
  end
end
