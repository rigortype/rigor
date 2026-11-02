# frozen_string_literal: true

require "rbs"

require_relative "../rooted_glob"

module Rigor
  module SigGen
    # Issues #2603 and #2605 — the run-wide view of the parameterless headers of generic classes (`class Array`, as
    # sig-gen spelled it before #2436) that `sig/` holds, read before the writer changes anything.
    #
    # rbs rejects a class with `GenericParameterMismatchError` while any one of its declarations opens it bare, so
    # the repair is decided per class, across every file under the sig root: either every bare opening of the class
    # is repaired, or none is. A class is held back ({#left_bare}) when the body of any of its bare openings names
    # one of the parameters as a relative constant ({.shadowing_names}), because the inserted parameter would capture
    # that name. Every file under the sig root is read, not only those a candidate of the run routes to, so a bare
    # header whose source file is gone is repaired too (#2603).
    #
    # A file that is not valid UTF-8, or does not parse, is not read: rbs never loads it, and the writer refuses it.
    class GenericHeaderScan
      # One bare opening: the file it is in, the class it opens, and the parameter names its body spells.
      Opening = Data.define(:target, :class_name, :names)

      # @param sig_root — the directory the writer writes to; nothing outside it is read.
      # @param spelling_for — called with a class name, returns the header spelling to insert
      #   (`"[unchecked out E]"`), or nil for a class that is not generic with plain parameters only.
      def self.scan(sig_root:, spelling_for:)
        new(spelling_for).tap { |scan| scan.read_tree(sig_root) }
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
      end

      # Every class to repair, with the spelling to insert: each bare opening of it, in every file read, is clear.
      def repairs
        @repairs ||= by_class.reject { |_, openings| openings.any? { |o| !o.names.empty? } }
                             .to_h { |name, _| [name, spelling(name)] }
      end

      # The files that hold a bare opening of a class in {#repairs}, as their `to_s`.
      def repair_targets
        @openings.select { |o| repairs.key?(o.class_name) }.map(&:target).uniq
      end

      # One entry per class held back: `{ class:, targets:, blocking: [{ target:, names: }] }`, where `targets` is
      # every file with a bare opening of it and `blocking` the openings whose body names a parameter.
      def left_bare
        by_class.filter_map do |name, openings|
          blocking = openings.reject { |o| o.names.empty? }
          next if blocking.empty?

          { class: name, targets: openings.map(&:target).uniq,
            blocking: blocking.map { |o| { target: o.target, names: o.names } } }
        end
      end

      def read_tree(sig_root)
        return unless sig_root.directory?

        RootedGlob.glob(sig_root.to_s, "**/*.rbs").sort.each { |path| read_file(Pathname(path)) }
      end

      private

      def by_class
        @by_class ||= @openings.group_by(&:class_name).sort.to_h
      end

      def spelling(name)
        @spellings ||= {}
        return @spellings[name] if @spellings.key?(name)

        @spellings[name] = @spelling_for.call(name)
      end

      def read_file(path)
        source = path.read
        return unless source.valid_encoding?

        _, _, decls = RBS::Parser.parse_signature(source)
        collect(path.to_s, source, decls, [])
      rescue RBS::ParsingError, SystemCallError
        nil
      end

      def collect(target, source, decls, prefix)
        decls.each do |decl|
          next unless decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)

          local = decl.name.to_s.delete_prefix("::")
          # The naming {Writer#find_class_decls} uses, so a class this scan clears is the one the writer repairs.
          name = prefix.empty? ? local : "#{prefix.join('::')}::#{local}"
          record(target, source, decl, name)
          collect(target, source, decl.members, prefix + [local])
        end
      end

      def record(target, source, decl, name)
        return unless decl.type_params.empty? && decl.location&.[](:name)

        spelled = spelling(name)
        params = spelled && self.class.parameter_names(spelled)
        return if params.nil?

        @openings << Opening.new(target: target, class_name: name,
                                 names: self.class.shadowing_names(source, decl, params))
      end
    end
  end
end
