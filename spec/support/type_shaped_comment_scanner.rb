# frozen_string_literal: true

require "prism"

# Scanner behind spec/docs/type_shaped_comments_spec.rb. A "type-shaped comment" is a type written
# in a comment rather than checked RBS (sig/) or an inferred type: it is never verified, so it can
# lie, and an agent reading the source has no way to tell a comment type from a checked one. Types
# live in sig/ or are left to inference; comments carry prose. See AGENTS.md's "RBS Authorship" and
# ADR-93 for why an inline rbs-inline annotation (`#:`, `# @rbs`) is a stronger violation of the same
# idea in THIS repository specifically — Rigor's own product default ingests those as live type
# sources, so one left in Rigor's own tree would be read by Rigor itself, not just by a human.
#
# Every rule works off `Prism.parse_comments`/`Prism#comments` — real `Comment` nodes, never a
# line-oriented regex over raw source — so text that merely looks like a comment inside a string or
# heredoc literal (e.g. the diagnostic message strings in
# lib/rigor/analysis/rule_catalog.rb that embed the literal text "# @rbs") is never matched: Prism
# only emits a `Comment` for an actual `#` token.
module TypeShapedCommentScanner
  # One flagged line. `path` is caller-supplied (repo-relative in the corpus specs, an arbitrary
  # label in the unit specs); `excerpt` is the comment's own source text, whitespace-trimmed.
  Violation = Struct.new(:path, :line, :excerpt, keyword_init: true) do
    def to_s
      "#{path}:#{line}: #{excerpt}"
    end
  end

  # The gated scope (relative to a repo root): Rigor's own product tree. Deliberately excludes
  # spec/, tool/, bin/, and references/ (vendored upstream, not Rigor code).
  SCAN_GLOBS = %w[
    lib/**/*.rb
    plugins/*/lib/**/*.rb
    examples/*/lib/**/*.rb
  ].freeze

  # YARD tags whose grammar reserves a `[Type]` slot right after the tag (or after the one name
  # token that follows it, for the tags that take a name). Every one of these must be written with
  # that slot left empty in Rigor's own tree: `@param name description`, `@return description`,
  # `@raise ExceptionClass description`. `@!attribute` is a different tag (its `[r]`/`[w]` is an
  # access mode, not a type slot) and is intentionally absent from this list.
  NAME_SLOT_TAGS = %w[param yieldparam option].freeze
  TYPE_FIRST_TAGS = %w[return yieldreturn raise].freeze
  YARD_TYPE_TAGS = (NAME_SLOT_TAGS + TYPE_FIRST_TAGS).freeze

  # R1 (type-shaped tag) — matches a `[` in a position YARD's own grammar defines as a type slot:
  # directly after any of the tags (`@return [T]`, `@param [T] name`, `@raise [X]`), or, only for the
  # tags that take a name, after exactly one name token (`@param name [T]`, `@option opts [T] :key`).
  # `@return` and its siblings have no name slot, so a bracket after their first word is description
  # (`@return `{ [path, name] => row }``), not a type. A `[` anywhere else — later prose, a `{Foo#bar}`
  # cross-reference, `@!attribute [r]`'s access-mode marker, `@see` — never reaches a slot, so none of
  # those match. This is deliberate: AGENTS.md weighs false positives heavily, and a bracket three words
  # into a description is not a type annotation.
  TAG_BRACKET_RE = /
    \A@(?:
        (?:#{NAME_SLOT_TAGS.join('|')})\b[ \t]*(?: \[ | \S+[ \t]+\[ )
      | (?:#{TYPE_FIRST_TAGS.join('|')})\b[ \t]*\[
    )
  /x

  # R2 (inline rbs annotation) — mirrors the coarse, deliberately false-positive-safe heuristic
  # `DiagnosticAggregator` already ships for the same shape, `INLINE_ANNOTATION_SHAPE`
  # (lib/rigor/analysis/runner/diagnostic_aggregator.rb, ~L270-310), used there to detect that a
  # project carries rbs-inline annotations when the `rbs-inline` library itself is not installed.
  # Reused verbatim in judgment, simplified in mechanics: that heuristic scans raw file text and so
  # anchors on `(?:^|\s)#` to admit a trailing comment; here every candidate is already an isolated
  # Prism `Comment`, whose slice always starts at the `#` itself, so `\A#` is the same test. Keys on
  # the `# @rbs` block form (`# @rbs!`, `# @rbs skip` included — anything starting `@rbs` followed by
  # a word boundary) and on a `#:` comment immediately followed by the start of an RBS type (`(`,
  # `[`, `{`, `?`, an uppercase `Constant`, or an RBS lowercase base type). Never matches an RDoc
  # directive (`#:nodoc:`, `#:yields:`, `#:call-seq:`, …), which reads as a bare lowercase word
  # closed by a colon and so satisfies neither alternative.
  INLINE_RBS_RE = /
    \A\#\s*@rbs\b
    |
    \A\#:[ \t]*(?:[\[({?A-Z]|(?:bool|void|nil|untyped|top|bot|self|instance|class)\b)
  /x

  # R3 (stale parameter name) — the two tags from YARD_TYPE_TAGS that name a parameter.
  PARAM_NAME_TAG_RE = /\A@(?:param|option)\b[ \t]+(\S+)/

  # R5 (missing delimiter) — with the type slot gone, nothing separates the name from the prose
  # (`@param format the output format`), which is hard to read for anyone who does not already know
  # the parameter list. The house form puts an em dash after the name token (`@param format — the
  # output format`, `@raise ArgumentError — when amount is zero`; a bare `@param name —` when the
  # description continues on the next line). YARD keeps the name binding either way (the dash lands
  # in the description text), so the delimiter costs nothing a tool reads. `@return` has no name and
  # needs no delimiter. Only the tags that take a name token are checked.
  DELIMITED_TAG_RE = /\A@(?:param|yieldparam|option|raise)\b[ \t]+\S+[ \t]+—(?:[ \t]|\z)/
  NAME_TOKEN_TAG_RE = /\A@(?:param|yieldparam|option|raise)\b[ \t]+\S+/

  # R4 (stale forward reference) — narrow on purpose (AGENTS.md: "a check that fires on correct
  # input teaches people to route around it"). Only an explicit, numbered forward reference; not any
  # mention of "will" or "later" prose, which is common and legitimate in design-rationale comments.
  STALE_FORWARD_REF_RE = /\bSlice \d+ will\b|\bdeferred to Slice \d+\b/i

  module_function

  # Every file in the gated scope under `root`, sorted for stable output.
  def scan_paths(root)
    SCAN_GLOBS.flat_map { |glob| Dir.glob(File.join(root, glob)) }.sort
  end

  # Runs all four rules over `source` (a single file's content). `path` is only ever used to label
  # the returned Violations — this method never touches the filesystem, which is what lets the unit
  # examples in the spec exercise each rule on an inline fixture.
  #
  # Returns {r1:, r2:, r3:, r4:, r5:} => Array[Violation].
  def scan_source(path, source)
    {
      r1: r1_type_shaped_tag(path, source),
      r2: r2_inline_rbs_annotation(path, source),
      r3: r3_stale_parameter_name(path, source),
      r4: r4_stale_forward_reference(path, source),
      r5: r5_missing_delimiter(path, source)
    }
  end

  # Runs scan_source over every file scan_paths(root) finds, concatenating each rule's violations
  # across the whole tree. Violation#path is repo-relative (relative to `root`).
  def scan_tree(root)
    totals = { r1: [], r2: [], r3: [], r4: [], r5: [] }
    scan_paths(root).each do |absolute|
      relative = absolute.delete_prefix("#{root}/")
      source = File.read(absolute, encoding: "utf-8")
      result = scan_source(relative, source)
      totals.each_key { |rule| totals[rule].concat(result[rule]) }
    end
    totals
  end

  # Prism::InlineComment nodes only (never Prism::EmbDocComment / `=begin`..`=end` blocks — Rigor's
  # own tree carries none, and no rbs-inline or YARD tag grammar is ever written inside one).
  def inline_comments(source)
    Prism.parse_comments(source).grep(Prism::InlineComment)
  end
  private_class_method :inline_comments

  # A comment's own source text with the leading `#` run and following whitespace stripped, e.g.
  # `"# @param name [String] x"` => `"@param name [String] x"`.
  def comment_body(comment)
    comment.location.slice.sub(/\A#+[ \t]*/, "")
  end
  private_class_method :comment_body

  def r1_type_shaped_tag(path, source)
    inline_comments(source).filter_map do |comment|
      next unless TAG_BRACKET_RE.match?(comment_body(comment))

      Violation.new(path: path, line: comment.location.start_line, excerpt: comment.location.slice.strip)
    end
  end

  def r5_missing_delimiter(path, source)
    inline_comments(source).filter_map do |comment|
      body = comment_body(comment)
      next unless NAME_TOKEN_TAG_RE.match?(body)
      next if DELIMITED_TAG_RE.match?(body)

      Violation.new(path: path, line: comment.location.start_line, excerpt: comment.location.slice.strip)
    end
  end

  def r2_inline_rbs_annotation(path, source)
    inline_comments(source).filter_map do |comment|
      next unless INLINE_RBS_RE.match?(comment.location.slice)

      Violation.new(path: path, line: comment.location.start_line, excerpt: comment.location.slice.strip)
    end
  end

  # A doc block is the run of pure-comment lines immediately (no blank line, no code line) above a
  # `def`. "Pure" means the comment is the only thing on its line — a trailing comment on a code
  # statement one line above a `def` is not a doc block for that `def`, even though Prism reports a
  # Comment at that line too.
  def r3_stale_parameter_name(path, source)
    result = Prism.parse(source)
    return [] unless result.success?

    pure_comments = pure_comment_lines(source)
    violations = []
    each_def_node(result.value) do |def_node|
      doc_block = doc_block_above(def_node, pure_comments)
      violations.concat(stale_param_violations(path, def_node, doc_block)) unless doc_block.empty?
    end
    violations
  end

  # {line_number => Comment}, restricted to lines where the comment is the only thing on the line —
  # a trailing comment on a code statement is never part of a doc block (see r3_stale_parameter_name).
  def pure_comment_lines(source)
    lines = source.lines
    inline_comments(source).each_with_object({}) do |comment, index|
      line = comment.location.start_line
      before = lines[line - 1].to_s[0...comment.location.start_column]
      index[line] = comment if before.strip.empty?
    end
  end
  private_class_method :pure_comment_lines

  # Every `@param`/`@option` tag in doc_block whose name is not one of def_node's own parameter names.
  #
  # A `**rest` capture legitimately absorbs keyword options that never appear in def_parameter_names
  # under their own name (lib/rigor/type/hash_shape.rb's `initialize(pairs = nil, **keywords)`
  # individually `@param`-documents four such options, `POLICY_KEYWORDS`, none of which is a literal
  # parameter). Real drift — a `@param` naming a parameter the signature dropped outright — is common
  # enough in this exact corpus to be worth keeping the rule for (five `RbsCacheProducer` subclasses
  # still document a `store` argument `compute(loader)` no longer takes, four `try_dispatch` overloads
  # still list the pre-`CallContext` keyword arguments), but a `**rest` def makes "not a declared name"
  # too weak a signal to tell the two apart, so the whole block is skipped rather than risk teaching
  # people to route around the rule on the common case.
  def stale_param_violations(path, def_node, doc_block)
    return [] if kwrest_present?(def_node)

    param_names = def_parameter_names(def_node)
    doc_block.filter_map do |line, comment|
      match = PARAM_NAME_TAG_RE.match(comment_body(comment))
      next unless match

      name = normalize_param_token(match[1])
      next if name.empty? || param_names.include?(name)

      Violation.new(path: path, line: line, excerpt: comment.location.slice.strip)
    end
  end
  private_class_method :stale_param_violations

  def r4_stale_forward_reference(path, source)
    inline_comments(source).filter_map do |comment|
      next unless STALE_FORWARD_REF_RE.match?(comment.location.slice)

      Violation.new(path: path, line: comment.location.start_line, excerpt: comment.location.slice.strip)
    end
  end

  # Depth-first walk collecting every Prism::DefNode, including one `def` nested inside another.
  def each_def_node(node, &block)
    return unless node.is_a?(Prism::Node)

    block.call(node) if node.is_a?(Prism::DefNode)
    node.compact_child_nodes.each { |child| each_def_node(child, &block) }
  end
  private_class_method :each_def_node

  # [[line, comment], ...] top-down for the contiguous run of pure-comment lines directly above
  # def_node, or [] when the line immediately above is not a pure-comment line (blank, code, or a
  # trailing comment on code) — "a block separated by a blank line is not a doc block".
  def doc_block_above(def_node, pure_comments_by_line)
    block = []
    line = def_node.location.start_line - 1
    while (comment = pure_comments_by_line[line])
      block.unshift([line, comment])
      line -= 1
    end
    block
  end
  private_class_method :doc_block_above

  # Every parameter/keyword/rest/block name a `def` declares, as bare strings (`"name"`, never
  # `"*name"` / `"name:"`) — Prism's own `#name` already omits the sigil and colon.
  def def_parameter_names(def_node)
    params = def_node.parameters
    return [] unless params

    nodes = params.requireds + params.optionals + params.posts + params.keywords
    names = nodes.filter_map { |n| n.name if n.respond_to?(:name) }
    names << params.rest&.name
    names << params.keyword_rest&.name
    names << params.block&.name
    names.compact.map(&:to_s)
  end
  private_class_method :def_parameter_names

  # Whether def_node declares a `**rest` (keyword-rest) parameter, named or anonymous.
  def kwrest_present?(def_node)
    !def_node.parameters&.keyword_rest.nil?
  end
  private_class_method :kwrest_present?

  # Strips the sigils a `@param`/`@option` name token may carry so it compares equal to the bare
  # name Prism reports for the matching def parameter: a leading `*`/`**`/`&`, a trailing `:`
  # (keyword params are written `name:` in both the def and, sometimes, the doc).
  def normalize_param_token(token)
    token.sub(/\A[*&]{1,2}/, "").sub(/:\z/, "")
  end
  private_class_method :normalize_param_token
end
