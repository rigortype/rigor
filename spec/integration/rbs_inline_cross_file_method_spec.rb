# frozen_string_literal: true

# Issue #1934 — a class `rigor-rbs-inline` declares is the project's own, as a `sig/` sidecar is (#735).
#
# `alias_method :title, :label` in an annotated file, called from another file, reported
# `call.undefined-method` with the ADR-17 `pre_eval:` advice although Ruby defines `Shop#title`. The alias
# itself was recorded; what went wrong is whose RBS the class had. Upstream rbs-inline translates the `alias`
# keyword and not `alias_method`, so the synthesized declaration lacked `title`, and the #735 suppression
# that keeps a project's second file of its own class from reading as a monkey-patch counted only `sig/`
# declarations as the project's. A plain `def` in a sibling file of the same class drew the same report.
#
# Mutations of `RbsLoader#inline_only_entry?` this file and the loader spec kill:
#
# | Mutation                                                   | Killed by                                         |
# | ---------------------------------------------------------- | ------------------------------------------------- |
# | an inline-only class never counts (the pre-fix reading)    | "does not report the project's own methods"       |
# | one inline declaration suffices (`all?` read as `any?`)    | "still reports a cross-file def on String"        |
#
# The typo, singleton-typo and declared-contract rows are the must-still-fire arms: the suppression answers for
# methods the project defines, and an argument check on a declared member is untouched.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "an rbs-inline class and the project's other definitions on it (#1934)" do
  def write_project
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "shop.rb"), shop_source)
    File.write(File.join("lib", "shop_ext.rb"), sibling_source)
    File.write(File.join("lib", "probe.rb"), probe_source)
  end

  def shop_source
    <<~RUBY
      # rbs_inline: enabled

      class Shop
        #: (Integer n) -> String
        def label(n) = n.to_s

        #: () -> Integer
        def size = 1

        def plain(a) = a

        alias_method :title, :label
        alias_method "heading", "label"
        alias_method :str, :to_s
        alias_method :plain2, :plain
        alias_method :size, :label

        class << self
          def make = new
          alias_method :build, :make
        end
      end

      class String
        #: () -> String
        def yell = upcase
      end
    RUBY
  end

  def sibling_source
    <<~RUBY
      class Shop
        def extra = 1
        alias_method :caption, :label
      end

      class String
        def shout = upcase
      end
    RUBY
  end

  def probe_source
    <<~RUBY
      class Probe
        def symbol_alias = Shop.new.title(1)
        def string_alias = Shop.new.heading(1)
        def inherited_alias = Shop.new.str
        def unannotated_alias = Shop.new.plain2(1)
        def declared_name_alias = Shop.new.size
        def singleton_alias = Shop.build
        def sibling_alias = Shop.new.caption(1)
        def sibling_def = Shop.new.extra
        def typo = Shop.new.nope
        def singleton_typo = Shop.nope_s
        def bundled_patch = "x".shout
        def bundled_inline = "x".yell
        def declared_contract = Shop.new.label("x")
        def sibling_arity = Shop.new.extra(1)
      end
    RUBY
  end

  # Requires and registers the bundled plugin from source; see `arity_declared_source_method_spec.rb`.
  def require_rbs_inline_plugin
    plugin_lib = File.expand_path("../../plugins/rigor-rbs-inline/lib", __dir__)
    $LOAD_PATH.unshift(plugin_lib) unless $LOAD_PATH.include?(plugin_lib)
    require "rigor-rbs-inline"
    Rigor::Plugin.unregister!
    lambda do |_name|
      Rigor::Plugin.register(Rigor::Plugin::RbsInline)
      true
    end
  end

  def run_check
    plugin_requirer = require_rbs_inline_plugin
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => %w[lib], "workers" => 0,
        "plugins" => [{ "gem" => "rigor-rbs-inline", "id" => "rbs-inline" }]
      )
    )
    guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil, plugin_requirer: plugin_requirer),
      %w[lib]
    )
  end

  def rows(result)
    result.diagnostics.select { |d| d.path.end_with?("probe.rb") }.map { |d| [d.line, d.qualified_rule] }
  end

  around do |example|
    Dir.mktmpdir("rigor-rbs-inline-cross-file-") { |dir| Dir.chdir(dir) { example.run } }
  ensure
    Rigor::Plugin.unregister!
  end

  let(:result) do
    write_project
    run_check
  end

  it "does not report the project's own methods on the class, whichever way they are defined" do
    # Lines 2-9: symbol and string `alias_method`, an alias of an inherited method and of an unannotated `def`,
    # an alias onto a name the inline RBS declares (its declared `size` stands), `class << self`, and an
    # `alias_method` or a `def` in a sibling file.
    expect(rows(result).map(&:first)).not_to include(2, 3, 4, 5, 6, 7, 8, 9)
  end

  it "still reports a name nobody defines, on either side" do
    expect(rows(result)).to include([10, "call.undefined-method"], [11, "call.undefined-method"])
  end

  it "still reports a cross-file def on String, which an inline file reopens but bundled RBS declares" do
    shout = result.diagnostics.find { |d| d.line == 12 && d.path.end_with?("probe.rb") }
    expect(shout&.message).to include("the project defines `String#shout' at lib/shop_ext.rb:7", "(ADR-17)")
    expect(rows(result)).not_to include([13, "call.undefined-method"])
  end

  it "keeps checking a declared method's contract" do
    expect(rows(result)).to include([14, "call.argument-type-mismatch"])
  end

  # The other reader of the same answer: a project `def` no member declares is checked against its own
  # positional envelope on a project-declared class (#992), as on a `sig/` one. `extra` takes none.
  it "checks a sibling def's arity against its own envelope" do
    expect(rows(result)).to include([15, "call.wrong-arity"])
  end

  it "reports nothing else" do
    expect(rows(result)).to contain_exactly(
      [10, "call.undefined-method"], [11, "call.undefined-method"], [12, "call.undefined-method"],
      [14, "call.argument-type-mismatch"], [15, "call.wrong-arity"]
    )
  end
end
