# frozen_string_literal: true

require "rigor"
require "rigor/rbs_extended/envelope_scanner"

# ADR-103 #383 — the envelope READER: the `%a{pure}` / `%a{rigor:v1:effect …}` grammar, the precedence
# between them, and the fail-open reading of a tag whose meaning cannot be established. The judgment that
# consumes what this produces is `spec/rigor/effects/envelope_check_spec.rb`.
RSpec.describe Rigor::RbsExtended::EnvelopeScanner do
  let(:registry) { Rigor::Effects::Registry.default }

  def scan(source, name: "sig/demo.rbs")
    described_class.scan(sources: [[name, source]], registry: registry)
  end

  describe "the grammar (ADR-103 WD14)" do
    it "reads a single bare label" do
      result = scan(<<~RBS)
        class Repo
          %a{rigor:v1:effect io.db}
          def find: (Integer) -> String
        end
      RBS

      expect(result.method_envelopes["Repo#find"].bound.to_a).to eq(["io.db"])
    end

    it "reads a comma-separated list, whitespace-tolerant, sorted into the set" do
      result = scan(<<~RBS)
        class Repo
          %a{rigor:v1:effect nondet.time,io.db , telemetry}
          def find: (Integer) -> String
        end
      RBS

      expect(result.method_envelopes["Repo#find"].bound.to_a).to eq(%w[io.db nondet.time telemetry])
    end

    it "reads `%a{pure}` as the empty bound" do
      result = scan(<<~RBS)
        class Repo
          %a{pure}
          def slug: (String) -> String
        end
      RBS
      envelope = result.method_envelopes["Repo#slug"]

      expect([envelope.bound.to_a, envelope.source]).to eq([[], :pure_annotation])
    end

    it "tolerates `mutate.local` under every bound, `%a{pure}` included" do
      result = scan(<<~RBS)
        class Repo
          %a{pure}
          def slug: (String) -> String
        end
      RBS

      expect(result.method_envelopes["Repo#slug"].tolerates?("mutate.local")).to be(true)
    end

    # RBS accepts five bracket pairs for an annotation; the reader sees only the payload inside them,
    # so every spelling binds — and the routing pre-filter below must not lose any of them.
    it "reads the annotation whatever bracket pair RBS accepted it in" do
      result = scan(<<~RBS)
        class Repo
          %a(pure)
          def a: () -> String
          %a[rigor:v1:effect io.db]
          def b: () -> String
          %a<rigor:v1:effect telemetry>
          def c: () -> String
          %a|pure|
          def d: () -> String
        end
      RBS

      expect(result.method_envelopes.keys).to contain_exactly("Repo#a", "Repo#b", "Repo#c", "Repo#d")
      expect(result.method_envelopes["Repo#b"].bound.to_a).to eq(["io.db"])
    end

    it "keys a singleton member on the `.` side and `def self?.` on both" do
      result = scan(<<~RBS)
        class Repo
          %a{rigor:v1:effect io.db}
          def self.find: (Integer) -> String

          %a{pure}
          def self?.slug: (String) -> String
        end
      RBS

      expect(result.method_envelopes.keys).to eq(["Repo.find", "Repo#slug", "Repo.slug"])
    end

    it "keys a nested declaration by its lexical path" do
      result = scan(<<~RBS)
        module App
          class Repo
            %a{rigor:v1:effect io.db}
            def find: (Integer) -> String
          end
        end
      RBS

      expect(result.method_envelopes.keys).to eq(["App::Repo#find"])
    end
  end

  describe "the routing pre-filter" do
    # The positive controls are every example above: an annotated source IS parsed and read. This is
    # the other half — a source with no honoured payload can contribute neither an envelope nor an
    # unresolved report, so it is answered by one regex and never parsed.
    it "never parses a source that carries no effect annotation" do
      allow(RBS::Parser).to receive(:parse_signature)

      result = scan(<<~RBS)
        class Repo
          %a{implicitly-returns-nil}
          def find: (Integer) -> String?
        end
      RBS

      expect(result).to be_empty
      expect(RBS::Parser).not_to have_received(:parse_signature)
    end
  end

  describe "the readings that produce no bound" do
    # Each is ⊤ — "any effect, or an effect we cannot name" — never the recognisable subset of the tag.
    # Narrowing a typo to what happened to parse would put findings on correct code; widening suppresses
    # them, which is the direction the false-positive budget runs (ADR-5).
    {
      "an empty list" => "%a{rigor:v1:effect}",
      "a token outside the label grammar" => "%a{rigor:v1:effect io/db}",
      "an uppercase token" => "%a{rigor:v1:effect IO}",
      "a trailing comma" => "%a{rigor:v1:effect io.db,}",
      "a label the registry does not know" => "%a{rigor:v1:effect io.bd}"
    }.each do |description, annotation|
      it "reads #{description} as ⊤" do
        result = scan(<<~RBS)
          class Repo
            #{annotation}
            def find: (Integer) -> String
          end
        RBS

        expect(result.method_envelopes["Repo#find"].top?).to be(true)
      end
    end

    it "records a malformed payload on the reporter channel" do
      result = scan(<<~RBS)
        class Repo
          %a{rigor:v1:effect io/db}
          def find: (Integer) -> String
        end
      RBS

      expect(result.unresolved.map(&:payload)).to eq(["rigor:v1:effect io/db"])
    end

    # The seam #384's `effect.unknown-label` reads. An unknown spelling is a DIFFERENT condition from a
    # malformed one — the grammar held — so it is carried rather than reported as unresolved.
    it "carries an unknown spelling on the envelope and leaves the reporter silent" do
      result = scan(<<~RBS)
        class Repo
          %a{rigor:v1:effect io.bd}
          def find: (Integer) -> String
        end
      RBS

      expect(result.method_envelopes["Repo#find"].unknown_labels).to eq(["io.bd"])
      expect(result.unresolved).to be_empty
    end
  end

  describe "`pure` versus `effect` on one declaration" do
    let(:result) do
      scan(<<~RBS)
        class Repo
          %a{pure}
          %a{rigor:v1:effect io.db}
          def find: (Integer) -> String
        end
      RBS
    end

    it "lets `pure` win" do
      expect(result.method_envelopes["Repo#find"].bound.to_a).to eq([])
    end

    it "records the contradiction rather than resolving it silently" do
      expect(result.unresolved.map(&:payload).join).to include("contradictory", "`pure` wins")
    end
  end

  describe "class- and module-level envelopes" do
    let(:result) do
      scan(<<~RBS)
        %a{rigor:v1:effect io.db}
        class Repo
          def find: (Integer) -> String
        end

        %a{pure}
        module Tools
          def self.slug: (String) -> String
        end
      RBS
    end

    it "collects them under the class / module name, not a method key" do
      expect(result.class_envelopes.keys).to eq(%w[Repo Tools])
      expect(result.method_envelopes).to be_empty
    end

    it "stamps them `:class_annotation` whichever spelling was used" do
      expect(result.class_envelopes.values.map(&:source)).to eq(%i[class_annotation class_annotation])
    end
  end

  describe "the location" do
    it "carries the annotation's own `path:line`, project-relative" do
      result = scan(<<~RBS)
        class Repo
          %a{rigor:v1:effect io.db}
          def find: (Integer) -> String
        end
      RBS

      expect(result.method_envelopes["Repo#find"].location).to eq("sig/demo.rbs:2")
    end

    # rbs-inline's synthesized RBS arrives in a `virtual:<plugin-id>:<source path>` buffer; the path a
    # reader can act on is the Ruby file, so the synthetic prefix is dropped.
    it "strips the `virtual:` prefix a synthesized buffer carries" do
      result = scan(<<~RBS, name: "virtual:rbs-inline:app/models/user.rb")
        class User
          %a{pure}
          def slug: () -> String
        end
      RBS

      expect(result.method_envelopes["User#slug"].location).to eq("app/models/user.rb:2")
    end
  end

  it "is fail-soft on an unparseable signature" do
    expect(scan("class Repo\n  def find: (Integer -> \n")).to be_empty
  end

  it "reads nothing from a declaration carrying no annotation" do
    expect(scan("class Repo\n  def find: (Integer) -> String\nend\n")).to be_empty
  end
end
