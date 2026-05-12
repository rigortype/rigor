# frozen_string_literal: true

module Rigor
  module SigGen
    # Maps a source `.rb` file to its target `.rbs` sig file
    # under the project's signature tree.
    #
    # ADR-14 § "Output layout":
    # - `--write` MUST NOT touch files outside
    #   `configuration.signature_paths` (default `sig/`).
    # - The first slice supports one source file → one RBS
    #   file; multi-class files emit one RBS containing both
    #   classes (handled by the {Writer}, not here).
    #
    # The mapping convention mirrors the Ruby community
    # default: strip the source root prefix (the first entry
    # of `configuration.paths`, typically `"lib"`), swap the
    # extension, and place the result under the first entry of
    # `configuration.signature_paths` (typically `"sig"`).
    #
    # ADR-14 follow-up: when a class is already declared in
    # an existing consolidated sig file (e.g. `sig/rigor/type.rbs`
    # holds all `Rigor::Type::*` classes), the optional
    # `LayoutIndex` re-routes the target to that file so the
    # writer updates the consolidated declaration instead of
    # creating a duplicate at the 1:1 mirror path.
    #
    # When the source path is not under any configured source
    # root (e.g. files supplied directly on the CLI from
    # outside `lib/`), the full relative path is preserved
    # under the sig root.
    class PathMapper
      # @param configuration [Rigor::Configuration]
      # @param project_root [String, Pathname] (defaults to `Dir.pwd`)
      # @param layout_index [LayoutIndex, nil] optional class
      #   → existing sig file index; routes the target to the
      #   consolidated file when the class is already declared.
      def initialize(configuration:, project_root: Dir.pwd, layout_index: nil)
        @configuration = configuration
        @project_root = Pathname(project_root)
        @layout_index = layout_index
      end

      # @param source_path [String]
      # @param class_name [String, nil] fully-qualified Ruby
      #   class name. When supplied and matched by the
      #   `LayoutIndex`, the consolidated sig file's path is
      #   returned instead of the 1:1 mirror.
      # @return [Pathname] absolute path of the target `.rbs`
      #   file for the candidate.
      def target_for(source_path, class_name: nil)
        existing = existing_target_for(class_name)
        return existing if existing

        rel_to_root = source_relative_to_root(source_path)
        stripped = strip_source_root(rel_to_root)
        sig_root_dir / "#{stripped.sub_ext('')}.rbs"
      end

      def existing_target_for(class_name)
        return nil if class_name.nil? || @layout_index.nil?

        @layout_index.file_for(class_name)
      end

      # The directory `--write` is allowed to create / modify.
      # Used by callers to assert the target stays inside the
      # configured signature tree before touching the disk.
      def sig_root_dir
        @sig_root_dir ||= @project_root / sig_root_name
      end

      private

      def source_relative_to_root(source_path)
        path = Pathname(source_path)
        return path unless path.absolute?

        # Both sides go through realpath so macOS `/tmp` vs
        # `/private/tmp` (and any other symlinked project
        # root) compare cleanly.
        path.realpath.relative_path_from(@project_root.realpath)
      rescue ArgumentError, Errno::ENOENT
        path
      end

      def strip_source_root(rel_path)
        source_root = source_root_name
        return rel_path if source_root.nil?

        first = rel_path.each_filename.first
        return rel_path unless first == source_root

        components = rel_path.each_filename.drop(1)
        components.empty? ? Pathname("") : Pathname(components.join(File::SEPARATOR))
      end

      # `Configuration` resolves `paths:` and `signature_paths:`
      # to absolute Strings. We only need the trailing basename
      # for the mapping (`/abs/lib` → `lib`, `/abs/app` → `app`).
      def source_root_name
        @source_root_name ||= begin
          path = @configuration.paths.first
          path.nil? || path.empty? ? nil : Pathname(path).basename.to_s
        end
      end

      def sig_root_name
        @sig_root_name ||= begin
          first_sig = Array(@configuration.signature_paths).first
          first_sig.nil? ? "sig" : Pathname(first_sig).basename.to_s
        end
      end
    end
  end
end
