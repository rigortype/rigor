# frozen_string_literal: true

require "spec_helper"

# Drift guard for issue #449.
#
# ADR-72's Gemfile.lock-gated overlay (`data/gem_overlay/activesupport/core_ext.rbs`) and the opt-in
# `rigor-activesupport-core-ext` plugin are two hand-maintained copies of one surface. The overlay's own
# header says so and asks the author to "keep the two in sync when extending coverage" — and nothing
# checked it, so they drifted by twelve selectors.
#
# The cost of the drift falls entirely on the overlay's side, and it is a FALSE POSITIVE on correct code,
# which AGENTS.md ranks above the worst-case static reading: `Date#to_time` reached the plugin in #437 and
# not the overlay, so `date.to_time(:utc)` — ordinary ActiveSupport — drew an arity error on every project
# that locks activesupport without opting into the plugin. The other eleven were `call.undefined-method` on
# `String#dasherize`, `Object#in?` and friends, by the same mechanism.
#
# The invariant is one-directional on purpose. The plugin is the authoring home, so a row lands there
# first; what must never happen is that it STAYS there, because the overlay is the copy that applies
# automatically and therefore reaches every project that has not opted in.
#
# The comparison is by SELECTOR, deliberately, and NOT by signature (issue #661 asked). The two halves are
# def-line identical today, but a signature comparison would go red on a legitimate divergence — the
# overlay is free to be the more conservative copy (`() -> untyped` where the plugin, which a project has
# to opt into, can afford a precise type), and a looser overlay row costs nothing: the drift that hurt in
# #449 was a row the overlay did not declare AT ALL, which is what this guard catches. Under AGENTS.md's
# false-positives-outrank-worst-case-reading rule, a gate that fires on a deliberate difference is the
# thing that teaches people to route around it, so the narrower invariant is the one worth enforcing.
RSpec.describe "ActiveSupport overlay / plugin parity" do
  def repo_root
    File.expand_path("../../..", __dir__)
  end

  def overlay_path
    File.join(repo_root, "data/gem_overlay/activesupport/core_ext.rbs")
  end

  def plugin_path
    File.join(repo_root, "plugins/rigor-activesupport-core-ext/sig/active_support/core_ext.rbs")
  end

  # Parsed with RBS rather than by regex: a regex over `def` lines cannot see nesting, and `ERB::Util`
  # is exactly the case it would get wrong — the first version of this guard reported parity while
  # `Util.html_escape_once` was still missing, because it keyed the row on `Util` alone.
  def selectors(path)
    _, _, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: path, content: File.read(path)))
    walk(decls, []).to_set
  end

  def walk(decls, prefix)
    decls.flat_map do |decl|
      next [] unless decl.respond_to?(:members)

      nested = prefix + [decl.name.to_s.sub(/\A::/, "")]
      decl.members.flat_map do |member|
        next walk([member], nested) unless member.is_a?(RBS::AST::Members::MethodDefinition)

        member.kind == :singleton ? ["#{nested.join('::')}.#{member.name}"] : ["#{nested.join('::')}##{member.name}"]
      end
    end
  end

  # Issue #661 — the drifted selectors, spelled out. This lived inline in the failure lambda below and
  # named a constant (`OVERLAY`) that never existed, so the one run that reaches it — a real drift —
  # raised `NameError` instead of reporting what drifted. A lambda body is only ever executed on failure,
  # which is exactly why it needs an example of its own ("names the drifted selector", below) rather than
  # the passing run's coverage.
  def drift_message(missing)
    "the plugin declares #{missing.size} selector(s) the auto-applied overlay does not, so a project " \
      "that locks activesupport without the plugin sees a false positive on each:\n  " \
      "#{missing.sort.join("\n  ")}\n" \
      "Add them to #{overlay_path.delete_prefix("#{repo_root}/")} (declarations only — the overlay " \
      "carries no effect annotations)."
  end

  it "declares in the overlay every selector the plugin declares" do
    missing = selectors(plugin_path) - selectors(overlay_path)

    expect(missing).to be_empty, -> { drift_message(missing) }
  end

  # The failure path itself, driven directly: on a drift the author must be told WHICH selector to port
  # and where to put it, and there is no other run in which that string is ever built.
  it "names the drifted selector in the failure message" do
    message = drift_message(Set["ActiveSupport::Duration#parts", "String#dasherize"])

    expect(message).to include("ActiveSupport::Duration#parts", "String#dasherize")
    expect(message).to include("data/gem_overlay/activesupport/core_ext.rbs")
    expect(message).to include("2 selector(s)")
  end

  # The guard's own non-vacuity: a parity assertion passes trivially if the extractor returns nothing,
  # which is precisely how the first version of it passed while twelve rows were missing.
  it "extracts a plausible surface from both files, so parity is not vacuous" do
    expect(selectors(plugin_path).size).to be > 200
    expect(selectors(overlay_path).size).to be > 200
    expect(selectors(plugin_path)).to include("Date#to_time", "ERB::Util.html_escape_once", "String#dasherize")
  end

  # The overlay is deliberately annotation-free: effect envelopes on gem-shipped RBS are read by the
  # accepted-signature lane (ADR-103 WD6), and the overlay applies to projects that never opted into the
  # plugin. Porting a row must not port its `%a{pure}`.
  it "keeps the overlay free of effect annotations" do
    expect(File.read(overlay_path)).not_to include("%a{")
    expect(File.read(plugin_path)).to include("%a{pure}")
  end
end
