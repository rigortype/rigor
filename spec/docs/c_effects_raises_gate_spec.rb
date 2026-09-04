# frozen_string_literal: true

# Verifies `data/builtins/ruby_core/*.yml`'s `c_effects:` facet against the C body each row's own
# `c_body_at` cites. An empty (or `raises`-omitting) `c_effects` list is a positive claim — "this method
# has no C-level effects, `raises` included" — and #756 found that claim wrong in bulk: 36 rows across
# eight files omitted `raises` while the function their own `c_body_at` points at raises, 32 of them with
# a bare `c_effects: []`. Nothing checked the claim against the source it cited, so it stood uncaught.
#
# The facet is load-bearing: #390 gates `effect.discarded-pure-result` on the callee being total on its
# domain and names this facet as the source, so an under-claimed `raises` is exactly the false positive
# that gate exists to avoid (`hash.fetch(:k)`-shaped code).
#
# `references/ruby` is an optional submodule (AGENTS.md) that CI does not check out, so the main example
# below SKIPS — not fails — when it is absent, following the established `skip "<reason>" unless
# <condition>` pattern (spec/rigor/runtime/jit_spec.rb, spec/rigor/inference/fork_map_spec.rb, …) rather
# than spec/docs/link_integrity_spec.rb's "exclude without checking" treatment: that file's `references/`
# links are permanently unresolvable in CI by design, whereas a `raises` claim is genuinely checkable
# wherever the checkout happens to exist, so a skip (not a standing exclusion) is the honest state. That
# is also why this lives under `spec/docs/` (`make docs-check`) rather than `make verify`: it can only run
# with an optional checkout in place, the same shape as the rest of this directory's gates.
#
# The primitive list below is a heuristic, and the direction of its errors matters: a MISSED primitive
# leaves a row unflagged — no worse than before this gate existed — but a FALSE hit fails the spec on a
# row that is actually correct. So the list starts conservative (verified against every row it currently
# matches, below) and grows only with the same verification. Two things it deliberately does NOT include,
# despite being named in #756's illustrative list:
#
# - `NUM2*` / `rb_check_*` — both are far too broad to gate on. Scanning the current (already
#   human-audited) catalogue with them flags 62 and 121 rows respectively, the overwhelming majority
#   correct: `rb_check_funcall` is the family member that explicitly does NOT raise (it is the
#   non-raising alternative to `rb_funcall`), and `rb_check_frozen` is already captured by the `mutate`
#   facet elsewhere. `tool/extract_builtin_catalog.rb`'s own CBodyClassifier::RAISERS excludes
#   `rb_num2*` / `rb_check_arity` / `rb_scan_args` for the identical reason (documented there): virtually
#   every `-1`-arity C function does argument coercion, so counting it here would make the facet fire
#   almost everywhere and defeat the purpose a consumer like #390 needs it for.
# - `rb_memerror` — #756 flags this one by name: a bare OOM path exists in nearly every allocating C
#   function, so it alone should not force the facet without a human adjudicating the specific row (the
#   one case it would have caught, `MatchData#initialize_copy`, is already covered here by
#   `OBJ_INIT_COPY`, which reaches `rb_obj_init_copy`'s unconditional `rb_raise`/`rb_check_frozen`).
#
# `rb_struct_modify`, `Check_Type`, and `OBJ_INIT_COPY` are each included as exact, narrow tokens (not a
# prefix family) specifically because each was hand-verified against every row it currently matches
# below — the same "verified, not adopted on trust" standard #757 held its data corrections to.

require "spec_helper"
require "yaml"

