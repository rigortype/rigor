# frozen_string_literal: true

require "rbs"

module Rigor
  module SigGen
    # Pre-scans every `.rbs` file under the configured `signature_paths` to build a `qualified_class_name →
    # sig_file_path` map.
    #
    # ADR-14 path-mapper limitation surfaced repeatedly during the self-dogfood: the existing rigor `sig/`
    # consolidates multiple `.rb` sources into one `.rbs` file (e.g. `sig/rigor/type.rbs` declares all 14
    # `Type::*` classes, `sig/rigor.rbs` declares `CLI::TypeOfCommand` and `CLI::TypeScanCommand`). The naive
    # 1:1 mapper writes new files alongside the existing consolidated ones, producing
    # `RBS::DuplicatedMethodDefinition` errors at lookup time.
    #
    # The index lets {PathMapper} route a candidate to the consolidated sig file when the class is already
    # declared there, falling back to the 1:1 mirror only when the class has no existing declaration anywhere
    # under the signature tree.
    #
    # First-found wins on duplicate declarations across files; RBS itself allows the same class to be declared
    # in multiple files for additive member contributions, but the writer only needs one canonical target per
    # class.
    #
    # ADR-122 WD2 adds the member level: `(class_name, method_name, kind) → sig_file_path`, so a member the project
    # already declares in one file is updated there rather than inserted a second time into the class's
    # first-found file (#1488).
    class LayoutIndex
      # The `[method_name, kind]` keys a member declaration answers for, `kind` being `:instance` or
      # `:singleton`. A `def self?.f` answers for both kinds; an `attr_accessor` answers for its reader and its
      # writer. Shared with {Writer}, which asks the same question of the target file it is merging into.
      def self.member_keys(member)
        case member
        when RBS::AST::Members::MethodDefinition
          kinds = member.kind == :singleton_instance ? %i[instance singleton] : [member.kind]
          kinds.map { |kind| [member.name, kind] }
        when RBS::AST::Members::AttrReader then [[member.name, member.kind]]
        when RBS::AST::Members::AttrWriter then [[:"#{member.name}=", member.kind]]
        when RBS::AST::Members::AttrAccessor then [[member.name, member.kind], [:"#{member.name}=", member.kind]]
        else []
        end
      end

      # @param signature_paths —
      #   the `.rigor.yml`-configured signature directories.
      #   When `nil` or empty, falls back to `<project_root>/sig`
      #   if it exists (matching `Environment.for_project`'s
      #   auto-detection convention).
      def initialize(signature_paths:, project_root: Dir.pwd)
        @signature_paths = resolve_paths(signature_paths, project_root)
        @index = nil
        @members = nil
      end

      # @param class_name — fully-qualified Ruby class
      #   name (e.g. `"Rigor::Type::Top"`).
      # @return absolute path of the sig file
      #   that already declares this class, or `nil` when no
      #   existing declaration is found.
      def file_for(class_name)
        index[class_name]
      end

      # @return absolute path of the first sig file (in the same order as {#file_for}) that declares
      #   `method_name` of `kind` on `class_name`, or `nil` when no file does.
      def member_file_for(class_name, method_name, kind)
        index
        @members[[class_name, method_name, kind]]
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
        @members = {}
        Array(@signature_paths).each do |dir|
          base = Pathname(dir)
          next unless base.directory?

          Dir.glob(File.join(base.to_s, "**/*.rbs"), sort: true).each do |rbs_file|
            index_file(Pathname(rbs_file), accumulator)
          end
        end
        @members.freeze
        accumulator.freeze
      end

      def index_file(rbs_path, accumulator)
        source = rbs_path.read
        # Pre-parser encoding guard (mirrors `Environment::RbsLoader.invalid_encoding?`): on rbs releases
        # before 4.1 the C lexer could hang on an invalid UTF-8 byte, and a hang is the one failure the
        # rescue below cannot absorb. Skipping is safe here for the same reason the rescue is — placement
        # falls back as for any unparseable file, and the env loader's quarantine warning names the file.
        return unless source.valid_encoding?

        _, _, decls = RBS::Parser.parse_signature(source)
        record_decls(decls, [], rbs_path, accumulator)
      rescue StandardError
        # Bad RBS file — skip silently; the user's `rigor check` run will surface the real parse error
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
        decl.members.each do |member|
          # An `overloading?` member (`def f: ... | ...`) adds to a declaration elsewhere; routing a candidate to
          # it would replace the user's overload.
          next if member.is_a?(RBS::AST::Members::MethodDefinition) && member.overloading?

          self.class.member_keys(member).each { |name, kind| @members[[full, name, kind]] ||= rbs_path }
        end

        record_decls(decl.members, prefix + [local_name], rbs_path, accumulator)
      end
    end
  end
end
