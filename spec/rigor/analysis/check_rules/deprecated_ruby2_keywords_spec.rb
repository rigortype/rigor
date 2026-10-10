# frozen_string_literal: true

require "spec_helper"
require "rigor/analysis/rule_catalog"

# Issue #1692 (the ADR-47 WD5 amendment) — `call.deprecated-ruby2-keywords`: a call to the `ruby2_keywords` family
# Ruby 4.1 deprecates (Feature #22205), reported only when `.rigor.yml` states a 4.1+ runtime through an explicit
# `target_ruby`.
RSpec.describe "call.deprecated-ruby2-keywords", type: :runner do
  rule = "call.deprecated-ruby2-keywords"

  def deprecations(source, target: "4.1", **config)
    config = config.transform_keys(&:to_s)
    config["target_ruby"] = target unless target.nil?
    analyze(source, config: config).diagnostics.select { |d| d.rule.to_s == "call.deprecated-ruby2-keywords" }
  end

  def fired(source, **)
    deprecations(source, **).map(&:line)
  end

  let(:module_form) do
    <<~RUBY
      class Delegator
        ruby2_keywords def method_missing(name, *args, &) = super
      end
    RUBY
  end

  describe "the target_ruby gate" do
    it "is silent without a target_ruby key" do
      expect(fired(module_form, target: nil)).to be_empty
    end

    it "is silent under target_ruby 4.0" do
      expect(fired(module_form, target: "4.0")).to be_empty
    end

    it "is silent under target_ruby latest, which names a parser rather than a runtime" do
      expect(fired(module_form, target: "latest")).to be_empty
    end

    it "reports under an explicit target_ruby 4.1, naming the removal version" do
      diagnostics = deprecations(module_form)
      expect(diagnostics.map { |d| [d.line, d.column] }).to eq([[2, 3]])
      expect(diagnostics.first.message).to eq(
        "`Module#ruby2_keywords' is deprecated since Ruby 4.1 and will be removed in Ruby 4.4 " \
        '(target_ruby: "4.1")'
      )
    end

    it "is a warning under balanced, info under lenient and an error under strict" do
      severities = %w[lenient balanced strict].map do |profile|
        deprecations(module_form, severity_profile: profile).map(&:severity)
      end
      expect(severities).to eq([[:info], [:warning], [:error]])
    end
  end

  describe "the reported forms" do
    it "reports Module#ruby2_keywords in a class, module, singleton-class or singleton-method body" do
      source = <<~RUBY
        class A
          ruby2_keywords :a
          self.ruby2_keywords :a
          def self.wrap = ruby2_keywords(:a)
          class << self
            ruby2_keywords :b
          end
          [1].each { ruby2_keywords :a }
        end
        module B
          ruby2_keywords :c
        end
        C = Class.new do
          ruby2_keywords :d
        end
      RUBY
      expect(fired(source)).to eq([2, 3, 4, 6, 8, 11, 14])
    end

    it "reports top-level ruby2_keywords outside any block" do
      source = "def fwd(*args) = args\nruby2_keywords :fwd\n"
      expect(deprecations(source).map(&:message)).to eq(
        ["`top-level ruby2_keywords' is deprecated since Ruby 4.1 and will be removed in Ruby 4.4 " \
         '(target_ruby: "4.1")']
      )
    end

    it "reports Proc#ruby2_keywords on a receiver typed Proc" do
      source = <<~RUBY
        pr = proc { |*args| args }
        pr.ruby2_keywords
        lambda { |*args| args }.ruby2_keywords
      RUBY
      expect(deprecations(source).map { |d| [d.line, d.message[/`[^']+'/]] })
        .to eq([[2, "`Proc#ruby2_keywords'"], [3, "`Proc#ruby2_keywords'"]])
    end

    it "reports the Hash methods with their 4.5 removal" do
      source = <<~RUBY
        Hash.ruby2_keywords_hash?({})
        ::Hash.ruby2_keywords_hash({})
      RUBY
      expect(deprecations(source).map(&:message)).to eq(
        [
          "`Hash.ruby2_keywords_hash?' is deprecated since Ruby 4.1 and will be removed in Ruby 4.5 " \
          '(target_ruby: "4.1")',
          "`Hash.ruby2_keywords_hash' is deprecated since Ruby 4.1 and will be removed in Ruby 4.5 " \
          '(target_ruby: "4.1")'
        ]
      )
    end

    it "reports the names through send with a literal Symbol" do
      source = <<~RUBY
        class A
          send(:ruby2_keywords, :a)
        end
        A.send(:ruby2_keywords, :a)
        A.__send__(:ruby2_keywords, :a)
        Hash.send(:ruby2_keywords_hash?, {})
      RUBY
      expect(fired(source)).to eq([2, 4, 5, 6])
    end
  end

  describe "where it declines" do
    it "does not judge an instance method, an instance_eval block or a top-level block" do
      source = <<~RUBY
        class A
          def call = ruby2_keywords(:a)
          Object.new.instance_eval { ruby2_keywords :a }
          Object.new.instance_exec { ruby2_keywords :a }
        end
        describe "x" do
          ruby2_keywords :a
        end
      RUBY
      expect(fired(source)).to be_empty
    end

    it "does not report a private Module#ruby2_keywords on an explicit receiver without send" do
      expect(fired("class A; end\nA.ruby2_keywords(:a)\n")).to be_empty
    end

    it "does not report a Hash-named class that is not Hash" do
      source = <<~RUBY
        module N
          class Hash; end
          Hash.ruby2_keywords_hash?({})
        end
      RUBY
      expect(fired(source)).to be_empty
    end

    it "is silenced by a project method of the same name anywhere" do
      source = <<~RUBY
        class Polyfill
          def self.ruby2_keywords(*) = nil
        end
        class A
          ruby2_keywords :a
        end
        Hash.ruby2_keywords_hash?({})
      RUBY
      expect(fired(source)).to eq([7])
    end

    it "reads a version guard against the stated Ruby" do
      source = <<~RUBY
        class A
          ruby2_keywords :a if RUBY_VERSION < "4.1"
          ruby2_keywords :b if RUBY_VERSION >= "2.7"
          if RUBY_VERSION >= "4.1"
            nil
          else
            ruby2_keywords :c
          end
          unless Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.1")
            ruby2_keywords :d
          end
          ruby2_keywords :e if RUBY_VERSION < "4.2"
        end
      RUBY
      expect(fired(source)).to eq([3, 12])
    end

    it "pads a two-segment target before comparing it as a String" do
      # `RUBY_VERSION` is "4.1.0" on Ruby 4.1, so `RUBY_VERSION > "4.1"` is true there.
      source = "class A\n  ruby2_keywords :a if RUBY_VERSION > \"4.1\"\nend\n"
      expect(fired(source)).to eq([2])
    end

    it "does not report under a guard it cannot decide, or after a guard that jumps away" do
      source = <<~RUBY
        class A
          ruby2_keywords :a if RUBY_VERSION >= "2.7" && RUBY_ENGINE == "ruby"
          RUBY_VERSION < "3.0" && ruby2_keywords(:b)
          case RUBY_VERSION
          when "4.1.0" then ruby2_keywords :c
          end
        end
        module B
          def self.setup
            return if RUBY_VERSION >= "3.0"

            ruby2_keywords :d
          end
        end
      RUBY
      expect(fired(source)).to be_empty
    end
  end

  describe Rigor::Analysis::CheckRules::RubyDeprecations do
    def diagnostics_for(source, stated)
      root = Prism.parse(source).value
      scope = Rigor::Scope.empty(environment: Rigor::Environment.new)
      index = Rigor::Inference::ScopeIndexer.index(root, default_scope: scope)
      described_class.diagnostics("x.rb", root, index, stated)
    end

    it "says the method was removed once the stated Ruby reaches the removal version" do
      messages = diagnostics_for("class A\n  ruby2_keywords :a\nend\nHash.ruby2_keywords_hash?({})\n",
                                 "4.4").map(&:message)
      expect(messages).to eq(
        [
          "`Module#ruby2_keywords' was removed in Ruby 4.4 (target_ruby: \"4.4\")",
          "`Hash.ruby2_keywords_hash?' is deprecated since Ruby 4.1 and will be removed in Ruby 4.5 " \
          '(target_ruby: "4.4")'
        ]
      )
    end

    it "is inactive without a stated Ruby, below 4.1, or for a malformed one" do
      expect([nil, "4.0", "3.4.1", "x"].map { |v| described_class.active?(v) }).to all(be(false))
      expect(%w[4.1 4.1.0 4.3].map { |v| described_class.active?(v) }).to all(be(true))
    end
  end

  it "is listed in the rule catalogue with its documentation anchor" do
    entry = Rigor::Analysis::RuleCatalog::ENTRIES.fetch(rule)
    expect(entry.severity_by_profile).to eq(lenient: :info, balanced: :warning, strict: :error)
    expect(File.read(File.expand_path("../../../../docs/manual/04-diagnostics.md", __dir__)))
      .to include(%(<a id="rule-call-deprecated-ruby2-keywords"></a>`#{rule}`))
  end
end
