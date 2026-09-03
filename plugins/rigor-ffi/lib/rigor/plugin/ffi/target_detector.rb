# frozen_string_literal: true

module Rigor
  module Plugin
    class FFI < Base
      module TargetDetector
        module_function

        # Detects whether the project targets ffx or the classic ffi gem per WD6.
        def detect(root:, config: {})
          explicit = config["target"] || config[:target]
          return explicit.to_sym if explicit && explicit != "auto"

          return :ffx if extconf_uses_ffx?(root)
          return :ffx if lockfile_has_ffx?(root)

          :ffi
        end

        def extconf_uses_ffx?(root)
          return false if root.nil?

          Dir.glob(File.join(root.to_s, "ext/**/extconf.rb")).any? do |extconf|
            File.read(extconf).include?("FFX.create_makefile")
          rescue SystemCallError
            false
          end
        end

        def lockfile_has_ffx?(root)
          return false if root.nil?

          lockfile = File.join(root.to_s, "Gemfile.lock")
          return false unless File.file?(lockfile)

          File.foreach(lockfile) do |line|
            return true if line =~ /^\s{4}ffx\s/
          end
          false
        rescue SystemCallError
          false
        end
      end
    end
  end
end
