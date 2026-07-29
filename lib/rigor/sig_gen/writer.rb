# frozen_string_literal: true

require "fileutils"
require "rbs"

require_relative "classification"
require_relative "write_result"

module Rigor
  module SigGen
    # Applies a per-source-file group of {MethodCandidate}s to the target `.rbs` file under the project
    # signature tree.
    #
    # ADR-14 slice 2: the writer parses the target with `RBS::Parser` to find the matching class declaration and
    # inserts new method declarations just before the class's closing `end` keyword. Existing declarations are
    # NEVER touched unless `--overwrite` is set AND the candidate's classification is `tighter-return`.
    #
    # The slice does NOT re-render the whole file through `RBS::Writer`. That would lose comments / blank-line
    # formatting per upstream design; the byte-range insertion approach taken here preserves untouched
    # declarations verbatim. Mixed hand-written + generated output inside the *same* class declaration may still
    # lose trailing blank lines on the touched ranges; the `--diff` review surface from slice 1 is the user's
    # escape hatch.
    #
    # Safety boundary: the writer ASSERTS the target lives inside the configured signature tree before touching
    # the disk. Files outside that tree route through `WriteResult(action: :skipped_outside_sig_root)`; the
    # caller decides whether to warn or fail.
    class Writer # rubocop:disable Metrics/ClassLength
      INDENT = "  "
      private_constant :INDENT

      # Per-`update_existing` accumulator. The merge_class helper mutates `source` / `decls` / `applied` /
      # `skipped` in place as each class is processed so the next class sees the latest byte positions.
      MergeState = Struct.new(:source, :decls, :applied, :skipped, keyword_init: true)
      private_constant :MergeState

      def initialize(path_mapper:, overwrite: false)
        @path_mapper = path_mapper
        @overwrite = overwrite
        # Run-level (cross-file) namespace-kind view, populated per `#write_all` from every candidate's per-file
        # map. Empty until then so the single-target `#write` path falls back to per-candidate kinds only.
        @global_namespace_kinds = {}
        # Run-level qualified-class-name => superclass-token view, same lifecycle as `@global_namespace_kinds`.
        @global_superclasses = {}
      end

      # Process the full candidate list by resolving each candidate's target sig file via the path mapper (which
      # may route consolidated-layout classes to existing files) and grouping candidates that share a target
      # before writing.
      #
      # ADR-14 follow-up: this is the consolidated-layout entry point. The legacy `write(source_path,
      # candidates)` below assumes all candidates share a target and remains for spec convenience.
      #
      # @param candidates [Array<MethodCandidate>]
      # @return [Array<WriteResult>] one per target sig file.
      def write_all(candidates)
        emittable = candidates.select { |c| EMITTABLE.include?(c.classification) }
        return [] if emittable.empty?

        @global_namespace_kinds = build_namespace_kinds(candidates)
        @global_superclasses = build_superclasses(candidates)
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

      # Shared per-target write path used by both `#write` and `#write_all`. Picks a representative
      # `source_path` for the {WriteResult} when multiple candidates merge into one target.
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
        # The sig root doesn't exist yet; we'll create it alongside the target file. Allow this case.
        target.expand_path.to_s.start_with?(@path_mapper.sig_root_dir.expand_path.to_s)
      end

      def realpath_or_nil(path)
        path.realpath
      rescue Errno::ENOENT
        nil
      end

      def create_new(source_path, target, candidates)
        content = render_new_file(candidates)
        error = RbsValidity.source_error(content)
        if error
          return WriteResult.new(source_path: source_path, target_path: target,
                                 action: :skipped_invalid_rbs, error: error)
        end

        FileUtils.mkdir_p(target.dirname)
        target.write(content)
        WriteResult.new(source_path: source_path, target_path: target,
                        action: :created, applied: candidates)
      end

      # ADR-14 gap-#3 follow-up (c): when one candidate's `class_name` is a strict prefix of another's, emit a
      # single nested tree instead of two flat sibling blocks. The third-round self-dogfood surfaced
      # `Analysis::DependencySourceInference::GemResolver` containing `class Resolved < Data.define(...)` — the
      # earlier `group_by(&:class_name)` flattened that into two top-level wraps (one for GemResolver's own
      # methods, one for GemResolver::Resolved's), which Steep accepted but is not the canonical layout in this
      # project's `sig/`.
      #
      # The writer now builds a tree keyed by qualified-name segments. Each tree node carries (qualified_name,
      # methods, shells, children); rendering walks the tree so every nested class appears inside its parent's
      # block. Empty class shells (gap-#3 follow-up (e), e.g. `Unresolvable = Data.define(...)`) participate as
      # zero-method tree nodes — they emit `class Foo\nend` at their position.
      def render_new_file(candidates)
        shells = collect_class_shells(candidates)
        tree = build_namespace_tree(candidates, shells)
        kinds = merged_namespace_kinds(candidates)
        supers = merged_superclasses(candidates)
        render_tree_nodes(tree, kinds, supers, 0)
      end

      # Drains `class_shells` from every candidate; the generator's walker populates the same set on every
      # candidate produced from a given file (gap-#3 (e)).
      def collect_class_shells(candidates)
        shells = Set.new
        candidates.each { |c| shells.merge(c.class_shells) if c.respond_to?(:class_shells) }
        shells
      end

      def merged_namespace_kinds(candidates)
        merged = @global_namespace_kinds.dup
        candidates.each do |c|
          (c.namespace_kinds || {}).each { |k, v| apply_namespace_kind(merged, k, v) }
        end
        merged
      end

      # Folds every candidate's per-file namespace-kind map into one run-level view so a `class Foo` recorded
      # while scanning `foo.rb` governs the wrapper keyword emitted for `Foo` in a *sibling* file's target — e.g.
      # `foo/bar.rb` declaring `class Foo::Bar`, whose compact constant path never names `Foo`, so the walker
      # records no kind for it. Without this view that sibling target wraps the nested class in `module Foo`
      # while `foo.rbs` declares `class Foo`; loading both raises `RBS::DuplicatedDeclarationError`, aborting the
      # whole RBS env build.
      def build_namespace_kinds(candidates)
        candidates.each_with_object({}) do |candidate, acc|
          (candidate.namespace_kinds || {}).each { |name, kind| apply_namespace_kind(acc, name, kind) }
        end
      end

      # Superclass twins of {#merged_namespace_kinds} / {#build_namespace_kinds}: fold every candidate's
      # per-file `class_superclasses` map into one view keyed by qualified class name. Only plain-constant
      # superclasses are ever recorded (the generator skips computed ones), so a missing key means "emit no
      # superclass", never "unknown".
      def merged_superclasses(candidates)
        merged = @global_superclasses.dup
        candidates.each do |c|
          next unless c.respond_to?(:class_superclasses)

          (c.class_superclasses || {}).each { |name, sup| merged[name] = sup }
        end
        merged
      end

      def build_superclasses(candidates)
        candidates.each_with_object({}) do |candidate, acc|
          next unless candidate.respond_to?(:class_superclasses)

          (candidate.class_superclasses || {}).each { |name, sup| acc[name] = sup }
        end
      end

      # A `class` declaration is authoritative and MUST win over the `:module` wrapper default: a compact
      # `class Foo::Bar` never names `Foo`, so the only signal for `Foo`'s kind is an actual `class Foo` (or
      # `Const = Data.define(...)` shell) seen elsewhere. This guarantees the generated tree never mixes
      # `class` / `module` for the same constant.
      def apply_namespace_kind(map, key, kind)
        if kind == :class
          map[key] = :class
        else
          map[key] ||= :module
        end
      end

      # Tree node: { name:, children: Hash{String => node}, methods: Array<MethodCandidate>, shell: Boolean }.
      # `shell` flags nodes that came in via `class_shells` only (no methods of their own); rendering uses it to
      # default the keyword to `:class` for the `class Const` = `Data.define(...)` case.
      def build_namespace_tree(candidates, shells)
        root = { name: nil, children: {}, methods: [], shell: false }
        candidates.group_by(&:class_name).each do |class_name, methods|
          insert_into_tree(root, class_name.split("::"), methods: methods)
        end
        shells.each { |name| insert_into_tree(root, name.split("::"), shell: true) }
        root
      end

      def insert_into_tree(node, segments, methods: nil, shell: false)
        return if segments.empty?

        head, *rest = segments
        child = node[:children][head] ||= { name: head, children: {}, methods: [], shell: false }
        if rest.empty?
          child[:methods].concat(methods) if methods
          child[:shell] ||= shell
        else
          insert_into_tree(child, rest, methods: methods, shell: shell)
        end
      end

      def render_tree_nodes(node, kinds, supers, depth)
        node[:children].values.map do |child|
          render_tree_node(child, kinds, supers, depth, [node[:name]].compact)
        end.join("\n")
      end

      def render_tree_node(node, kinds, supers, depth, prefix)
        indent = INDENT * depth
        qualified = (prefix + [node[:name]]).join("::")
        keyword = node_keyword(node, kinds, qualified)
        header = "#{keyword} #{node[:name]}#{superclass_suffix(keyword, supers, qualified)}"
        body = render_tree_node_body(node, kinds, supers, depth, prefix)
        "#{indent}#{header}\n#{body}#{indent}end\n"
      end

      def render_tree_node_body(node, kinds, supers, depth, prefix)
        inner_indent = INDENT * (depth + 1)
        method_lines = node[:methods].map { |c| "#{inner_indent}#{c.rbs}\n" }.join
        child_blocks = node[:children].values.map do |child|
          render_tree_node(child, kinds, supers, depth + 1, prefix + [node[:name]])
        end.join
        method_lines + child_blocks
      end

      # ` < Super` for a `class` node whose qualified name has a recorded superclass, else the empty string. A
      # `module` never takes a superclass (RBS forbids it), so the keyword gates emission — a name coincidentally
      # recorded as both (impossible from one source class, but cheap to guard) stays a bare module.
      def superclass_suffix(keyword, supers, qualified)
        return "" unless keyword == :class

        superclass = supers[qualified]
        superclass ? " < #{superclass}" : ""
      end

      # Per ADR-14 gap-#3 (a) the keyword for a segment comes from `namespace_kinds` when known. The default for
      # an explicit class shell (gap-#3 (e), `Const = Data.define(...)`) is `:class`; otherwise default to
      # `:class` for a method-bearing leaf node and `:module` for an intermediate (children-only) segment.
      # Defaulting intermediates to `:module` matches RBS's "multiple `module Foo` declarations merge" rule.
      def node_keyword(node, kinds, qualified)
        return kinds.fetch(qualified) if kinds.key?(qualified)
        return :class if node[:shell]
        return :class if node[:methods].any? && node[:children].empty?

        :module
      end

      def update_existing(source_path, target, candidates)
        source = target.read
        # Pre-parser encoding guard, mirroring `Environment::RbsLoader.invalid_encoding?`: handed invalid
        # UTF-8, `RBS::Parser` raises a bare `ArgumentError` on rbs 4.1 (not the `ParsingError` that
        # `parse_signature` below rescues) and could hang outright on the older releases the gemspec
        # supports. The refusal is loud — unlike an unparseable file (`:noop`, surfaced by `rigor check`'s
        # own quarantine warning), a mojibake file would otherwise fail with a stack trace naming neither
        # the file nor the fix.
        unless source.valid_encoding?
          return WriteResult.new(source_path: source_path, target_path: target,
                                 action: :skipped_invalid_encoding,
                                 error: "#{target} is not valid UTF-8")
        end

        decls = parse_signature(source)
        return WriteResult.new(source_path: source_path, target_path: target, action: :noop) if decls.nil?

        state = MergeState.new(source: source, decls: decls, applied: [], skipped: [])
        merge_candidates(state, candidates)

        action = state.applied.empty? ? :noop : :updated
        unless action == :updated
          return WriteResult.new(source_path: source_path, target_path: target, action: action,
                                 applied: state.applied, skipped: state.skipped)
        end

        # The merge splices text into an existing file by byte offset, so a bug here can produce a file neither
        # the generator nor the target was responsible for. Parse the assembled result and refuse to write it if
        # it is broken: a `.rbs` the consumer cannot parse is quarantined whole, so a bad splice would delete
        # every type in the file — including the user's own, which were fine before we touched them.
        error = RbsValidity.source_error(state.source)
        if error
          return WriteResult.new(source_path: source_path, target_path: target,
                                 action: :skipped_invalid_rbs, error: error)
        end

        target.write(state.source)
        WriteResult.new(source_path: source_path, target_path: target,
                        action: action, applied: state.applied, skipped: state.skipped)
      end

      # Applies every class group, then every requested shell, then normalises the layout the three steps
      # leave behind. Each step mutates `state` in place and re-parses, so the next one sees current offsets.
      def merge_candidates(state, candidates)
        supers = merged_superclasses(candidates)
        kinds = merged_namespace_kinds(candidates)
        shells = collect_class_shells(candidates)
        groups = candidates.group_by(&:class_name)
        # Ancestors first, so `Foo` is created (or found) before `Foo::Bar` looks for a parent to nest under.
        # A plain sort suffices: a name always sorts before every name it is a strict prefix of.
        groups.keys.sort.each { |name| merge_class(state, name, groups.fetch(name), kinds, supers) }
        merge_class_shells(state, shells, kinds, supers)
        collapse_nested_declarations(state, groups.keys + shells.to_a)
      end

      # ADR-14 gap-#3 (e): for every requested class shell that isn't already declared in the target file,
      # insert an empty `class Const\nend` block inside the nearest existing ancestor. Shells already covered by
      # an existing declaration are silently a no-op. The `applied` accumulator does NOT grow — shells are
      # structural declarations, not methods, so the action-count surface (`updated +N`) keeps reflecting method
      # changes only.
      def merge_class_shells(state, shells, kinds, supers)
        shells.each do |qualified|
          next if find_class_decl(state.decls, qualified)

          insert_namespace_chain(state, qualified, kinds, supers, [])
        end
      end

      # Splices the missing part of `qualified`'s namespace chain into the nearest declaration the file
      # already has for one of its ancestors, or at top level when it has none. `methods` land on the leaf
      # node, so this is the single insertion path for both an empty class shell and a brand-new class.
      def insert_namespace_chain(state, qualified, kinds, supers, methods)
        segments = qualified.split("::")
        anchor_segs, missing = split_at_existing_ancestor(state.decls, segments)
        anchor_decl = anchor_segs.empty? ? nil : find_class_decl(state.decls, anchor_segs.join("::"))
        depth = anchor_decl ? member_indent_depth(anchor_decl) : 0
        snippet = render_chain_snippet(missing, anchor_segs, kinds, supers, depth, methods)
        state.source = if anchor_decl
                         insert_before_end(state.source, anchor_decl, snippet)
                       else
                         append_top_level(state.source, snippet)
                       end
        state.decls = parse_signature(state.source) || state.decls
      end

      # ADR-14 gap-#3 follow-up (c), update half: the create path folds a strict-prefix pair into one nested
      # tree, but a file written before that fix — or by hand — can still carry the flat sibling layout
      # (`class Foo` next to a top-level `class Foo::Bar`). After merging, relocate each declaration this run
      # touched underneath its parent's declaration when the same file holds both, so an update converges on
      # the same canonical layout a fresh generation would produce.
      #
      # Scope is deliberately the touched names only: an unrelated flat pair elsewhere in the file is none of
      # sig-gen's business, and rewriting it would be a layout change the user never asked for. Shallowest
      # first, so `Foo::Bar` has already moved under `Foo` by the time `Foo::Bar::Baz` looks for its parent.
      def collapse_nested_declarations(state, names)
        names.uniq.sort.each { |name| relocate_under_parent(state, name) }
      end

      def relocate_under_parent(state, qualified)
        segments = qualified.split("::")
        return if segments.size < 2

        parent_name = segments[0...-1].join("::")
        parent = find_class_decl(state.decls, parent_name)
        decl = parent && find_class_decl(state.decls, qualified)
        return if decl.nil? || overlapping?(parent, decl)

        region = decl_region(state.source, decl)
        block = region && relocated_block(state.source, decl, parent, segments.last, region)
        return if block.nil?

        apply_relocation(state, region, parent_name, block)
      end

      # Cuts the declaration's region out, re-parses so the parent's byte range reflects the removal, and
      # splices the re-indented block back in as the parent's last member. Any step that cannot be carried
      # out cleanly (an unparseable intermediate, a parent that vanished) abandons the move and leaves the
      # merged source exactly as it was — a flat layout is cosmetic, a mangled `.rbs` is not.
      def apply_relocation(state, region, parent_name, block)
        source = splice_out(state.source, region)
        decls = parse_signature(source)
        anchor = decls && find_class_decl(decls, parent_name)
        return if anchor.nil?

        state.source = insert_before_end(source, anchor, block)
        state.decls = parse_signature(state.source) || state.decls
      end

      # True when the two declarations' source ranges are not disjoint — either one already nests the other,
      # or the file's shape is one this pass does not understand. Both are reasons not to move anything.
      def overlapping?(one, other)
        one.location.start_pos < other.location.end_pos && other.location.start_pos < one.location.end_pos
      end

      # The declaration's full source region, extended to cover its leading comment and annotations and to
      # end just past the newline that closes it. Returns `nil` when either edge shares a line with something
      # else, because cutting there would move — or strand — text the declaration does not own.
      def decl_region(source, decl)
        start_pos = ([decl.location.start_pos] + leading_positions(decl)).min
        line_start = line_start_index(source, start_pos)
        return nil unless blank_range?(source, line_start, start_pos)

        finish = decl.location.end_pos
        line_end = source.index("\n", finish) || source.size
        return nil unless blank_range?(source, finish, line_end)

        line_start...(line_end < source.size ? line_end + 1 : line_end)
      end

      def leading_positions(decl)
        positions = decl.annotations.filter_map { |a| a.location&.start_pos }
        comment_location = decl.comment&.location
        positions << comment_location.start_pos if comment_location
        positions
      end

      # The moved text, with its compact `Foo::Bar` head shortened to `Bar` and every line pushed in to the
      # parent's member depth. The name's own sub-location drives the rewrite, so a superclass, type
      # parameters, and the whole body survive byte-for-byte.
      def relocated_block(source, decl, parent, short_name, region)
        name_location = decl.location[:name]
        return nil if name_location.nil?

        text = source[region].to_s
        head = name_location.start_pos - region.begin
        tail = name_location.end_pos - region.begin
        renamed = text[0...head].to_s + short_name + text[tail..].to_s
        reindent(renamed, member_indent_depth(parent) - decl_indent_depth(decl))
      end

      def reindent(text, delta)
        return text unless delta.positive?

        prefix = INDENT * delta
        text.lines.map { |line| line.match?(/\A\s*\z/) ? line : prefix + line }.join
      end

      # Removes `region`, collapsing the newline run left behind at the seam so the cut never shows up as a
      # widening gap (or a trailing blank line at EOF) in the file it edited. Spacing that was already fine
      # is left exactly as the user wrote it.
      def splice_out(source, region)
        before = source[0...region.begin].to_s
        after = source[region.end..].to_s
        return after.sub(/\A\n+/, "") if before.match?(/\A\s*\z/)
        return before.sub(/\n{2,}\z/, "\n") if after.match?(/\A\s*\z/)

        seam = before[/\n+\z/].to_s.size + after[/\A\n+/].to_s.size
        return before + after if seam <= 2

        "#{before.sub(/\n+\z/, "\n\n")}#{after.sub(/\A\n+/, '')}"
      end

      def split_at_existing_ancestor(decls, segments)
        (segments.size - 1).downto(0).each do |i|
          ancestor = segments[0...i].join("::")
          return [segments[0...i], segments[i..]] if i.zero? || find_class_decl(decls, ancestor)
        end
        [[], segments]
      end

      # The indent depth (in `INDENT` units) a member of `decl` sits at: one level deeper than the
      # declaration's own keyword column. Pre-existing members might be missing (an empty `class Foo; end`)
      # so the keyword column is the robust signal.
      def member_indent_depth(decl)
        decl_indent_depth(decl) + 1
      end

      def decl_indent_depth(decl)
        decl.location[:keyword].start_column / INDENT.size
      end

      # Renders the `missing` segment chain as one nested block, carrying `methods` on its leaf, by handing a
      # synthesised tree node to the create path's renderer. Both paths therefore agree on the keyword, the
      # superclass suffix, and the indentation of every level. A leaf with no methods is a class shell, which
      # is exactly the create path's `shell:` node (gap-#3 (e)).
      def render_chain_snippet(missing, anchor_segs, kinds, supers, depth, methods)
        return "" if missing.empty?

        node = missing.reverse.each_with_index.inject(nil) do |child, (segment, index)|
          { name: segment, children: child ? { child[:name] => child } : {},
            methods: index.zero? ? methods : [], shell: index.zero? && methods.empty? }
        end
        render_tree_node(node, kinds, supers, depth, anchor_segs)
      end

      # Splices `snippet` in just before the declaration's closing `end`. When that `end` starts its own line
      # the insertion point moves to the START of that line: the snippet carries its own indentation, and
      # anchoring at the keyword would otherwise donate the `end`'s indent to the snippet's first line and
      # strand the `end` in column zero.
      def insert_before_end(source, decl, snippet)
        return source if snippet.empty?

        end_pos = decl.location[:end].start_pos
        line_start = line_start_index(source, end_pos)
        return source[0...line_start] + snippet + source[line_start..] if blank_range?(source, line_start, end_pos)

        "#{source[0...end_pos]}\n#{snippet}#{source[end_pos..]}"
      end

      # Appends a top-level block, separated from whatever precedes it by exactly one blank line.
      def append_top_level(source, snippet)
        return snippet if source.empty?

        base = ends_with_newline?(source) ? source : "#{source}\n"
        base.end_with?("\n\n") ? base + snippet : "#{base}\n#{snippet}"
      end

      def line_start_index(source, pos)
        return 0 unless pos.positive?

        (source.rindex("\n", pos - 1) || -1) + 1
      end

      def blank_range?(source, from, to)
        source[from...to].to_s.match?(/\A[ \t]*\z/)
      end

      def parse_signature(source)
        _, _, decls = RBS::Parser.parse_signature(source)
        decls
      rescue RBS::ParsingError
        nil
      end

      def merge_class(state, class_name, methods, kinds, supers)
        decl = find_class_decl(state.decls, class_name)
        if decl.nil?
          state.applied.concat(methods)
          insert_namespace_chain(state, class_name, kinds, supers, methods)
        else
          state.source = merge_into_existing_class(state.source, decl, methods, state.applied, state.skipped)
          state.decls = parse_signature(state.source) || state.decls
        end
      end

      # Walks the parsed decl tree recursively, tracking the enclosing module/class prefix, and returns the
      # declaration whose fully-qualified name matches `qualified_name`. Recursing into modules lets us match
      # `Rigor::Type::Nominal` against the `class Nominal` declaration nested inside
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

      # Returns a list of `[method_name (Symbol), kind (Symbol)]` pairs for every method-like member in the
      # declaration. ADR-14 slice 4 recognises `MethodDefinition`'s `:instance` / `:singleton` kind plus the
      # three `attr_*` declaration kinds so a source-side `attr_reader :name` and an RBS-side
      # `attr_reader name: T` are treated as the same member (i.e. user-authored).
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

      # Inserts each new method line one column before the class declaration's `end` keyword. The insertion
      # text carries its own leading indent + trailing newline so the surrounding source's whitespace stays
      # intact.
      def insert_into_class(source, decl, new_methods)
        return source if new_methods.empty?

        indent = INDENT * member_indent_depth(decl)
        insert_before_end(source, decl, new_methods.map { |c| "#{indent}#{c.rbs}\n" }.join)
      end

      # Walks the class's existing method declarations; for each replaceable candidate that matches a member
      # name, slices out the old declaration's source range and substitutes the new RBS one-liner. Members that
      # are not `MethodDefinition`s are left alone.
      #
      # Two candidate classifications are eligible for replacement under `--overwrite`:
      #
      # 1. `TIGHTER_RETURN` — the classifier already proved the new return type is a strict subtype of the
      #    declared one (with lenience guards passed).
      # 2. `NEW_METHOD` whose new RBS strictly tightens an `untyped` position in the existing declaration. The
      #    canonical case is `initialize_stub_candidate`, which bypasses the existing-RBS comparison and always
      #    classifies as `NEW_METHOD` — when sig-gen's `--params=observed` upgrades a `(path: untyped) -> void`
      #    declaration to `(path: String) -> void` we want `--overwrite` to apply it.
      def replace_eligible_conflicts(source, decl, candidates)
        eligible = candidates.select { |c| eligible_for_replacement?(c, decl, source) }
        return [source, []] if eligible.empty?

        replaced = []
        # Apply replacements from highest byte position downward so earlier byte offsets remain valid as the
        # source grows or shrinks.
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

      # Compares the existing member's source-side RBS text against the candidate's proposed RBS text. Returns
      # true when the new spelling has STRICTLY FEWER bare `untyped` tokens than the existing one — i.e. at
      # least one `untyped` slot becomes a concrete type AND no concrete slot becomes `untyped`. Word-boundary
      # matching ensures we count `untyped` only as a type token, not as a substring inside identifiers.
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

      # Splices the new RBS one-liner over the existing declaration's byte range. `RBS::Parser`'s location
      # starts at the `def` keyword, NOT at the column zero of the line, so the leading whitespace stays inside
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
