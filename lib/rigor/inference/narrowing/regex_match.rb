# frozen_string_literal: true

require "prism"
require_relative "../../reflection"
require_relative "../../source/constant_path"
require_relative "../../type"
require_relative "../../builtins/regex_refinement"
require_relative "../project_method_ownership"

module Rigor
  module Inference
    module Narrowing
      # ADR-116 C1 — the regex match predicates and the capture-group analysis: `=~`, `!~`, `match`, `match?`
      # and the whole-receiver refinement a match proves ({.analyse_regex_match_predicate},
      # {.analyse_regex_not_match_predicate}, {.analyse_whole_regex_match_predicate}), the scopes a successful match
      # binds ({.regex_match_predicate_scopes}), the receiver's kind ({.match_member_kinds}) and the groups a pattern
      # captures unconditionally ({.unconditional_capture_groups}).
      #
      # Calls back into `Narrowing` for `narrow_nil` and `narrow_not_class` only, which `match_member_kind` asks to
      # classify a receiver member as `nil`, a `String` or a `Symbol`; nothing else in `Narrowing` is reached from
      # here. `Narrowing`'s `case`/`when` entries and `string_match_receiver?` call {.regex_match_predicate_scopes},
      # {.unconditional_capture_groups} and {.match_member_kinds}.
      # rubocop:disable-next Metrics/ModuleLength
      module RegexMatch
        module_function

        # A recognised `=~` regex pattern operand: the pattern `source` string and whether it was
        # compiled in extended (`//x`) mode. Extraction from a literal `RegularExpressionNode` and from
        # a value-pinned `Constant[Regexp]` share this carrier so the participation walk and the
        # extended-mode bail read one shape.
        RegexMatchPattern = Data.define(:source, :extended)
        private_constant :RegexMatchPattern

        # Survey item (b): `/regex/ =~ str` and `str =~ /regex/` bind the regex match-data
        # globals on each edge ({#regex_match_edges}), gated on the subject (#1494): an edge is
        # narrowed only when the receiver proves what the frame holds on it
        # ({#match_receiver_edges}), and an edge it cannot vouch for keeps the match globals
        # forgotten. A `String?` subject keeps the match edge only, since `NilClass#=~` answers
        # nil with the previous match still bound; an untyped one is read the same way.
        #
        # Returns nil (no narrowing) when the receiver / argument pair does not resolve to exactly one
        # regex pattern we can count (see {#regex_match_pattern}).
        def analyse_regex_match_predicate(node, scope)
          gated_regex_match_edges(node, scope)
        end

        # Issue #1379 — `subject !~ pattern` is `Kernel#!~`, which returns `!(subject =~ pattern)`. It runs the same
        # match in the caller's frame, so its edges are {#analyse_regex_match_predicate}'s swapped: the falsey edge is
        # the match edge (`$~` a `MatchData`, an unconditional `$N` a `String`, and the whole-receiver refinement), the
        # truthy edge the no-match edge (`$~` and `$N` nil). The same patterns are recognised and the same ones
        # declined (a non-regex operand, an ambiguous constant, `//x`), and the receiver gates the edges alike.
        def analyse_regex_not_match_predicate(node, scope)
          gated_regex_match_edges(node, scope)&.reverse
        end

        # `[match_edge, no_match_edge]` of a `=~` / `!~` predicate, each kept only where
        # {#match_receiver_edges} lets it be; an edge it cannot vouch for is the entry scope with the
        # match globals forgotten, since the call may still have rebound them. The whole-receiver
        # refinement is kept only when the local it would narrow is known to be a String on the
        # match edge ({#refinable_operand?}).
        def gated_regex_match_edges(node, scope)
          edges = regex_match_edges(node, scope, refine: refinable_operand?(node, scope))
          return nil if edges.nil?

          match, no_match = edges
          forgotten = scope.forget_match_globals
          case match_receiver_edges(node, scope)
          when :both then [match, no_match]
          when :match then [match, forgotten]
          else [forgotten, forgotten]
          end
        end

        # The ungated edges of a match:
        #
        # - Match edge (`=~` returned an Integer position — the match succeeded): `$~` to
        #   `Nominal[MatchData]`; `$&` and `$1..$N` (where N is the number of capture groups in
        #   the regex source) to `Nominal[String]`. This is the same optimistic-narrowing shape
        #   the existing `analyse_match_write` uses for named captures inside `if /(?<x>...)/
        #   =~ str` — optional groups in the regex source (`(\d+)?`) would bind `$N` to `nil`
        #   at runtime, but the floor here matches the common idiom (required captures) and
        #   lets `unless /(\d+)/ =~ s; raise; end; $1.to_i` resolve cleanly.
        # - No-match edge (`=~` returned nil): `$~` and every numbered / back-reference
        #   global bound to `Constant<nil>`.
        #
        # `refine: false` leaves out the whole-receiver refinement, which names a String.
        def regex_match_edges(node, scope, refine:)
          return nil if node.arguments.nil?
          return nil unless node.arguments.arguments.size == 1

          arg = node.arguments.arguments.first
          pattern = regex_match_pattern(node.receiver, arg, scope)
          return nil if pattern.nil?
          # Extended mode (`//x`) lets the pattern carry free whitespace and `#` comments, and a
          # comment may contain a literal `(` — which the light char-scan walker would miscount as a
          # capturing group, shifting `$N` indices and narrowing the wrong global. That is a
          # false-negative-class misnarrowing, so bail rather than risk it. The literal path shares
          # this bail: `RegularExpressionNode` carries the same latent miscount.
          return nil if pattern.extended

          unconditional = unconditional_capture_groups(pattern.source)
          truthy, falsey = regex_match_predicate_scopes(scope, unconditional)
          # #164 — layer whole-receiver refinement onto the truthy edge without disturbing the
          # match-global logic above. A successful `str =~ /\A\d+\z/` proves the WHOLE string
          # matched, so the string operand narrows to the imported refinement the anchored pattern
          # names. The falsey edge is untouched: a failed match proves nothing about the shape.
          truthy = apply_whole_receiver_refinement(truthy, node.receiver, arg, pattern.source, scope) if refine
          [truthy, falsey]
        end

        # Which edges of `recv =~ pattern` / `recv !~ pattern` the receiver lets {#gated_regex_match_edges} narrow:
        # `:both`, `:match` (the match edge only) or nil. `Kernel#!~` dispatches `=~` on the receiver:
        #
        # - A Regexp receiver (the pattern on the left) runs `Regexp#=~`, which sets `$~` on both outcomes, a `nil`
        #   argument included: `:both`.
        # - `String#=~` and `Symbol#=~` do the same: `:both` when every member of the receiver's type is a String
        #   (a project subclass of String included) or a Symbol.
        # - `NilClass#=~` answers nil and leaves `$~` alone, so a nil receiver reaches the no-match edge with the
        #   previous match still bound; it never reaches the match edge. A `Dynamic` receiver may be nil at run time
        #   whatever its static facet says. So does a safe-navigation call, which answers nil without matching on a
        #   nil receiver.
        #
        # The two operators part over a receiver that is none of those ({#match_operator_edges},
        # {#not_match_operator_edges}).
        def match_receiver_edges(node, scope)
          return nil if node.receiver.nil?

          edges =
            if regex_operand_pattern(node.receiver, scope).is_a?(RegexMatchPattern)
              :both
            else
              kinds = match_member_kinds(scope.type_of(node.receiver), scope)
              node.name == :=~ ? match_operator_edges(kinds) : not_match_operator_edges(kinds)
            end
          return edges unless node.safe_navigation?

          :match if edges && node.name == :=~
        end

        STRING_MATCH_KINDS = %i[string string_subclass symbol].freeze
        private_constant :STRING_MATCH_KINDS

        # `recv =~ pattern`'s match edge is the truthy one. Only a member known to define its own `=~` in the
        # project keeps it out (#1494): that method binds `$~` in its own frame, not the caller's. Any other member
        # either matches in the caller's frame, answers nil (`NilClass`), or has no `=~` at all (`Integer` since
        # Ruby 3.2 drops `Object#=~`) and so never reaches the edge; a receiver the analyzer cannot classify keeps the
        # edge, as every `=~` did before #1494.
        def match_operator_edges(kinds)
          return nil if kinds.include?(:custom)
          return :both if kinds.all? { |kind| STRING_MATCH_KINDS.include?(kind) }

          :match
        end

        # `recv !~ pattern`'s match edge is the falsey one, which a receiver whose `=~` is not the caller's match
        # also reaches, so it is kept only when every member is a String, a Symbol, nil, or a `Dynamic` that is
        # untyped or whose facet holds only those (#1379).
        def not_match_operator_edges(kinds)
          return :both if kinds.all? { |kind| STRING_MATCH_KINDS.include?(kind) }

          :match if kinds.all? { |kind| (STRING_MATCH_KINDS + %i[nil dynamic]).include?(kind) }
        end

        # Whether the local operand {#apply_whole_receiver_refinement} would narrow holds only Strings and nil, which
        # the match edge excludes. The refinement names a String, so a member that may be a Symbol — a Symbol, or an
        # untyped `Dynamic` that may be one at run time — keeps it out: `return unless raw =~ /\A\d+\z/` on an untyped
        # `raw` must not make `raw.to_proc` an undefined method (#1379, #1494).
        def refinable_operand?(node, scope)
          operand = [node.receiver, *node.arguments&.arguments].find { |o| o.is_a?(Prism::LocalVariableReadNode) }
          type = operand && scope.local(operand.name)
          return true if type.nil?

          match_member_kinds(type, scope).all? { |kind| %i[string nil].include?(kind) }
        end

        def match_member_kinds(type, scope)
          (type.is_a?(Type::Union) ? type.members : [type]).map { |member| match_member_kind(member, scope) }
        end

        # `:custom` for a member whose class the project gives a `=~` of its own (in its ancestry, a reopened
        # `String` included); `:string` or `:symbol` for a member {.narrow_not_class} proves a String or a Symbol (a
        # value or refinement of either, or a class the environment orders below it); `:string_subclass` for a
        # project class whose superclass chain reaches `String`, which the environment cannot order; `:nil`;
        # `:dynamic` for a `Dynamic` whose facet is untyped or holds only Strings, Symbols and nil; or nil for anything
        # else.
        def match_member_kind(member, scope)
          return match_dynamic_kind(member, scope) if member.is_a?(Type::Dynamic)
          return :nil if Narrowing.narrow_nil(member) == member && !member.is_a?(Type::Bot)
          return :custom if custom_match_operator?(member, scope)

          environment = scope.environment
          { "String" => :string, "Symbol" => :symbol }.each do |class_name, kind|
            if Narrowing.narrow_not_class(member, class_name, environment: environment, scope: scope).is_a?(Type::Bot)
              return kind
            end
          end
          :string_subclass if project_string_subclass?(member, scope)
        end

        def match_dynamic_kind(member, scope)
          facet = member.static_facet
          return :dynamic if Type::Combinator.untyped?(member)

          facet_kinds = match_member_kinds(facet, scope)
          :dynamic if facet_kinds.all? { |kind| (STRING_MATCH_KINDS + [:nil]).include?(kind) }
        end

        def custom_match_operator?(member, scope)
          targets = ProjectMethodOwnership.targets(member)
          return false if targets.nil?

          targets.any? { |class_name, kind| ProjectMethodOwnership.defines?(class_name, :=~, kind, scope) }
        end

        def project_string_subclass?(member, scope)
          return false unless member.is_a?(Type::Nominal) && scope.known_user_class?(member.class_name)

          scope.external_ancestor_name_candidates(member.class_name, mixins: false)
               .flatten.any? { |name| name.to_s.delete_prefix("::") == "String" }
        end

        # `str.match?(/\A\d+\z/)` — `String#match?` is a pure boolean predicate whose truthy edge
        # proves a property of the ENTIRE receiver. When the argument is a fully `\A…\z`-anchored
        # single-char-class pattern recognised by {RegexRefinement.for_whole_pattern}, narrow the
        # receiver local to the matching imported refinement on the truthy edge; the falsey edge
        # passes through unchanged (failing one pattern proves nothing about the string's shape).
        # A non-literal / unanchored / `\Z` / line-anchored / `//x` pattern falls through to no
        # narrowing.
        #
        # The refinement names a String, so it shares `=~`'s gate (#1955): a receiver that may be a Symbol, or an
        # untyped one, is left as it is ({#refinable_operand?}).
        def analyse_whole_regex_match_predicate(node, scope)
          return nil unless node.receiver.is_a?(Prism::LocalVariableReadNode)
          return nil if node.arguments.nil? || node.arguments.arguments.size != 1
          return nil unless refinable_operand?(node, scope)

          pattern = regex_operand_pattern(node.arguments.arguments.first, scope)
          return nil unless pattern.is_a?(RegexMatchPattern)
          return nil if pattern.extended

          refinement = ::Rigor::Builtins::RegexRefinement.for_whole_pattern(pattern.source)
          return nil if refinement.nil?

          local_name = node.receiver.name
          return nil if scope.local(local_name).nil?

          [scope.with_local(local_name, refinement), scope]
        end

        # Narrows the string operand of a `=~` predicate to a whole-receiver refinement when the
        # regex source is a recognised `\A…\z`-anchored pattern. Returns the (possibly unchanged)
        # truthy scope; the falsey edge is never touched by this layer.
        def apply_whole_receiver_refinement(truthy, receiver, arg, source, scope)
          refinement = ::Rigor::Builtins::RegexRefinement.for_whole_pattern(source)
          return truthy if refinement.nil?

          # `regex_match_pattern` already resolved the regex operand from a literal or a
          # `Constant[Regexp]` constant read — never a bare local — so the string subject is
          # unambiguously the local-read operand, if either operand is one.
          subject = [receiver, arg].find { |operand| operand.is_a?(Prism::LocalVariableReadNode) }
          return truthy if subject.nil? || scope.local(subject.name).nil?

          truthy.with_local(subject.name, refinement)
        end

        # Recognises the regex pattern operand of a `=~` predicate. An operand resolves to a regex when
        # it is either a syntactic `RegularExpressionNode` literal OR a constant read whose type is a
        # value-pinned `Constant[Regexp]` (`RE = /.../` and `RE = Regexp.new(...)` both fold to the
        # carrier in the whole-program constant pre-pass). Returns a single {RegexMatchPattern}, or nil
        # (no narrowing) when NEITHER operand resolves to a regex, when BOTH do (`/a/ =~ /b/` — no
        # string subject to bind), or when a constant operand is ambiguous — typed as a `Union` from a
        # twice-assigned constant, where no single source can be pinned.
        def regex_match_pattern(left, right, scope)
          left_pattern = regex_operand_pattern(left, scope)
          right_pattern = regex_operand_pattern(right, scope)
          return nil if left_pattern == :ambiguous || right_pattern == :ambiguous

          patterns = [left_pattern, right_pattern].grep(RegexMatchPattern)
          patterns.size == 1 ? patterns.first : nil
        end

        # Classifies one `=~` operand: a {RegexMatchPattern} when it resolves to a regex (literal or
        # `Constant[Regexp]`), `:ambiguous` when a constant operand types as a `Union` (a twice-assigned
        # constant), or nil when the operand is not a regex at all.
        def regex_operand_pattern(node, scope)
          case node
          when Prism::RegularExpressionNode
            RegexMatchPattern.new(source: node.unescaped, extended: node.extended?)
          when Prism::ConstantReadNode, Prism::ConstantPathNode
            regex_operand_from_constant(node, scope)
          end
        end

        # Resolves a constant-reference operand to a regex pattern via the shared lexical-constant
        # resolution (`Reflection.resolve_constant_type`). `Regexp#options` gives the real
        # extended-mode flag; `Regexp#source` the pattern. Returns `:ambiguous` for a `Union`-typed
        # constant so the caller bails, and nil when the constant does not resolve to a `Constant[Regexp]`.
        def regex_operand_from_constant(node, scope)
          name = Source::ConstantPath.qualified_name_or_nil(node)
          return nil if name.nil?

          type = Reflection.resolve_constant_type(name, scope: scope,
                                                        rooted: Source::ConstantPath.rooted?(node))
          return :ambiguous if type.is_a?(Type::Union)
          return nil unless type.is_a?(Type::Constant)

          value = type.value
          return nil unless value.is_a?(Regexp)

          RegexMatchPattern.new(source: value.source, extended: value.options.anybits?(Regexp::EXTENDED))
        end

        # Curated set of match globals bound non-nil on every successful `=~` regardless of grouping:
        # `$~` (the MatchData), `$&` (whole match), `` $` `` (pre-match), `$'` (post-match). Numbered
        # references (`$1..$N`) and `$+` (the last matched group) are handled separately because they
        # depend on the regex source — `$+` is gated on the same participation set as `$N` (#177).
        REGEX_MATCH_GLOBALS = %i[$~ $& $` $'].freeze
        private_constant :REGEX_MATCH_GLOBALS

        # `unconditional` is the Set of 1-based numbered-capture indices whose group is
        # guaranteed to participate in any successful match (no optional quantifier on the
        # group or an ancestor, no alternation in the pattern). Those `$N` are bound to
        # `String`; every other numbered group present in the pattern stays `String | nil` on
        # both edges (a truthy match leaves an optional group nil at runtime), so we do not
        # narrow it on the truthy edge.
        #
        # Both edges start from `scope` with the match globals forgotten (#1385): the match rebinds every one of them,
        # so a `$N` an earlier match narrowed says nothing here. Without that, a `when /(x)/` arm, or the right operand
        # of `s =~ /(a)(b)(c)/ && t =~ /(x)/`, kept `$2` and `$3` narrowed to `String` where Ruby reads nil.
        def regex_match_predicate_scopes(scope, unconditional)
          string_t = Type::Combinator.nominal_of("String")
          match_data_t = Type::Combinator.nominal_of("MatchData")
          nil_t = Type::Combinator.constant_of(nil)

          truthy = scope.forget_match_globals
          falsey = truthy
          truthy = truthy.with_global(:$~, match_data_t)
          falsey = falsey.with_global(:$~, nil_t)
          REGEX_MATCH_GLOBALS.each do |name|
            next if name == :$~

            truthy = truthy.with_global(name, string_t)
            falsey = falsey.with_global(name, nil_t)
          end
          unconditional.each do |index|
            name = :"$#{index}"
            truthy = truthy.with_global(name, string_t)
            falsey = falsey.with_global(name, nil_t)
          end
          # `$+` is the LAST matched group, so it is nil on a successful match whose groups are all
          # optional (`"b" =~ /(a)?b/` matches yet leaves `$+` nil) or absent (no capture group). It
          # narrows to `String` only when some group is guaranteed to participate — the same
          # participation gate `$N` uses (#177). With no unconditional group it is left unbound on both
          # edges (fall through to the RBS `String?` default), exactly as an optional `$N` is.
          unless unconditional.empty?
            truthy = truthy.with_global(:$+, string_t)
            falsey = falsey.with_global(:$+, nil_t)
          end
          [truthy, falsey]
        end

        # Returns the Set of 1-based numbered-capture indices that are UNCONDITIONAL in
        # `source`: present on every successful match because no optional quantifier (`?`,
        # `*`, `{0,…}`, `{,…}`) applies to the group or any ancestor group, and the pattern contains no
        # alternation (`|`). Optional and alternation-reachable groups are excluded — at
        # runtime `$N` is `nil` for them even when the overall match succeeds, so narrowing
        # them to non-nil `String` would be unsound. The walker is intentionally light (char
        # scan, not a regex-AST parse): backslash escapes are skipped; `(?:…)`, lookahead
        # `(?=…)`/`(?!…)`, and lookbehind `(?<=…)`/`(?<!…)` do not capture; named groups
        # `(?<name>…)` / `(?'name'…)` do. Once the pattern has a named group, Ruby numbers only
        # the named groups and a plain `(…)` does not capture (#1471): `/(?<x>a)(b)/` has one
        # group, so `$2` is nil. Conservatism is one-directional — when in doubt a group is
        # treated as conditional (dropped from the Set), never the reverse.
        def unconditional_capture_groups(source)
          # `unconditional` collects every capturing index; a group is later removed (with its
          # whole subtree) when it is optionally quantified, nested under an optional ancestor,
          # or sits in an alternation branch. `stack` holds one frame per open group (plus a
          # virtual root frame for the top level) as `[group_index_or_nil, descendant_indices,
          # alternated?]`. A `|` marks the CURRENT group's frame alternated — its branches are
          # mutually exclusive, so its descendant captures may be absent on a successful match;
          # the group itself still participates. Closing a frame rolls its subtree up to the
          # parent so an optional / alternated ancestor disqualifies it.
          state = { unconditional: Set.new, stack: [[nil, [], false]], group_index: 0, named: named_groups?(source) }
          each_structural_char(source) { |pos, chr| scan_group_char(source, pos, chr, state) }
          # Drain the virtual root: a top-level `|` disqualifies all.
          finalize_frame(state, state[:stack].pop, optional: false)
          state[:unconditional]
        end

        # Yields each position of `source` outside a backslash escape and a character class, with its char.
        def each_structural_char(source)
          pos = 0
          length = source.length
          while pos < length
            chr = source[pos]
            if chr == "\\"
              pos += 2
              next
            end
            if chr == "["
              pos = skip_char_class(source, pos) + 1
              next
            end
            yield pos, chr
            pos += 1
          end
        end

        def named_groups?(source)
          each_structural_char(source) { |pos, chr| break true if chr == "(" && named_group?(source, pos) } == true
        end

        # Updates the walk `state` at a group-relevant char during
        # {#unconditional_capture_groups}: `(` pushes a frame, `)` pops and resolves it, `|`
        # flags the current frame as alternated.
        def scan_group_char(source, pos, chr, state)
          case chr
          when "("
            idx = nil
            if capturing_group?(source, pos, named: state[:named])
              idx = (state[:group_index] += 1)
              state[:unconditional] << idx
            end
            state[:stack].push([idx, [], false])
          when ")"
            finalize_frame(state, state[:stack].pop, optional: next_quantifier_optional?(source, pos + 1))
          when "|"
            state[:stack].last[2] = true
          end
        end

        # Resolves a closed (or virtual-root) group frame: its subtree is its own index plus
        # every descendant index. The subtree is disqualified when the group is optionally
        # quantified or its branches are alternated (only the descendants in that case — but a
        # self subtree always keeps its own index unless optional).
        def finalize_frame(state, frame, optional:)
          idx, descendants, alternated = frame
          subtree = descendants.dup
          subtree << idx if idx
          state[:unconditional].subtract(subtree) if optional
          # Alternation disqualifies the branch contents (descendants),
          # never the enclosing group itself.
          state[:unconditional].subtract(descendants) if alternated
          state[:stack].last && state[:stack].last[1].concat(subtree)
        end

        # True when the group whose closing paren is at `source[pos]` is followed by a
        # quantifier that permits zero repetitions (`?`, `*`, `{0…}`, `{,…}`). `+` and `{1,…}`
        # do NOT make a group optional. A lazy/possessive suffix (`*?`, `*+`) is still
        # zero-permitting on the base quantifier. `{,…}` counts only with a digit after the
        # comma — `{,}`, `{,x}` and `{, }` are literal braces, not quantifiers.
        def next_quantifier_optional?(source, pos)
          case source[pos]
          when "?", "*" then true
          when "{" then source[pos + 1] == "0" ||
            (source[pos + 1] == "," && source[pos + 2].to_s.match?(/\d/))
          else false
          end
        end

        # A plain `(…)` captures unless the pattern has a named group (`named:`); of the `(?…)` forms only a named
        # group does.
        def capturing_group?(source, pos, named:)
          return !named unless source[pos + 1] == "?"

          named_group?(source, pos)
        end

        # `(?<name>…)` and `(?'name'…)` are named groups; `(?<=…)`/`(?<!…)` (lookbehind) and
        # `(?:…)`/`(?=…)`/`(?!…)` are not.
        def named_group?(source, pos)
          return false unless source[pos + 1] == "?"
          return true if source[pos + 2] == "'"

          source[pos + 2] == "<" && source[pos + 3] != "=" && source[pos + 3] != "!"
        end

        def skip_char_class(source, start)
          pos = start + 1
          pos += 1 if source[pos] == "^"
          pos += 1 if source[pos] == "]" # literal ] as first member
          while pos < source.length
            return pos if source[pos] == "]"

            pos += source[pos] == "\\" ? 2 : 1
          end
          pos
        end

        private_class_method :gated_regex_match_edges, :regex_match_edges, :match_receiver_edges, :match_operator_edges,
                             :not_match_operator_edges, :refinable_operand?, :match_member_kind, :match_dynamic_kind,
                             :custom_match_operator?, :project_string_subclass?, :apply_whole_receiver_refinement,
                             :regex_match_pattern, :regex_operand_pattern, :regex_operand_from_constant,
                             :each_structural_char, :named_groups?, :scan_group_char, :finalize_frame,
                             :next_quantifier_optional?, :capturing_group?, :named_group?, :skip_char_class
      end
    end
  end
end
