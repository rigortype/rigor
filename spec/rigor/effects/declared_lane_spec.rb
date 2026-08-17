# frozen_string_literal: true

require "prism"

require "rigor"
require "rigor/analysis/runner"
require "rigor/analysis/baseline"
require "rigor/effects/envelope_index"
require "rigor/effects/scanner"

# ADR-103 WD1 / WD6 / WD14 (#386) — the declared lane through nominal carriers, and the inherited-bound
# reading it makes honest.
#
# Two rules, one fixture (`spec/integration/fixtures/effects/liskov`), because they are two readings of
# one declaration: `effect.liskov-widened` holds an override to the bound written on the method it
# overrides, and the call-site import lets a caller through a base-typed receiver read that bound as `≤`.
# The envelope check's own rules are `spec/rigor/effects/envelope_diagnostics_spec.rb`.
RSpec.describe "the declared lane at call sites and the inherited bound" do
  def fixture
    File.expand_path("../../integration/fixtures/effects/liskov", __dir__)
  end

  # One `namespace:` stanza, selecting the base of the convention pair and NOT its subclass, so the
  # inherited-bound reading has a configured envelope to inherit.
  def envelopes
    [{ "namespace" => "Liskov::Conventions::Store", "effect" => ["io.db"] }]
  end

  def configuration(effects: { "envelopes" => envelopes }, **extra)
    data = { "paths" => ["lib"], "signature_paths" => ["sig"] }.merge(extra)
    data["effects"] = effects unless effects == :absent
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(data))
  end

  def analyze(config = configuration)
    Dir.chdir(fixture) do
      runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil)
      [runner.run(["lib"]).diagnostics, runner]
    end
  end

  def liskov(config = configuration)
    analyze(config).first.select { |d| d.rule == "effect.liskov-widened" }
  end

  describe "effect.liskov-widened" do
    # The whole judgment in one assertion: exactly these three overrides widen, and every other method
    # in the fixture — including the two overrides that are purer than what they inherit — stays silent.
    it "fires on exactly the overrides that escape the bound they inherit" do
      expect(liskov.map { |d| d.message[/Method (\S+) /, 1] }).to eq(
        [
          "Liskov::PgRepo#find",
          "Liskov::DeclaredRepo#find",
          "Liskov::Conventions::HttpStore#read"
        ]
      )
    end

    # Variant one: the override declares nothing, so what it DOES is what the inherited bound has to
    # admit. Same lane, same shortest-path explanation as `effect.envelope-exceeded`.
    it "names the proven label, its origin and the ancestor's declaration" do
      message = liskov.find { |d| d.message.include?("PgRepo") }.message

      expect(message).to eq(
        "Method Liskov::PgRepo#find performs io.net.http (Net::HTTP.get), but overrides " \
        "Liskov::Repo#find, which is declared %a{rigor:v1:effect io.db} at sig/liskov.rbs:3, " \
        "so io.net.http exceeds the inherited envelope."
      )
    end

    # Variant two: two authored bounds, compared by subsumption. The body is pure, so nothing proven
    # could have produced this — it is the declaration that violates Liskov.
    it "compares two authored bounds when the override declares its own" do
      message = liskov.find { |d| d.message.include?("DeclaredRepo") }.message

      expect(message).to eq(
        "Method Liskov::DeclaredRepo#find is declared %a{rigor:v1:effect io.net.http} at " \
        "sig/liskov.rbs:16, but overrides Liskov::Repo#find, which is declared " \
        "%a{rigor:v1:effect io.db} at sig/liskov.rbs:3, so io.net.http exceeds the inherited envelope."
      )
    end

    it "inherits a bound written as an `effects.envelopes:` convention on the ancestor alone" do
      message = liskov.find { |d| d.message.include?("HttpStore") }.message

      expect(message).to include(
        "but overrides Liskov::Conventions::Store#read, which is declared effect: [io.db] " \
        "at .rigor.yml effects.envelopes[0]"
      )
    end

    it "positions the finding at the override's Ruby `def`, not at the ancestor's signature" do
      diagnostic = liskov.find { |d| d.message.include?("PgRepo") }
      line = File.readlines(File.join(fixture, diagnostic.path))[diagnostic.line - 1]

      expect([diagnostic.path, line]).to match(["lib/liskov.rb", /def find/])
    end

    it "stays silent for an override that is purer than the bound it inherits" do
      expect(liskov.map(&:message).join).not_to include("MemRepo", "PureRepo")
    end

    it "is silent without an `effects:` block and under `effects.check: false`" do
      expect(liskov(configuration(effects: :absent))).to be_empty
      expect(liskov(configuration(effects: { "check" => false, "envelopes" => envelopes }))).to be_empty
    end

    it "resolves to :error under the strict profile and :warning under lenient" do
      table = Rigor::Configuration::SeverityProfile::PROFILES

      expect(table[:strict]["effect.liskov-widened"]).to eq(:error)
      expect(table[:lenient]["effect.liskov-widened"]).to eq(:warning)
    end
  end

  describe "the declared lane a call site imports" do
    let(:table) { analyze.last.effect_table }

    # `Reader#fetch` proves nothing and has no override, so `io.db` in the caller can only have come
    # from the base method's own envelope — imported at the call site, never joined into `proven`.
    it "reads a base method's envelope as `≤` at a caller typed to the base" do
      entry = table["Liskov::Loader#load"]

      expect(entry.declared.to_a).to eq(["io.db"])
      expect(entry.proven.to_a).to eq([])
      expect(entry).to be_exhaustive
    end

    it "files the import under an `envelope:` origin naming the callee" do
      origins = table["Liskov::Loader#load"].direct.declared_bundles.keys.map(&:to_s)

      expect(origins).to eq(["envelope:Liskov::Reader#fetch"])
    end

    # The whole point of keeping the lanes apart: the caller's own `%a{rigor:v1:effect io.db}` envelope
    # is judged against `proven`, which the import never touches.
    it "never lets an imported bound produce an `effect.envelope-exceeded`" do
      exceeded = analyze.first.select { |d| d.rule == "effect.envelope-exceeded" }

      expect(exceeded).to be_empty
    end

    it "imports a bound written as an `effects.envelopes:` convention on the receiver's class" do
      expect(table["Liskov::StoreCaller#fetch"].declared.to_a).to eq(["io.db"])
    end

    it "imports nothing at a call site whose callee declares nothing" do
      expect(table["Liskov::PgRepo#find"].declared.to_a).to eq([])
    end

    it "imports nothing from a convention stanza the project did not write" do
      entry = analyze(configuration(effects: {})).last.effect_table["Liskov::StoreCaller#fetch"]

      expect(entry.declared.to_a).to eq([])
    end
  end

  # The discharge half, pinned at the unit the rule lives in. A `Dynamic` receiver whose static facet
  # still names a class is where the taint and the envelope meet, and arranging one end to end would
  # mean arranging the typer rather than the rule.
  describe "exhaustive by envelope (ADR-103 WD6: the checked stratum discharges)" do
    def scan_with(envelopes:, dynamic:)
      source = <<~RUBY
        class Caller
          def run(repo)
            repo.find(1)
          end
        end
      RUBY
      root = Prism.parse(source).value
      call = find_call(root, :find)
      record = Rigor::Effects::Collector::CallRecord.new(
        receiver_class: "Repo", kind: :instance, dynamic: dynamic,
        cause: dynamic ? "parameter" : nil, resolved: true
      )
      calls = {}.compare_by_identity
      calls[call] = record
      Rigor::Effects::Scanner.scan(root: root, path: "caller.rb", calls: calls, envelopes: envelopes)
    end

    def find_call(node, name)
      return node if node.is_a?(Prism::CallNode) && node.name == name

      node.child_nodes.compact.each do |child|
        found = find_call(child, name)
        return found if found
      end
      nil
    end

    def index_with(bound)
      Rigor::Effects::EnvelopeIndex.new(
        method_envelopes: {
          "Repo#find" => Rigor::Effects::Envelope.build(
            owner_key: "Repo#find", bound: Rigor::Effects::LabelSet.new(bound),
            source: :effect_annotation, location: "sig/repo.rbs:2",
            spelling: "%a{rigor:v1:effect #{bound.join(', ')}}"
          )
        }
      )
    end

    it "taints `dynamic-receiver` and records no edge when nothing bounds the callee" do
      summary = scan_with(envelopes: Rigor::Effects::EnvelopeIndex.empty, dynamic: true)
                .summaries.fetch("Caller#run")

      expect(summary).not_to be_exhaustive
      expect(summary.causes).to eq([%w[dynamic-receiver parameter]])
    end

    it "keeps the site exhaustive and its project edge when the callee's declaration bounds it" do
      collection = scan_with(envelopes: index_with(["io.db"]), dynamic: true)
      summary = collection.summaries.fetch("Caller#run")

      expect(summary).to be_exhaustive
      expect(summary.causes).to eq([])
      expect(summary.declared.to_a).to eq(["io.db"])
      expect(collection.edges.fetch("Caller#run").map(&:selector)).to eq(["find"])
    end

    it "leaves an already-exhaustive site alone beyond the bound it imports" do
      summary = scan_with(envelopes: index_with(["io.db"]), dynamic: false).summaries.fetch("Caller#run")

      expect(summary).to be_exhaustive
      expect(summary.declared.to_a).to eq(["io.db"])
      expect(summary.proven.to_a).to eq([])
    end
  end

  # ADR-103 WD6's second discharging stratum. The trust distinction is project-source versus
  # environment-only, so the fixture is a signature tree the ENVIRONMENT loaded and the configuration
  # does not name — which is exactly the shape a gem's shipped RBS has.
  describe "accepted signatures" do
    def with_vendor_sig
      Dir.mktmpdir("rigor-accepted-envelope-") do |dir|
        FileUtils.mkdir_p(File.join(dir, "vendor_sig"))
        FileUtils.mkdir_p(File.join(dir, "sig"))
        File.write(File.join(dir, "vendor_sig/acme.rbs"), <<~RBS)
          module Acme
            class Client
              %a{rigor:v1:effect io.net.http}
              def call: (String url) -> String
            end
          end
        RBS
        Dir.chdir(dir) { yield(Rigor::Environment.for_project(root: dir, signature_paths: ["vendor_sig"])) }
      end
    end

    def project_only_configuration
      Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("signature_paths" => ["sig"], "effects" => {})
      )
    end

    it "imports a bound the project's own signatures never declared" do
      with_vendor_sig do |environment|
        index = Rigor::Effects::EnvelopeIndex.build(
          configuration: project_only_configuration, environment: environment
        )

        expect(index["Acme::Client", false, "call"].bound.to_a).to eq(["io.net.http"])
      end
    end

    # The complement, and the reason the two readers stay two: the CHECKED stratum is the project's own
    # sources, so the same annotation contributes no envelope the contract check could fire on.
    it "is invisible to the reader the envelope check uses" do
      with_vendor_sig do |_environment|
        scan = Rigor::RbsExtended::EnvelopeScanner.scan(
          sources: Rigor::Effects::SignatureSources.collect(signature_paths: ["sig"]),
          registry: Rigor::Effects::Registry.default
        )

        expect(scan).to be_empty
      end
    end

    it "loses to a project declaration of the same key" do
      with_vendor_sig do |environment|
        File.write("sig/acme.rbs", <<~RBS)
          module Acme
            class Client
              %a{pure}
              def call: (String url) -> String
            end
          end
        RBS
        index = Rigor::Effects::EnvelopeIndex.build(
          configuration: project_only_configuration, environment: environment
        )

        expect(index["Acme::Client", false, "call"].bound.to_a).to eq([])
      end
    end
  end

  describe "the suppression pipeline" do
    around do |example|
      Dir.mktmpdir("rigor-liskov-suppression-") do |dir|
        FileUtils.cp_r(File.join(fixture, "lib"), dir)
        FileUtils.cp_r(File.join(fixture, "sig"), dir)
        Dir.chdir(dir) { example.run }
      end
    end

    def local_findings(extra = {})
      config = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          { "paths" => ["lib"], "signature_paths" => ["sig"],
            "effects" => { "envelopes" => envelopes } }.merge(extra)
        )
      )
      Rigor::Analysis::Runner.new(configuration: config, cache_store: nil)
                             .run(["lib"]).diagnostics.select { |d| d.rule == "effect.liskov-widened" }
    end

    it "honours a `# rigor:disable` comment on the override's `def` line" do
      source = File.read("lib/liskov.rb")
      File.write(
        "lib/liskov.rb",
        source.sub(
          "class PgRepo < Repo\n    def find(id)",
          "class PgRepo < Repo\n    def find(id) # rigor:disable effect.liskov-widened"
        )
      )

      expect(local_findings.map(&:message).grep(/PgRepo/)).to be_empty
      expect(local_findings.map(&:message).grep(/DeclaredRepo/)).not_to be_empty
    end

    it "honours the project `disable:` list" do
      expect(local_findings("disable" => ["effect.liskov-widened"])).to be_empty
    end

    it "is absorbed by a project baseline" do
      diagnostics = local_findings
      remaining, absorbed = Rigor::Analysis::Baseline.from_diagnostics(diagnostics).filter(diagnostics)

      expect(remaining).to be_empty
      expect(absorbed).to eq(diagnostics.size)
    end
  end

  # The corpus half of the byte-identical contract every effects slice carries.
  describe "a collecting project with no envelopes" do
    it "produces no effect.* diagnostics and the same stream as a run with effects off" do
      tracer = File.expand_path("../../integration/fixtures/effects/tracer", __dir__)
      run = lambda do |effects|
        data = { "paths" => [tracer] }
        data["effects"] = {} if effects
        Rigor::Analysis::Runner.new(
          configuration: Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(data)),
          cache_store: nil
        ).run([tracer]).diagnostics
      end
      on = run.call(true)

      expect(on.select { |d| d.rule.to_s.start_with?("effect.") }).to be_empty
      expect(on.map(&:to_h)).to eq(run.call(false).map(&:to_h))
    end
  end
end
