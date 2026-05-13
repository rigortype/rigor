# frozen_string_literal: true

require "fileutils"
require "rbs"

require_relative "classification"
require_relative "write_result"

module Rigor
  module SigGen
    # Applies a per-source-file group of {MethodCandidate}s to
    # the target `.rbs` file under the project signature tree.
    #
    # ADR-14 slice 2: the writer parses the target with
    # `RBS::Parser` to find the matching class declaration and
    # inserts new method declarations just before the class's
    # closing `end` keyword. Existing declarations are NEVER
    # touched unless `--overwrite` is set AND the candidate's
    # classification is `tighter-return`.
    #
    # The slice does NOT re-render the whole file through
    # `RBS::Writer`. That would lose comments / blank-line
    # formatting per upstream design; the byte-range insertion
    # approach taken here preserves untouched declarations
    # verbatim. Mixed hand-written + generated output inside
    # the *same* class declaration may still lose trailing
    # blank lines on the touched ranges; the `--diff` review
    # surface from slice 1 is the user's escape hatch.
    #
    # Safety boundary: the writer ASSERTS the target lives
    # inside the configured signature tree before touching the
    # disk. Files outside that tree route through
    # `WriteResult(action: :skipped_outside_sig_root)`; the
    # caller decides whether to warn or fail.
    class Writer # rubocop:disable Metrics/ClassLength
      INDENT = "  "
      private_constant :INDENT

      # Per-`update_existing` accumulator. The merge_class
      # helper mutates `source` / `decls` / `applied` /
      # `skipped` in place as each class is processed so the
      # next class sees the latest byte positions.
      MergeState = Struct.new(:source, :decls, :applied, :skipped, keyword_init: true)
      private_constant :MergeState

      def initialize(path_mapper:, overwrite: false)
        @path_mapper = path_mapper
        @overwrite = overwrite
      end

      # Process the full candidate list by resolving each
      # candidate's target sig file via the path mapper (which
      # may route consolidated-layout classes to existing
      # files) and grouping candidates that share a target
      # before writing.
      #
      # ADR-14 follow-up: this is the consolidated-layout
      # entry point. The legacy `write(source_path, candidates)`
      # below assumes all candidates share a target and
      # remains for spec convenience.
      #
      # @param candidates [Array<MethodCandidate>]
      # @return [Array<WriteResult>] one per target sig file.
      def write_all(candidates)
        emittable = candidates.select { |c| EMITTABLE.include?(c.classification) }
        return [] if emittable.empty?

        emittable.group_by { |c| @path_mapper.target_for(c.path, class_name: c.class_name) }
                 .map { |target, group| write_target(target, group) }
      end

      # @param source_path [String]
      # @param candidates [Array<MethodCandidate>] only
      #   emittable classifications (new-method /
      #   tighter-return) are honoured; the caller is
      #   responsible for filtering.
      # @return [WriteResult]
      def write(source_path, candidates)
        emittable = candidates.select { |c| EMITTABLE.include?(c.classification) }
        return WriteResult.new(source_path: source_path, target_path: nil, action: :noop) if emittable.empty?

        target = @path_mapper.target_for(source_path, class_name: emittable.first.class_name)
        write_target(target, emittable, source_path: source_path)
      end

      private

      # Shared per-target write path used by both `#write` and
      # `#write_all`. Picks a representative `source_path` for
      # the {WriteResult} when multiple candidates merge into
      # one target.
      def write_target(target, candidates, source_path: nil)
        source_path ||= candidates.first&.path
        unless inside_sig_root?(target)
          return WriteResult.new(source_path: source_path, target_path: target,
                                 action: :skipped_outside_sig_root)
        end

        target.exist? ? update_existing(source_path, target, candidates) : create_new(source_path, target, candidates)
      end

      EMITTABLE = [Classification::NEW_METHOD, Classification::TIGHTER_RETURN].freeze
      private_constant :EMITTABLE

      def inside_sig_root?(target)
        root = @path_mapper.sig_root_dir.realpath
        target.expand_path.ascend.any? { |ancestor| realpath_or_nil(ancestor) == root }
      rescue Errno::ENOENT
        # The sig root doesn't exist yet; we'll create it
        # alongside the target file. Allow this case.
        target.expand_path.to_s.start_with?(@path_mapper.sig_root_dir.expand_path.to_s)
      end

      def realpath_or_nil(path)
        path.realpath
      rescue Errno::ENOENT
        nil
      end

      def create_new(source_path, target, candidates)
        FileUtils.mkdir_p(target.dirname)
        target.write(render_new_file(candidates))
        WriteResult.new(source_path: source_path, target_path: target,
                        action: :created, applied: candidates)
      end

      def render_new_file(candidates)
        candidates.group_by(&:class_name).map do |class_name, methods|
          render_nested_class(class_name, methods)
        end.join("\n")
      end

      # Emits a class/module declaration wrapped in nested
      # `module` / `class` blocks for every namespace segment,
      # matching the canonical RBS layout in this project's
      # `sig/`. `Rigor::Analysis::DependencySourceInference::GemResolver`
      # becomes:
      #
      #     module Rigor
      #       module Analysis
      #         module DependencySourceInference
      #           module GemResolver
      #             ...method declarations...
      #           end
      #         end
      #       end
      #     end
      #
      # ADR-14 gap-#3 follow-up: each segment's keyword
      # (`module` vs `class`) is looked up in the candidate's
      # `namespace_kinds` map (populated by the generator from
      # the source AST). Unknown segments default to `module`
      # — safer than `class` because RBS allows multiple
      # `module Foo` declarations to merge but rejects
      # duplicate `class Foo` declarations as
      # `RBS::DuplicatedDeclarationError`.
      def render_nested_class(class_name, methods)
        segments = class_name.split("::")
        leaf = segments.last
        prefix = segments[0..-2]
        kinds = methods.first.namespace_kinds || {}
        leaf_keyword = kinds[class_name] || :class

        body_lines = methods.map(&:rbs)
        wrap_in_modules(prefix, "#{leaf_keyword} #{leaf}", body_lines, [], kinds, 0)
      end

      def wrap_in_modules(prefix, leaf_header, body_lines, accumulated, kinds, depth) # rubocop:disable Metrics/ParameterLists
        indent = INDENT * depth
        if prefix.empty?
          inner_indent = INDENT * (depth + 1)
          lines = body_lines.map { |line| "#{inner_indent}#{line}" }
          "#{indent}#{leaf_header}\n#{lines.join("\n")}\n#{indent}end\n"
        else
          seg = prefix.first
          new_accumulated = accumulated + [seg]
          full = new_accumulated.join("::")
          keyword = kinds[full] || :module
          inner = wrap_in_modules(prefix.drop(1), leaf_header, body_lines, new_accumulated, kinds, depth + 1)
          "#{indent}#{keyword} #{seg}\n#{inner}#{indent}end\n"
        end
      end

      def update_existing(source_path, target, candidates)
        source = target.read
        decls = parse_signature(source)
        return WriteResult.new(source_path: source_path, target_path: target, action: :noop) if decls.nil?

        state = MergeState.new(source: source, decls: decls, applied: [], skipped: [])
        candidates.group_by(&:class_name).each { |class_name, methods| merge_class(state, class_name, methods) }

        action = state.applied.empty? ? :noop : :updated
        target.write(state.source) if action == :updated
        WriteResult.new(source_path: source_path, target_path: target,
                        action: action, applied: state.applied, skipped: state.skipped)
      end

      def parse_signature(source)
        _, _, decls = RBS::Parser.parse_signature(source)
        decls
      rescue RBS::ParsingError
        nil
      end

      def merge_class(state, class_name, methods)
        decl = find_class_decl(state.decls, class_name)
        state.source = if decl.nil?
                         append_new_class(state.source, class_name, methods, state.applied)
                       else
                         merge_into_existing_class(state.source, decl, methods, state.applied, state.skipped)
                       end
        state.decls = parse_signature(state.source) || state.decls
      end

      # Walks the parsed decl tree recursively, tracking the
      # enclosing module/class prefix, and returns the
      # declaration whose fully-qualified name matches
      # `qualified_name`. Recursing into modules lets us
      # match `Rigor::Type::Nominal` against the
      # `class Nominal` declaration nested inside
      # `module Rigor; module Type; … end; end`.
      def find_class_decl(decls, qualified_name)
        find_class_decl_in(decls, [], qualified_name)
      end

      def find_class_decl_in(decls, prefix, qualified_name)
        decls.each do |decl|
          next unless decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)

          local = decl.name.to_s.sub(/\A::/, "")
          full = prefix.empty? ? local : "#{prefix.join('::')}::#{local}"
          return decl if full == qualified_name

          nested = find_class_decl_in(decl.members, prefix + [local], qualified_name)
          return nested if nested
        end
        nil
      end

      # Appends an entirely new `class Foo … end` block at the
      # end of the file (with a leading blank line as
      # separator).
      def append_new_class(source, class_name, methods, applied)
        body = methods.map { |c| "#{INDENT}#{c.rbs}" }.join("\n")
        snippet = "\nclass #{class_name}\n#{body}\nend\n"
        applied.concat(methods)
        ends_with_newline?(source) ? source + snippet : "#{source}\n#{snippet}"
      end

      def ends_with_newline?(source)
        source.end_with?("\n")
      end

      def merge_into_existing_class(source, decl, methods, applied, skipped)
        existing_pairs = collect_member_pairs(decl)
        new_methods, conflicting = partition_against_existing(methods, existing_pairs)

        source = insert_into_class(source, decl, new_methods)
        applied.concat(new_methods)

        if @overwrite
          source, replaced = replace_eligible_conflicts(source, decl, conflicting)
          applied.concat(replaced)
          skipped.concat(conflicting.reject { |c| replaced.include?(c) }.map { |c| [c, :user_authored] })
        else
          skipped.concat(conflicting.map { |c| [c, :user_authored] })
        end

        source
      end

      # Returns a list of `[method_name (Symbol), kind (Symbol)]`
      # pairs for every method-like member in the declaration.
      # ADR-14 slice 4 recognises `MethodDefinition`'s
      # `:instance` / `:singleton` kind plus the three
      # `attr_*` declaration kinds so a source-side
      # `attr_reader :name` and an RBS-side `attr_reader name: T`
      # are treated as the same member (i.e. user-authored).
      def collect_member_pairs(decl)
        pairs = []
        decl.members.each { |m| collect_pairs_for_member(m, pairs) }
        pairs
      end

      def collect_pairs_for_member(member, pairs)
        case member
        when RBS::AST::Members::MethodDefinition
          pairs << [member.name, member.kind]
        when RBS::AST::Members::AttrReader
          pairs << [member.name, :instance]
        when RBS::AST::Members::AttrWriter
          pairs << [:"#{member.name}=", :instance]
        when RBS::AST::Members::AttrAccessor
          pairs << [member.name, :instance]
          pairs << [:"#{member.name}=", :instance]
        end
      end

      def partition_against_existing(methods, existing_pairs)
        methods.partition { |c| !existing_pairs.include?([c.method_name, c.kind]) }
      end

      # Inserts each new method line one column before the
      # class declaration's `end` keyword. The insertion text
      # carries its own leading indent + trailing newline so
      # the surrounding source's whitespace stays intact.
      def insert_into_class(source, decl, new_methods)
        return source if new_methods.empty?

        end_pos = decl.location[:end].start_pos
        addition = new_methods.map { |c| "#{INDENT}#{c.rbs}\n" }.join
        source[0...end_pos] + addition + source[end_pos..]
      end

      # Walks the class's existing method declarations; for
      # each replaceable candidate that matches a member
      # name, slices out the old declaration's source range
      # and substitutes the new RBS one-liner. Members that
      # are not `MethodDefinition`s are left alone.
      #
      # Two candidate classifications are eligible for
      # replacement under `--overwrite`:
      #
      # 1. `TIGHTER_RETURN` — the classifier already proved the
      #    new return type is a strict subtype of the declared
      #    one (with lenience guards passed).
      # 2. `NEW_METHOD` whose new RBS strictly tightens an
      #    `untyped` position in the existing declaration. The
      #    canonical case is `initialize_stub_candidate`, which
      #    bypasses the existing-RBS comparison and always
      #    classifies as `NEW_METHOD` — when sig-gen's
      #    `--params=observed` upgrades a `(path: untyped) -> void`
      #    declaration to `(path: String) -> void` we want
      #    `--overwrite` to apply it.
      def replace_eligible_conflicts(source, decl, candidates)
        eligible = candidates.select { |c| eligible_for_replacement?(c, decl, source) }
        return [source, []] if eligible.empty?

        replaced = []
        # Apply replacements from highest byte position downward
        # so earlier byte offsets remain valid as the source
        # grows or shrinks.
        sorted = eligible.sort_by { |c| -member_position(decl, c.method_name, c.kind) }
        sorted.each do |candidate|
          source = apply_replacement(source, decl, candidate) and replaced << candidate
        end
        [source, replaced]
      end

      def eligible_for_replacement?(candidate, decl, source)
        case candidate.classification
        when Classification::TIGHTER_RETURN then true
        when Classification::NEW_METHOD then tightens_untyped?(candidate, decl, source)
        else false
        end
      end

      # Compares the existing member's source-side RBS text
      # against the candidate's proposed RBS text. Returns
      # true when the new spelling has STRICTLY FEWER bare
      # `untyped` tokens than the existing one — i.e. at
      # least one `untyped` slot becomes a concrete type AND
      # no concrete slot becomes `untyped`. Word-boundary
      # matching ensures we count `untyped` only as a type
      # token, not as a substring inside identifiers.
      def tightens_untyped?(candidate, decl, source)
        member = find_method_member(decl, candidate.method_name, candidate.kind)
        return false if member.nil?

        existing_rbs = source[member.location.start_pos...member.location.end_pos]
        count_untyped(candidate.rbs) < count_untyped(existing_rbs)
      end

      def count_untyped(rbs)
        rbs.scan(/\buntyped\b/).size
      end

      def member_position(decl, method_name, kind)
        member = find_method_member(decl, method_name, kind)
        member ? member.location.start_pos : -1
      end

      def find_method_member(decl, method_name, kind)
        decl.members.find do |m|
          m.is_a?(RBS::AST::Members::MethodDefinition) && m.name == method_name && m.kind == kind
        end
      end

      # Splices the new RBS one-liner over the existing
      # declaration's byte range. `RBS::Parser`'s location
      # starts at the `def` keyword, NOT at the column zero of
      # the line, so the leading whitespace stays inside
      # `source[0...start_pos]` and we do not re-emit it.
      def apply_replacement(source, decl, candidate)
        member = find_method_member(decl, candidate.method_name, candidate.kind)
        return nil if member.nil?

        loc = member.location
        source[0...loc.start_pos] + candidate.rbs + source[loc.end_pos..]
      end
    end
  end
end