module CEffectsRaisesAudit
  # Curated, deliberately narrow: see the file header for what was tried and rejected, and why.
  # Every regex here is a literal token match, not a broad prefix — grep the header comment before
  # widening one of these into a family (`rb_sys_fail\w*` already covers `rb_sys_fail_path` etc.; a
  # NEW prefix family needs the same full-corpus verification pass the header describes).
  RAISE_PRIMITIVES = {
    "rb_raise" => /\brb_raise\w*\b/,
    "rb_sys_fail" => /\brb_sys_fail\w*\b/,
    "rb_syserr_fail" => /\brb_syserr_fail\w*\b/,
    "rb_sys_enc_fail" => /\brb_sys_enc_fail\w*\b/,
    "rb_error_arity" => /\brb_error_arity\b/,
    "rb_eof_error" => /\brb_eof_error\b/,
    "rb_struct_modify" => /\brb_struct_modify\b/,
    "Check_Type" => /\bCheck_Type\b/,
    "OBJ_INIT_COPY" => /\bOBJ_INIT_COPY\b/
  }.freeze

  module_function

  # A file used by every row's `c_body_at` — its presence stands in for "the references/ruby submodule
  # is checked out at `root`" without hard-coding the sparse/full-checkout question (`make init-submodules`
  # takes references/ruby full, not sparse — see the Makefile — so any perennial top-level source file
  # works as the marker).
  def ruby_reference_checked_out?(root)
    File.file?(File.join(root, "references/ruby/object.c"))
  end

  # Scans every `data/builtins/ruby_core/*.yml`-shaped file matched by `glob`, resolving each row's
  # `c_body_at` against `root`, and returns one description string per row whose body matches a
  # {RAISE_PRIMITIVES} entry while its own `c_effects` omits `raises`.
  def violations(root:, glob:)
    Dir.glob(glob).each_with_object([]) do |yml_path, found|
      catalog = YAML.safe_load_file(yml_path, permitted_classes: [Symbol])
      each_c_row(catalog) do |class_name, method_name, row|
        next if raises_claimed?(row)

        c_body_at = row["c_body_at"]
        next if c_body_at.nil? || c_body_at == "not_found"

        body = extract_c_body(root, c_body_at)
        next if body.nil?

        primitive = matched_primitive(body)
        next unless primitive

        found << "#{File.basename(yml_path)}: #{class_name}##{method_name} (#{c_body_at}) — body " \
                 "reaches `#{primitive}` but c_effects omits `raises`"
      end
    end
  end

  def each_c_row(catalog)
    (catalog["classes"] || {}).each do |class_name, class_data|
      %w[instance_methods singleton_methods].each do |kind|
        (class_data[kind] || {}).each do |method_name, row|
          next unless row.is_a?(Hash) && row["c_body_at"]

          yield class_name, method_name, row
        end
      end
    end
  end

  def raises_claimed?(row)
    Array(row["c_effects"]).include?("raises")
  end

  def matched_primitive(body)
    stripped = strip_comments(body)
    RAISE_PRIMITIVES.each do |name, pattern|
      return name if stripped.match?(pattern)
    end
    nil
  end

  def strip_comments(text)
    text.gsub(%r{/\*.*?\*/}m, "").gsub(%r{//[^\n]*}, "")
  end

  # `c_body_at` is `<path>:<line>`, `line` being the 1-indexed source line of the function's name
  # (`extract_builtin_catalog.rb`'s own convention — the line matching `name(args)`, not the return-type
  # line above it nor the `{` below it). Scans forward for the opening brace, then balances braces to
  # find the matching close, and returns the joined body text (inclusive of both braces).
  def extract_c_body(root, c_body_at)
    idx = c_body_at.rindex(":")
    return nil unless idx

    abs_path = File.join(root, c_body_at[0...idx])
    line_no = c_body_at[(idx + 1)..].to_i
    return nil unless File.file?(abs_path)

    lines = File.readlines(abs_path)
    start_idx = line_no - 1
    return nil if start_idx.negative? || start_idx >= lines.length

    brace_idx = start_idx
    brace_idx += 1 while brace_idx < lines.length && !lines[brace_idx].start_with?("{")
    return nil if brace_idx >= lines.length

    end_idx = balanced_close(lines, brace_idx)
    return nil if end_idx.nil?

    lines[brace_idx..end_idx].join
  end

  # From `lines[open_idx]` (the function body's opening `{`), walks forward summing brace depth per
  # line until it returns to zero, and returns that line's index — or nil if the file ends first.
  def balanced_close(lines, open_idx)
    depth = 0
    idx = open_idx
    while idx < lines.length
      depth += lines[idx].count("{") - lines[idx].count("}")
      return idx if depth <= 0 && (idx > open_idx || lines[idx].include?("}"))

      idx += 1
    end
    nil
  end
end

C_EFFECTS_RAISES_GATE_REPO_ROOT = File.expand_path("../..", __dir__)
C_EFFECTS_RAISES_GATE_FIXTURE_ROOT = File.join(__dir__, "..", "fixtures", "c_effects_raises_gate")

RSpec.describe "builtin catalogue c_effects raises facet" do
  it "matches every row's raises facet against the C body its own c_body_at cites" do
    unless CEffectsRaisesAudit.ruby_reference_checked_out?(C_EFFECTS_RAISES_GATE_REPO_ROOT)
      skip "references/ruby is an optional submodule (AGENTS.md) and is not checked out here"
    end

    violations = CEffectsRaisesAudit.violations(
      root: C_EFFECTS_RAISES_GATE_REPO_ROOT,
      glob: File.join(C_EFFECTS_RAISES_GATE_REPO_ROOT, "data/builtins/ruby_core/*.yml")
    )
    expect(violations).to be_empty,
                          "c_effects omits `raises` for a row whose own c_body_at raises " \
                          "(fix the data — see #756):\n" + violations.map { |v| "  → #{v}" }.join("\n")
  end

  # #756's mandatory clause: "the gate is green" and "the gate can execute the fail path" are different
  # claims. This runs unconditionally (no references/ruby checkout needed — the fixture supplies its own
  # tiny C source) and proves the scan actually flags a wrong row, and does not also flag a correct one.
  it "flags a fixture row whose body raises but whose c_effects omits it, and not its correct sibling" do
    violations = CEffectsRaisesAudit.violations(
      root: C_EFFECTS_RAISES_GATE_FIXTURE_ROOT,
      glob: File.join(C_EFFECTS_RAISES_GATE_FIXTURE_ROOT, "data/builtins/ruby_core/*.yml")
    )
    expect(violations.size).to eq(1)
    expect(violations.first).to include("FakeClass#broken", "rb_raise")
  end
end
