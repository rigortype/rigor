# frozen_string_literal: true

require "rbs"

require_relative "../environment/rbs_loader"
require_relative "../rooted_glob"

module Rigor
  module SigGen
    # Issues #2603 and #2605 — the run-wide view of the parameterless headers of generic classes (`class Array`, as
    # sig-gen spelled it before #2436) that `sig/` holds, read before the writer changes anything.
    #
    # rbs rejects a class with `GenericParameterMismatchError` while any one of its declarations opens it bare, so
    # the repair is decided per class, across every file the project's RBS env loads from `signature_paths:`: either
    # every bare opening of the class is repaired, or none is. A class is held back ({#left_bare}) when the body of
    # any of its bare openings names one of the parameters as a relative constant ({.shadowing_names}), because the
    # inserted parameter would capture that name, or when one of its bare openings lies outside the sig root, which
    # the writer never rewrites. Every file under the sig root is read, not only those a candidate of the run routes
    # to, so a bare header whose source file is gone is repaired too (#2603); the other signature paths are read
    # and never written.
    #
    # A file that is not valid UTF-8, or does not parse, is not read: rbs never loads it, and the writer refuses it.
    class GenericHeaderScan
      # One bare opening: the file it is in, the class it opens, the parameter names its body spells, and whether
      # the file is under the sig root (the writer may rewrite it).
      Opening = Data.define(:target, :class_name, :names, :writable)

      # @param sig_root — the directory the writer writes to; the only files it may rewrite.
      # @param signature_dirs — the other directories the RBS env loads (`signature_paths:`), read only. A file
      #   under the sig root is read once, as a writable one.
      # @param spelling_for — called with a class name, returns the header spelling to insert
      #   (`"[unchecked out E]"`), or nil for a class that is not generic with plain parameters only.
      def self.scan(sig_root:, spelling_for:, signature_dirs: [])
        new(spelling_for).tap do |scan|
          scan.read_tree(sig_root, writable: true)
          signature_dirs.each { |dir| scan.read_tree(dir, writable: false) }
        end
      end

      # The names in `names` that the declaration's text after its name (superclass, members, nested declarations)
      # spells as a relative constant (`E`, `E::X`, not `::E` or `Foo::E`). A method type that declares a name as
      # its own type parameter (`def m: [E] (E) -> E`) binds every `E` inside it, so its text does not count for
      # that name. The rest is matched as text, so a comment that spells the name counts.
      def self.shadowing_names(source, decl, names)
        start = decl.location[:name].end_pos
        body = source[start...decl.location.end_pos]
        names.select do |name|
          masked = mask_binders(body, binder_ranges(decl, name), start)
          masked.match?(/(?<![\w:])#{Regexp.escape(name)}(?!\w)/)
        end
      end

      # The source ranges of the method types under `decl` (nested declarations included) that declare `name` as a
      # type parameter of their own.
      def self.binder_ranges(decl, name, ranges = [])
        (decl.respond_to?(:members) ? decl.members : []).each do |member|
          if member.is_a?(RBS::AST::Members::MethodDefinition)
            member.overloads.each do |overload|
              type = overload.method_type
              next unless type.location && type.type_params.any? { |param| param.name.to_s == name }

              ranges << (type.location.start_pos...type.location.end_pos)
            end
          end
          binder_ranges(member, name, ranges)
        end
        ranges
      end

      def self.mask_binders(body, ranges, offset)
        masked = body.dup
        ranges.each do |range|
          from = range.begin - offset
          masked[from, range.size] = " " * range.size if from >= 0 && from + range.size <= masked.size
        end
        masked
      end
      private_class_method :mask_binders

      # The parameter names `[unchecked out K, unchecked out V]` declares; nil when it does not parse.
      def self.parameter_names(spelling)
        _, _, decls = RBS::Parser.parse_signature("class RigorSigGenProbe#{spelling}\nend\n")
        decls.first&.type_params&.map { |param| param.name.to_s }
      rescue RBS::ParsingError
        nil
      end

      def initialize(spelling_for)
        @spelling_for = spelling_for
        @openings = []
        @seen = Set.new
      end

      # Every class to repair, with the spelling to insert: each bare opening of it, in every file read, is clear.
      def repairs
        @repairs ||= by_class.reject { |_, openings| openings.any? { |o| blocking?(o) } }
                             .to_h { |name, _| [name, spelling(name)] }
      end

      # The files that hold a bare opening of a class in {#repairs}, as their `to_s`.
      def repair_targets
        @openings.select { |o| repairs.key?(o.class_name) }.map(&:target).uniq
      end

      # One entry per class held back: `{ class:, targets:, blocking: [...] }`, where `targets` is every file with a
      # bare opening of it and `blocking` the openings that hold it back, each `{ target:, reason:
      # "outside_sig_root" }` (a file the writer does not rewrite) or `{ target:, reason: "names_parameter", names: }`.
      def left_bare
        by_class.filter_map do |name, openings|
          blocking = openings.select { |o| blocking?(o) }
          next if blocking.empty?

          { class: name, targets: openings.map(&:target).uniq, blocking: blocking.map { |o| blocking_entry(o) } }
        end
      end

      def read_tree(dir, writable:)
        return unless dir.directory?

        RootedGlob.glob(dir.to_s, "**/*.rbs").sort.each do |path|
          key = realpath(path)
          read_file(Pathname(path), writable) if @seen.add?(key)
        end
      end

      private

      def blocking?(opening)
        !opening.writable || !opening.names.empty?
      end

      def blocking_entry(opening)
        return { target: opening.target, reason: "outside_sig_root" } unless opening.writable

        { target: opening.target, reason: "names_parameter", names: opening.names }
      end

      def realpath(path)
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path)
      end

      def by_class
        @by_class ||= @openings.group_by(&:class_name).sort.to_h
      end

      def spelling(name)
        @spellings ||= {}
        return @spellings[name] if @spellings.key?(name)

        @spellings[name] = @spelling_for.call(name)
      end

      def read_file(path, writable)
        source = path.read
        return unless source.valid_encoding?

        _, _, decls = RBS::Parser.parse_signature(source)
        collect([path.to_s, writable], source, decls, [])
      rescue RBS::ParsingError, SystemCallError
        nil
      end

      def collect(target, source, decls, prefix)
        decls.each do |decl|
          next unless decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)

          # RBS resolves `module Foo; class ::Set` to the top-level `Set`, and so does this key (#2654).
          path = Environment::RbsLoader.declared_class_path(decl, prefix)
          record(target, source, decl, path.join("::"))
          collect(target, source, decl.members, path)
        end
      end

      def record(target, source, decl, name)
        return unless decl.type_params.empty? && decl.location&.[](:name)

        spelled = spelling(name)
        params = spelled && self.class.parameter_names(spelled)
        return if params.nil?

        file, writable = target
        @openings << Opening.new(target: file, class_name: name, writable: writable,
                                 names: self.class.shadowing_names(source, decl, params))
      end
    end
  end
end
