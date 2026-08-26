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
RSpec.describe "ActiveSupport overlay / plugin parity" do
  def overlay_path
    File.expand_path("../../../data/gem_overlay/activesupport/core_ext.rbs", __dir__)
  end

  def plugin_path
    File.expand_path("../../../plugins/rigor-activesupport-core-ext/sig/active_support/core_ext.rbs", __dir__)
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

  it "declares in the overlay every selector the plugin declares" do
    missing = selectors(plugin_path) - selectors(overlay_path)

    expect(missing).to be_empty, lambda {
      "the plugin declares #{missing.size} selector(s) the auto-applied overlay does not, so a project " \
        "that locks activesupport without the plugin sees a false positive on each:\n  " \
        "#{missing.sort.join("\n  ")}\nAdd them to #{OVERLAY.sub("#{Dir.pwd}/", '')} (declarations only — " \
        "the overlay carries no effect annotations)."
    }
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
