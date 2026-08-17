# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor"
require "rigor/analysis/runner"
require "rigor/analysis/baseline"

UNKNOWN_LABEL_INLINE_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-rbs-inline/lib", __dir__)
$LOAD_PATH.unshift(UNKNOWN_LABEL_INLINE_PLUGIN_LIB) unless $LOAD_PATH.include?(UNKNOWN_LABEL_INLINE_PLUGIN_LIB)
require "rigor-rbs-inline"

# ADR-103 WD1 / WD14 (#384) — `effect.unknown-label`, the diagnostic paired with the fail-open rule.
#
# An unrecognised label degrades the WHOLE tag to ⊤, which is silent by construction; this is what
# keeps that silence honest. The unit-level intent rules are `label_intent_spec.rb`; here is the
# end-to-end behaviour: which declarations fire, where the finding lands, and what turns it off.
RSpec.describe "effect.unknown-label" do
  def rule
    "effect.unknown-label"
  end

  def fixture
    File.expand_path("../../integration/fixtures/effects/unknown_labels", __dir__)
  end

  def configuration(effects: {}, **extra)
    data = { "paths" => ["lib"], "signature_paths" => ["sig"] }.merge(extra)
    data["effects"] = effects unless effects == :absent
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(data))
  end

  def diagnostics_for(configuration, root: fixture, rules: [rule])
    Dir.chdir(root) do
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
                             .run(["lib"]).diagnostics.select { |d| rules.include?(d.rule) }
    end
  end

  def messages(configuration, **)
    diagnostics_for(configuration, **).map(&:message)
  end

  describe "the four intent signals" do
    it "fires on a near miss, a known sibling and a dotted path, and on nothing else" do
      expect(messages(configuration).sort).to eq(
        [
          "Effect envelope on UnknownLabels::Signals#dotted names widget.render, which is not a " \
          "known effect label; the annotation now bounds nothing.",
          "Effect envelope on UnknownLabels::Signals#known_sibling names frobnicate, which is not " \
          "a known effect label; the annotation now bounds nothing.",
          "Effect envelope on UnknownLabels::Signals#near_miss names exi, which is not a known " \
          "effect label (did you mean exit?); the annotation now bounds nothing."
        ]
      )
    end

    # The FP boundary. A vocabulary is open by design, so a bare word nothing resembles is as likely
    # to be a label this project has not registered as it is a typo — and the tag is unbounded either
    # way, which is why `lone_word`'s `puts` produces no `effect.envelope-exceeded` either.
    it "stays silent on a lone far-off word, and the tag still reads ⊤" do
      surfaced = diagnostics_for(configuration, rules: [rule, "effect.envelope-exceeded"])

      expect(surfaced.map(&:message).grep(/lone_word|database/)).to be_empty
    end

    # The registry ships an empty `retired:` table (nothing has been renamed at vocabulary 1), so the
    # spelling is stubbed rather than seeded into `data/effects/registry.yml`.
    it "names the replacement for a retired spelling" do
      retiring = Rigor::Effects::Registry.new(
        vocabulary_version: 2, labels: Rigor::Effects::Registry.default.labels,
        retired: { "io.stdout" => ["io.output.stdout"] }
      )
      allow(Rigor::Effects::Registry).to receive(:default).and_return(retiring)

      Dir.mktmpdir("rigor-retired-label-") do |dir|
        FileUtils.cp_r(File.join(fixture, "lib"), dir)
        FileUtils.mkdir_p(File.join(dir, "sig"))
        File.write(
          File.join(dir, "sig", "retired.rbs"),
          "module UnknownLabels\n  class Signals\n    %a{rigor:v1:effect io.stdout}\n    " \
          "def near_miss: () -> void\n  end\nend\n"
        )
        found = diagnostics_for(configuration, root: dir).map(&:message)

        expect(found).to include(
          "Effect envelope on UnknownLabels::Signals#near_miss names io.stdout, which is not a " \
          "known effect label (io.stdout is retired; write io.output.stdout instead); the " \
          "annotation now bounds nothing."
        )
      end
    end
  end

  describe "where the finding lands" do
    it "points at the `.rbs` line the envelope was written on" do
      diagnostic = diagnostics_for(configuration).find { |d| d.message.include?("exi,") }

      expect([diagnostic.path, diagnostic.column]).to eq(["sig/unknown_labels.rbs", 1])
      expect(File.readlines(File.join(fixture, diagnostic.path))[diagnostic.line - 1])
        .to include("%a{rigor:v1:effect exi}")
    end

    it "is authored `:info`" do
      expect(diagnostics_for(configuration).map(&:severity).uniq).to eq([:info])
    end
  end

  # The `.rb` half (ADR-103 WD5 (5)). rbs-inline's writer re-emits the author's comment block above
  # each generated member, so the annotation's line inside the synthesized buffer is NOT the `.rb`
  # line; the finding is re-anchored against the Ruby source.
  describe "an rbs-inline annotation in a `.rb` file" do
    before { Rigor::Plugin.unregister! }
    after { Rigor::Plugin.unregister! }

    def inline_diagnostics(source)
      config = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => ["demo.rb"], "plugins" => ["rigor-rbs-inline"], "effects" => {}
        )
      )
      Dir.mktmpdir("rigor-inline-unknown-label-") do |dir|
        File.write(File.join(dir, "demo.rb"), source)
        Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: config, cache_store: nil,
            plugin_requirer: ->(_name) { Rigor::Plugin.register(Rigor::Plugin::RbsInline) }
          ).run(["demo.rb"]).diagnostics.select { |d| d.rule == rule }
        end
      end
    end

    it "is positioned on the `.rb` line the author wrote the annotation on" do
      diagnostics = inline_diagnostics(<<~RUBY)
        # rbs_inline: enabled
        class Memo
          # @rbs return: Integer
          def first
            @a = 1
            @b = 2
            @c = 3
          end

          # @rbs %a{rigor:v1:effect io.bd}
          # @rbs return: Integer
          def second
            1
          end
        end
      RUBY

      expect(diagnostics.size).to eq(1)
      expect(diagnostics.first.message).to include("io.bd", "did you mean io.db?")
      expect([diagnostics.first.path, diagnostics.first.line]).to eq(["demo.rb", 10])
    end
  end

  describe "labels written in `.rigor.yml`" do
    # Shape is a tier-2 load error already; this is the other half — a well-formed label the registry
    # does not know, which tolerates nothing and would otherwise fail in total silence.
    it "reports an unknown `effects.tolerated:` member at `.rigor.yml`" do
      found = diagnostics_for(configuration(effects: { "tolerated" => ["io.netw", "io.db"] }))
              .find { |d| d.path == ".rigor.yml" }

      expect([found.path, found.line, found.column]).to eq([".rigor.yml", 1, 1])
      expect(found.message).to eq(
        "`effects.tolerated:` in .rigor.yml names io.netw, which is not a known effect label " \
        "(did you mean io.net?); the entry discharges nothing."
      )
    end

    it "leaves a recognised list alone" do
      found = messages(configuration(effects: { "tolerated" => ["io.db", "nondet.time"] }))

      expect(found.grep(/effects\.tolerated/)).to be_empty
    end
  end

  describe "the gate" do
    it "is silent without an `effects:` block" do
      expect(diagnostics_for(configuration(effects: :absent))).to be_empty
    end

    it "is silent under `effects.check: false`" do
      expect(diagnostics_for(configuration(effects: { "check" => false }))).to be_empty
    end

    it "honours the project `disable:` list" do
      expect(diagnostics_for(configuration(**{ "disable" => [rule] }))).to be_empty
    end

    it "is absorbed by a project baseline" do
      diagnostics = diagnostics_for(configuration)
      baseline = Rigor::Analysis::Baseline.from_diagnostics(diagnostics)
      remaining, absorbed = baseline.filter(diagnostics)

      expect(remaining).to be_empty
      expect(absorbed).to eq(diagnostics.size)
    end
  end
end
