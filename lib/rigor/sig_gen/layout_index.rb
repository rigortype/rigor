# frozen_string_literal: true

require "rbs"

module Rigor
  module SigGen
    # Pre-scans every `.rbs` file under the configured
    # `signature_paths` to build a `qualified_class_name →
    # sig_file_path` map.
    #
    # ADR-14 path-mapper limitation surfaced repeatedly during
    # the self-dogfood: the existing rigor `sig/` consolidates
    # multiple `.rb` sources into one `.rbs` file (e.g.
    # `sig/rigor/type.rbs` declares all 14 `Type::*` classes,
    # `sig/rigor.rbs` declares `CLI::TypeOfCommand` and
    # `CLI::TypeScanCommand`). The naive 1:1 mapper writes new
    # files alongside the existing consolidated ones, producing
    # `RBS::DuplicatedMethodDefinition` errors at lookup time.
    #
    # The index lets {PathMapper} route a candidate to the
    # consolidated sig file when the class is already declared
    # there, falling back to the 1:1 mirror only when the
    # class has no existing declaration anywhere under the
    # signature tree.
    #
    # First-found wins on duplicate declarations across files;
    # RBS itself allows the same class to be declared in
    # multiple files for additive member contributions, but
    # the writer only needs one canonical target per class.
    class LayoutIndex
      # @param signature_paths [Array<String, Pathname>, nil]
      #   the `.rigor.yml`-configured signature directories.
      #   When `nil` or empty, falls back to `<project_root>/sig`
      #   if it exists (matching `Environment.for_project`'s
      #   auto-detection convention).
      # @param project_root [String, Pathname]
      def initialize(signature_paths:, project_root: Dir.pwd)
        @signature_paths = resolve_paths(signature_paths, project_root)
        @index = nil
      end

      # @param class_name [String] fully-qualified Ruby class
      #   name (e.g. `"Rigor::Type::Top"`).
      # @return [Pathname, nil] absolute path of the sig file
      #   that already declares this class, or `nil` when no
      #   existing declaration is found.
      def file_for(class_name)
        index[class_name]
      end

      def empty?
        index.empty?
      end

      private

      def resolve_paths(configured, project_root)
        list = Array(configured).reject { |p| p.nil? || p.to_s.empty? }
        return list unless list.empty?

        default = Pathname(project_root) / "sig"
        default.directory? ? [default] : []
      end

      def index
        @index ||= build_index
      end

      def build_index
        accumulator = {}
        Array(@signature_paths).each do |dir|
          base = Pathname(dir)
          next unless base.directory?

          Dir.glob(File.join(base.to_s, "**/*.rbs"), sort: true).each do |rbs_file|
            index_file(Pathname(rbs_file), accumulator)
          end
        end
        accumulator.freeze
      end

      def index_file(rbs_path, accumulator)
        source = rbs_path.read
        _, _, decls = RBS::Parser.parse_signature(source)
        record_decls(decls, [], rbs_path, accumulator)
      rescue StandardError
        # Bad RBS file — skip silently; the user's `rigor
        # check` run will surface the real parse error
        # elsewhere.
      end

      def record_decls(decls, prefix, rbs_path, accumulator)
        decls.each { |decl| record_decl(decl, prefix, rbs_path, accumulator) }
      end

      def record_decl(decl, prefix, rbs_path, accumulator)
        return unless decl.is_a?(RBS::AST::Declarations::Class) ||
                      decl.is_a?(RBS::AST::Declarations::Module)

        local_name = decl.name.to_s.sub(/\A::/, "")
        full = prefix.empty? ? local_name : "#{prefix.join('::')}::#{local_name}"
        accumulator[full] ||= rbs_path

        record_decls(decl.members, prefix + [local_name], rbs_path, accumulator)
      end
    end
  end
end
