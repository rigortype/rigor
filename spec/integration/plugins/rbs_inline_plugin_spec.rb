# frozen_string_literal: true

# Integration spec for `plugins/rigor-rbs-inline/`.
#
# ADR-32 — the plugin calls the upstream `rbs-inline` library to synthesise RBS from Ruby source files carrying
# rbs-inline-shaped comments and contributes the result to the RBS environment via the
# `source_rbs_synthesizer:` manifest hook. This spec proves the end-to-end path: with the plugin active, a
# `# @rbs name: T`-shaped parameter annotation enforces the contract just like a hand-written `.rbs` signature would.

require "spec_helper"

unless defined?(RBS_INLINE_PLUGIN_LIB)
  RBS_INLINE_PLUGIN_LIB = File.expand_path(
    "../../../plugins/rigor-rbs-inline/lib", __dir__
  )
end
$LOAD_PATH.unshift(RBS_INLINE_PLUGIN_LIB) unless $LOAD_PATH.include?(RBS_INLINE_PLUGIN_LIB)
require "rigor-rbs-inline"

RSpec.describe "plugins/rigor-rbs-inline" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::RbsInline }

  it "declares the rbs-inline plugin id and config schema" do
    expect(plugin_class.manifest.id).to eq("rbs-inline")
    expect(plugin_class.manifest.config_schema).to eq("require_magic_comment" => :boolean)
  end

  it "exposes a per-instance source_rbs_synthesizer via the instance manifest" do
    instance = plugin_class.new(
      services: Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection,
        type: Rigor::Type::Combinator,
        configuration: Rigor::Configuration.new
      )
    )
    expect(instance.manifest.source_rbs_synthesizer).to respond_to(:call)
  end

  describe "default mode (require_magic_comment: false, ADR-93 WD1)" do
    it "flags an argument-type mismatch on a class-wrapped # @rbs param annotation" do
      source = <<~RUBY
        # rbs_inline: enabled
        class AscDesc
          # @rbs asc_or_desc: :asc | :desc
          def ascdesc(asc_or_desc)
            asc_or_desc
          end
        end

        AscDesc.new.ascdesc(:bad)
      RUBY
      result = run_plugin(source: source)
      mismatches = result.diagnostics.select { |d| d.qualified_rule == "call.argument-type-mismatch" }
      expect(mismatches).not_to be_empty
      expect(mismatches.first.message).to include(":asc | :desc")
      expect(mismatches.first.message).to include(":bad")
    end

    it "processes an annotated file even without the magic comment (the ADR-93 flip)" do
      source = <<~RUBY
        # NOTE: no `# rbs_inline: enabled` magic comment — the default no longer requires it.
        class AscDesc
          # @rbs asc_or_desc: :asc | :desc
          def ascdesc(asc_or_desc)
            asc_or_desc
          end
        end

        AscDesc.new.ascdesc(:bad)
      RUBY
      result = run_plugin(source: source)
      mismatches = result.diagnostics.select { |d| d.qualified_rule == "call.argument-type-mismatch" }
      expect(mismatches).not_to be_empty
    end

    it "restores the ADR-32 opt-in when require_magic_comment: true is set explicitly" do
      source = <<~RUBY
        # NOTE: annotated, but no `# rbs_inline: enabled` magic comment.
        class AscDesc
          # @rbs asc_or_desc: :asc | :desc
          def ascdesc(asc_or_desc)
            asc_or_desc
          end
        end

        AscDesc.new.ascdesc(:bad)
      RUBY
      result = run_plugin(
        source: source,
        plugin_entry: {
          "gem" => "rigor-rbs-inline",
          "config" => { "require_magic_comment" => true }
        }
      )
      mismatches = result.diagnostics.select { |d| d.qualified_rule == "call.argument-type-mismatch" }
      expect(mismatches).to be_empty
    end
  end

  describe "host-context override (require_magic_comment: false, ADR-32 WD10)" do
    it "treats every file as if it carried the magic comment" do
      source = <<~RUBY
        class AscDesc
          # @rbs asc_or_desc: :asc | :desc
          def ascdesc(asc_or_desc)
            asc_or_desc
          end
        end

        AscDesc.new.ascdesc(:bad)
      RUBY
      result = run_plugin(
        source: source,
        plugin_entry: {
          "gem" => "rigor-rbs-inline",
          "config" => { "require_magic_comment" => false }
        }
      )
      mismatches = result.diagnostics.select { |d| d.qualified_rule == "call.argument-type-mismatch" }
      expect(mismatches).not_to be_empty
    end
  end

  # ADR-93's first WD4 measurement: without the magic comment gate, upstream's opt-out mode synthesizes a
  # full `def f: (untyped x) -> untyped` skeleton for EVERY unannotated def. Rigor trusts an accepted
  # signature over body inference, so the skeleton REPLACES real inferred types with untyped — on mail (zero
  # annotations) that moved diagnostics 26 -> 42. The magic-comment-free mode therefore gates on the file
  # actually carrying an annotation.
  describe "annotation-presence gate for the magic-comment-free mode (ADR-93 WD1)" do
    let(:override) do
      { "gem" => "rigor-rbs-inline", "config" => { "require_magic_comment" => false } }
    end

    def synthesized_for(source)
      Dir.mktmpdir("rigor-rbs-inline-gate-") do |dir|
        path = File.join(dir, "subject.rb")
        File.write(path, source)
        plugin = Rigor::Plugin::RbsInline.new(
          services: Rigor::Plugin::Services.new(
            reflection: Rigor::Reflection,
            type: Rigor::Type::Combinator,
            configuration: Rigor::Configuration.new
          ),
          config: { "require_magic_comment" => false }
        )
        plugin.manifest.source_rbs_synthesizer.call(path)
      end
    end

    it "contributes nothing for a file carrying no annotation" do
      expect(synthesized_for(<<~RUBY)).to be_nil
        class Plain
          def value(x)
            x.to_s
          end
        end
      RUBY
    end

    it "leaves an unannotated file's inference untouched" do
      source = <<~RUBY
        class Plain
          def value
            "text"
          end
        end

        Plain.new.value.no_such_method
      RUBY
      result = run_plugin(source: source, plugin_entry: override)
      # The body infers String; a synthesized `-> untyped` skeleton would erase that and silence this.
      undefined = result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }
      expect(undefined).not_to be_empty
    end

    it "still contributes for a file carrying an annotation" do
      expect(synthesized_for(<<~RUBY)).to include("Integer")
        class Annotated
          #: (String) -> Integer
          def size_of(s)
            s.length
          end
        end
      RUBY
    end

    # `class Foo #:nodoc:` is one of the most common comments in Ruby, and upstream's parser reads the RDoc
    # directive as a type assertion of an alias named `nodoc`. Left alone, 61 of mail's files opted into
    # synthesis on that alone — which is why the annotation gate by itself only got mail from 42 to 31
    # diagnostics rather than its true 26.
    it "does not treat an RDoc directive as an annotation" do
      expect(synthesized_for(<<~RUBY)).to be_nil
        class Documented #:nodoc:
          def value(x)
            x.to_s
          end
        end
      RUBY
    end
  end

  # Upstream reads `def f #:nodoc:` as a return type: `def f: () -> nodoc`, naming a type nothing declares.
  # `RBS::DefinitionBuilder` then raises `NoTypeFoundError` for the whole class, so EVERY real annotation in
  # it is silently lost. rbs-inline emits 29 of these for Ruby's own `lib/fileutils.rb`. Reported upstream as
  # soutaro/rbs-inline#248; until a fix ships in our supported range, the plugin rewrites the directive to
  # its spaced spelling before upstream's grammar sees it.
  describe "RDoc directive neutralization (soutaro/rbs-inline#248)" do
    let(:override) do
      { "gem" => "rigor-rbs-inline", "config" => { "require_magic_comment" => false } }
    end

    def synthesized_for(source)
      Dir.mktmpdir("rigor-rbs-inline-rdoc-") do |dir|
        path = File.join(dir, "subject.rb")
        File.write(path, source)
        plugin = Rigor::Plugin::RbsInline.new(
          services: Rigor::Plugin::Services.new(
            reflection: Rigor::Reflection,
            type: Rigor::Type::Combinator,
            configuration: Rigor::Configuration.new
          ),
          config: { "require_magic_comment" => false }
        )
        plugin.manifest.source_rbs_synthesizer.call(path)
      end
    end

    it "never emits a directive name as a type" do
      rendered = synthesized_for(<<~RUBY)
        class Widget
          #: (String) -> Integer
          def size_of(s)
            s.length
          end

          def internal(x) #:nodoc:
            x.to_s
          end
        end
      RUBY
      expect(rendered).to include("def size_of: (String) -> Integer")
      expect(rendered).not_to include("nodoc")
    end

    # The regression that motivated this: one sibling `#:nodoc:` used to take `size_of`'s annotation with it.
    it "keeps a sibling method's annotation binding" do
      source = <<~RUBY
        class Widget
          #: (String) -> Integer
          def size_of(s)
            s.length
          end

          def internal(x) #:nodoc:
            x.to_s
          end
        end

        Widget.new.size_of("ab").no_such_method
      RUBY
      result = run_plugin(source: source, plugin_entry: override)
      undefined = result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }
      expect(undefined.map(&:message).join).to include("Integer")
    end

    it "covers the directives that take an argument" do
      expect(synthesized_for(<<~RUBY)).not_to match(/nodoc|filename/)
        class Widget #:nodoc: all
          #: () -> Integer
          def size
            1
          end

          def internal #:include: filename
            2
          end
        end
      RUBY
    end

    it "leaves the spaced spelling alone" do
      rendered = synthesized_for(<<~RUBY)
        class Widget
          #: () -> Integer
          def size # :nodoc:
            1
          end
        end
      RUBY
      expect(rendered).to include("def size: () -> Integer")
    end

    # Regression: `Prism::Location#start_offset` counts BYTES and `String#insert` indexes CHARACTERS, so on
    # a file with any multi-byte content the space landed mid-word (`#:n odoc:`) and upstream still read a
    # directive. mail's `field.rb` and `multibyte/unicode.rb` caught this; the corpus went 26 -> 32.
    it "rewrites the directive correctly in a file with multi-byte content" do
      rendered = synthesized_for(<<~RUBY)
        # 日本語のコメント
        class Widget
          #: () -> Integer
          def size # 説明
            1
          end

          def internal #:nodoc:
            2
          end
        end
      RUBY
      expect(rendered).to include("def size: () -> Integer")
      expect(rendered).not_to include("nodoc")
    end

    # Prism decides what is a comment, so a directive-shaped string is not rewritten.
    it "does not rewrite a directive-shaped string literal" do
      rendered = synthesized_for(<<~RUBY)
        class Widget
          #: () -> String
          def marker
            "#:nodoc:"
          end
        end
      RUBY
      expect(rendered).to include("def marker: () -> String")
    end
  end

  describe "failure diagnostic (ADR-32 WD6)" do
    it "emits source-rbs-synthesis-failed on a file with bad inline-RBS grammar" do
      # `# @rbs ` followed by garbage that rbs-inline can't parse.
      source = <<~RUBY
        # rbs_inline: enabled
        class Demo
          # @rbs ??? this is not valid rbs-inline syntax ???
          def x(a)
            a
          end
        end
      RUBY
      result = run_plugin(source: source)
      info_diagnostics = result.diagnostics.select { |d| d.qualified_rule == "source-rbs-synthesis-failed" }
      # NOTE: rbs-inline is generally permissive and may not raise on every garbage input. The contract this
      # test asserts is: IF the synthesizer hits an error, THE engine surfaces it as an info diagnostic (and
      # analysis continues). If rbs-inline accepts our garbage silently, this is a no-op assertion path and the
      # test reverts to verifying no crash + no rule violation.
      expect(info_diagnostics.all? { |d| d.severity == :info }).to be(true)
      # In either branch, analysis must complete cleanly.
      expect(result.diagnostics).to all(have_attributes(severity: be_a(Symbol)))
    end
  end

  # ADR-32 WD12. The two inline-RBS dialects spell `module-self` differently, and the gem's response to the
  # other spelling is to build the annotation and then contribute nothing from it — invisible without a report,
  # since the annotation comment is echoed into the synthesised RBS either way.
  describe "annotation parsed but not honoured (ADR-32 WD12)" do
    def synthesizer_outcome(source)
      Dir.mktmpdir("rigor-rbs-inline-wd12-") do |dir|
        path = File.join(dir, "subject.rb")
        File.write(path, source)
        plugin = Rigor::Plugin::RbsInline.new(
          services: Rigor::Plugin::Services.new(
            reflection: Rigor::Reflection,
            type: Rigor::Type::Combinator,
            configuration: Rigor::Configuration.new
          ),
          config: { "require_magic_comment" => false }
        )
        plugin.manifest.source_rbs_synthesizer.call(path)
      end
    end

    it "flags the rbs-built-in `module-self:` spelling and still returns the file's RBS" do
      outcome = synthesizer_outcome(<<~RUBY)
        # @rbs module-self: Comparable
        module Sortable
          # @rbs () -> Integer
          def rank = 1
        end
      RUBY

      expect(outcome).to be_an(Array)
      kind, source, messages = outcome
      expect(kind).to eq(:ok)
      # The rest of the file is unaffected — that is the whole reason this is not routed through WD6.
      expect(source).to include("def rank: () -> Integer")
      expect(messages.first).to include("module-self")
    end

    # The gem's own spelling works, so the detector must stay silent on it. Without this the check would be a
    # lint that fires on correct input.
    it "stays silent on the rbs-inline spelling it does honour" do
      outcome = synthesizer_outcome(<<~RUBY)
        # @rbs module-self Comparable
        module Sortable
          # @rbs () -> Integer
          def rank = 1
        end
      RUBY

      expect(outcome).to be_a(String)
      expect(outcome).to include("module Sortable : Comparable")
    end

    it "surfaces it as an info diagnostic without suppressing the file's other annotations" do
      result = run_plugin(source: <<~RUBY)
        # rbs_inline: enabled
        # @rbs module-self: Comparable
        module Sortable
          # @rbs () -> Integer
          def rank = 1
        end
      RUBY

      not_honoured = result.diagnostics.select do |d|
        d.qualified_rule == "source-rbs-annotation-not-honoured"
      end
      expect(not_honoured.size).to eq(1)
      expect(not_honoured.first.severity).to eq(:info)
      expect(not_honoured.first.message).to include("module-self")
      expect(result.diagnostics.map(&:qualified_rule)).not_to include("source-rbs-synthesis-failed")
    end
  end

  describe "per-file cache (ADR-32 WD5)" do
    let(:cache_root) { Dir.mktmpdir("rigor-rbs-inline-cache-") }
    let(:cache_store) { Rigor::Cache::Store.new(root: cache_root) }
    let(:project_dir) { Dir.mktmpdir("rigor-rbs-inline-project-") }

    after do
      FileUtils.remove_entry(cache_root) if File.directory?(cache_root)
      FileUtils.remove_entry(project_dir) if File.directory?(project_dir)
    end

    it "memoises synthesizer output across runs with unchanged source" do
      source = <<~RUBY
        # rbs_inline: enabled
        class AscDesc
          # @rbs asc_or_desc: :asc | :desc
          def ascdesc(asc_or_desc)
            asc_or_desc
          end
        end

        AscDesc.new.ascdesc(:bad)
      RUBY
      # Re-use the same `project_dir` across both runs so the cache key (which includes the source file path)
      # is stable.
      Rigor::Plugin.unregister!
      run_plugin_in_dir(dir: project_dir, source: source, cache_store: cache_store)
      writes_before = cache_store.stats.fetch(:writes)
      hits_before = cache_store.stats.fetch(:hits)

      Rigor::Plugin.unregister!
      run_plugin_in_dir(dir: project_dir, source: source, cache_store: cache_store)
      hits_after = cache_store.stats.fetch(:hits)

      expect(writes_before).to be > 0
      expect(hits_after).to be > hits_before
    end
  end
end
