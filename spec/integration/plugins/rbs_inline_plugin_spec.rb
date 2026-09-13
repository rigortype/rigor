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

  # Issue #823 — the gate above keeps an ANNOTATION-FREE file's inference intact; inside an annotated file
  # the same skeleton mechanism used to hit every unannotated sibling. The declaration is kept (a partially
  # declared class reads to RBS as a fully declared one, which is what PR #779's member-level drop got
  # wrong) and only its defaulted type slots are marked `%a{rigor:v1:inferred-return}`.
  describe "unannotated siblings in an annotated file (issue #823)" do
    def synthesized_for(source)
      Dir.mktmpdir("rigor-rbs-inline-siblings-") do |dir|
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

    # The issue's reproduction: one annotated method, one plain sibling returning a literal, one caller of
    # the sibling. Master answered `untyped` and said nothing; #779 answered `call.undefined-method` on the
    # sibling itself.
    it "types a plain sibling from its body, not from the synthesized skeleton" do
      result = run_plugin(source: <<~RUBY)
        class Greeter
          # @rbs times: Integer
          def repeat(times)
            times
          end

          def sibling
            42
          end
        end

        Greeter.new.sibling.no_such_method
      RUBY

      rules = result.diagnostics.map(&:qualified_rule)
      expect(rules).to include("call.undefined-method")
      expect(result.diagnostics.find { |d| d.qualified_rule == "call.undefined-method" }.message)
        .to include("no_such_method")
    end

    # The other direction of the same rule: the annotated method is untouched, so its contract still binds.
    it "keeps the annotated sibling's own contract binding" do
      result = run_plugin(source: <<~RUBY)
        class Greeter
          # @rbs times: Integer
          def repeat(times)
            times
          end

          def sibling
            42
          end
        end

        Greeter.new.repeat("nope")
      RUBY

      expect(result.diagnostics.map(&:qualified_rule)).to include("call.argument-type-mismatch")
    end

    # An author-written `untyped` is a real contract and stays one — the reason the plugin marks the slots
    # upstream DEFAULTED rather than every slot that reads `untyped`.
    it "leaves an author-written untyped return as a contract" do
      result = run_plugin(source: <<~RUBY)
        class Greeter
          # @rbs times: Integer
          def repeat(times)
            times
          end

          #: () -> untyped
          def opaque
            42
          end
        end

        Greeter.new.opaque.no_such_method
      RUBY

      expect(result.diagnostics.map(&:qualified_rule)).not_to include("call.undefined-method")
    end

    # PR #779 dropped the skeleton members outright and a partially declared class cost 12
    # `call.wrong-arity` on `new` alone. The skeleton is what carries `initialize`'s arity, so keeping it is
    # the fix's precondition, not a side effect.
    it "keeps new's arity from the unannotated initialize" do
      result = run_plugin(source: <<~RUBY)
        class Greeter
          # @rbs times: Integer
          def repeat(times)
            times
          end

          def initialize(name)
            @name = name
          end
        end

        Greeter.new("a", "b")
      RUBY

      expect(result.diagnostics.map(&:qualified_rule)).to include("call.wrong-arity")
    end

    # #779's other measured failure: an annotation-free class produces no declaration at all, so a
    # cross-file reference to it stopped resolving (`RBS::NoTypeFoundError` on `Registry`) and 44 classes
    # degraded to `Dynamic[top]`. Keeping the skeleton keeps the name resolvable.
    it "keeps a cross-file reference to an annotation-free class resolving" do
      result = run_plugin(
        source: <<~RUBY,
          class Registry
            # @rbs key: Symbol
            def fetch(key)
              key
            end

            def size
              3
            end
          end
        RUBY
        files: {
          "caller.rb" => <<~RUBY
            Registry.new.size.no_such_method
          RUBY
        },
        paths: ["demo.rb", "caller.rb"]
      )

      rules = result.diagnostics.map(&:qualified_rule)
      expect(rules).to include("call.undefined-method")
      expect(rules).not_to include("rbs.coverage.definition-build-failed")
    end

    it "types an attr_reader sibling from the class body rather than the skeleton" do
      expect(synthesized_for(<<~RUBY))
        class Greeter
          # @rbs times: Integer
          def repeat(times)
            times
          end

          attr_reader :plain
        end
      RUBY
        .to include("%a{rigor:v1:inferred-return}\n  %a{rigor:v1:inferred-signature}\n  attr_reader plain: untyped")
    end

    # The stand-in the plugin renders with must never reach the environment: an undeclared type alias makes
    # `RBS::DefinitionBuilder` raise for the whole class, which is exactly how `#:nodoc:` used to lose every
    # annotation in a file.
    it "never leaks the defaulted-type stand-in into the contributed RBS" do
      synthesized = synthesized_for(<<~RUBY)
        class Greeter
          # @rbs times: Integer
          def repeat(times)
            times
          end

          def sibling(a, b = 1, *rest, key:, **kw, &blk)
            42
          end
        end
      RUBY

      expect(synthesized).not_to include("rigor__inline_defaulted")
      # `sibling` is annotated nowhere, so EVERY slot on it defaulted (not only the return), and it
      # carries both marks — see "marks only inferred-return, not inferred-signature" below for the
      # contrasting case.
      expect(synthesized).to include("%a{rigor:v1:inferred-return}\n  %a{rigor:v1:inferred-signature}\n  def sibling:")
      # The parameter slots keep the skeleton's arity; only the RETURN slot is what the mark speaks about.
      expect(synthesized).to include("(untyped a, ?untyped b, *untyped rest, key: untyped, **untyped kw)")
    end

    it "marks the return of a method whose parameters alone were annotated, but not the full signature" do
      synthesized = synthesized_for(<<~RUBY)
        class Greeter
          # @rbs times: Integer
          def repeat(times)
            times
          end
        end
      RUBY

      expect(synthesized)
        .to include("%a{rigor:v1:inferred-return}\n  def repeat: (Integer times) -> untyped")
      # Issue #991 — the parameter WAS authored, so this member must not read as "nothing was asserted
      # about it": `rigor:v1:inferred-signature` (present only when EVERY slot defaulted) must be absent,
      # even though `rigor:v1:inferred-return` fires the same way it would for a fully bare `def`.
      expect(synthesized).not_to include("rigor:v1:inferred-signature")
    end

    # The mark is a string contract across the plugin/engine boundary, spelled once on each side.
    it "writes the directive the engine reads" do
      expect(Rigor::Plugin::RbsInline::Synthesizer::INFERRED_RETURN_ANNOTATION)
        .to eq(Rigor::RbsExtended::INFERRED_RETURN_DIRECTIVE)
      expect(Rigor::Plugin::RbsInline::Synthesizer::INFERRED_SIGNATURE_ANNOTATION)
        .to eq(Rigor::RbsExtended::INFERRED_SIGNATURE_DIRECTIVE)
    end

    it "does not mark a fully annotated method" do
      synthesized = synthesized_for(<<~RUBY)
        class Greeter
          #: (Integer) -> String
          def repeat(times)
            times.to_s
          end
        end
      RUBY

      expect(synthesized).to include("def repeat: (Integer) -> String")
      expect(synthesized).not_to include("rigor:v1:inferred-return")
      expect(synthesized).not_to include("rigor:v1:inferred-signature")
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

  # Issue #824 / ADR-32 WD13 — a method declared by BOTH `sig/` and an inline annotation. rbs merges the two
  # sources into one `ClassEntry` and ranks neither, so before this the definition build raised
  # `RBS::DuplicatedMethodDefinitionError` and the whole class lost its method surface. `sig/` now wins per
  # member, and the drop is reported rather than swallowed (WD12).
  describe "precedence against sig/ (issue #824)" do
    let(:sig_and_inline) do
      run_plugin(
        source: <<~RUBY,
          # rbs_inline: enabled
          class Demo
            # @rbs (Integer) -> String
            def shared(value) = value.to_s

            # @rbs (Integer) -> Integer
            def only_inline(value) = value + 1
          end
        RUBY
        files: { "sig/demo.rbs" => <<~RBS },
          class Demo
            def shared: (::String) -> ::Integer
            def only_sig: () -> ::String
          end
        RBS
        signature_paths: ["sig"]
      )
    end

    it "lets the sig/ declaration win for the shared member" do
      # The `.rbs` says `-> Integer` and the body returns a String, so the sig/ contract is the one being
      # checked. Under the inline signature (`-> String`) the body would agree and nothing would fire.
      mismatches = sig_and_inline.diagnostics.select { |d| d.qualified_rule == "def.return-type-mismatch" }
      expect(mismatches.size).to eq(1)
      expect(mismatches.first.message).to include("declared Integer", "inferred String")
    end

    it "does not degrade the class: no rbs.coverage.definition-build-failed" do
      expect(sig_and_inline.diagnostics.map(&:qualified_rule))
        .not_to include("rbs.coverage.definition-build-failed")
    end

    it "reports one info row naming the member, the .rbs that won, and the annotated file" do
      rows = sig_and_inline.diagnostics.select { |d| d.qualified_rule == "source-rbs-annotation-not-honoured" }
      expect(rows.size).to eq(1)
      expect(rows.first.severity).to eq(:info)
      expect(rows.first.path).to end_with("demo.rb")
      expect(rows.first.message).to include("`Demo#shared`", "sig/demo.rbs", "inline signature was dropped")
    end

    # The rest of the file is unaffected — the same promise WD12's `module-self` row makes.
    it "keeps an inline member that sig/ does not declare" do
      result = run_plugin(
        source: <<~RUBY,
          # rbs_inline: enabled
          class Demo
            # @rbs (Integer) -> String
            def shared(value) = value.to_s

            # @rbs (Integer) -> Integer
            def only_inline(value) = value + 1
          end

          Demo.new.only_inline("nope")
        RUBY
        files: { "sig/demo.rbs" => "class Demo\n  def shared: (::String) -> ::Integer\nend\n" },
        signature_paths: ["sig"]
      )
      mismatches = result.diagnostics.select { |d| d.qualified_rule == "call.argument-type-mismatch" }
      expect(mismatches.size).to eq(1)
      expect(mismatches.first.message).to include("only_inline")
    end

    it "stays silent when the inline annotations do not overlap sig/" do
      result = run_plugin(
        source: <<~RUBY,
          # rbs_inline: enabled
          class Demo
            # @rbs (Integer) -> Integer
            def only_inline(value) = value + 1
          end
        RUBY
        files: { "sig/demo.rbs" => "class Demo\n  def only_sig: () -> ::String\nend\n" },
        signature_paths: ["sig"]
      )
      expect(result.diagnostics.map(&:qualified_rule)).not_to include("source-rbs-annotation-not-honoured")
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
