# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Issue #1002 — sig-gen renders a project-declared type alias in place of the union that alias expands to.
#
# Every example drives the whole {Rigor::SigGen::Generator}, not {Rigor::SigGen::AliasIndex} in isolation:
# the fold lives in `Generator#elaborated_rbs`, the one seam `--print`, `--diff`, `--write` and
# `--format=json` all read through, and a spec that bypassed it would stop proving the forms agree.
#
# The union under test is `:deprecated | :experimental | :performance` on purpose. Core RBS declares
# `Warning::category` with exactly that expansion, so the same fixture that proves a PROJECT alias folds also
# proves a core/stdlib alias does not.
RSpec.describe "sig-gen alias rendering" do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  def three_symbol_method
    <<~RUBY
      class Warner
        def category(n)
          case n
          when 0 then :deprecated
          when 1 then :experimental
          else :performance
          end
        end
      end
    RUBY
  end

  def full_union
    "def category: (untyped) -> (:deprecated | :experimental | :performance)"
  end

  def write(rel_path, contents)
    full = File.join(tmpdir, rel_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, contents)
    full
  end

  # @param signatures — `{ relative sig path => RBS source }`. `nil` configures no `signature_paths:` at all,
  #   which is the shape an adopting project has before it writes any RBS.
  def configuration_for(signatures, bundler: nil)
    paths = [File.join(tmpdir, "lib")]
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        {
          "paths" => paths,
          "signature_paths" => signatures.nil? ? nil : [File.join(tmpdir, "sig")],
          "bundler" => bundler
        }.compact
      )
    )
  end

  def rendered_return(signatures, ruby: three_symbol_method, method_name: :category, bundler: nil)
    write("lib/warner.rb", ruby)
    signatures&.each { |rel, body| write(File.join("sig", rel), body) }
    configuration = configuration_for(signatures, bundler: bundler)
    paths = [File.join(tmpdir, "lib")]
    candidates = Rigor::SigGen::Generator.new(configuration: configuration, paths: paths).run
    candidates.find { |c| c.method_name == method_name }.rbs
  end

  # The same alias, declared one namespace deeper than the `Deep::mood` the neighbouring examples use.
  def nested_alias_declaration
    <<~RBS
      module Deep
        module Inner
          type mood = :deprecated | :experimental | :performance
        end
      end
    RBS
  end

  def nested_three_symbol_method
    <<~RUBY
      module Deep
        module Inner
          class Warner
            def category(n)
              case n
              when 0 then :deprecated
              when 1 then :experimental
              else :performance
              end
            end
          end
        end
      end
    RUBY
  end

  # `Integer | String` rather than a literal union, so an alias body can be spelled with class instances.
  def integer_or_string_method
    <<~RUBY
      class Warner
        def widened(n)
          n.zero? ? Integer.sqrt(4) : String.new
        end
      end
    RUBY
  end

  it "renders the alias when the inferred union is exactly the alias's expansion" do
    rbs = rendered_return({ "warner.rbs" => "type mood = :deprecated | :experimental | :performance\n" })

    expect(rbs).to eq("def category: (untyped) -> ::mood")
  end

  # Member-set equality, not textual similarity: dropping one arm makes the proposal a different type, and
  # naming the alias there would claim a return the method cannot produce.
  it "renders the union in full when it is missing one of the alias's members" do
    two_arm = <<~RUBY
      class Warner
        def category(n)
          n.zero? ? :deprecated : :experimental
        end
      end
    RUBY

    rbs = rendered_return({ "warner.rbs" => "type mood = :deprecated | :experimental | :performance\n" },
                          ruby: two_arm)

    expect(rbs).to eq("def category: (untyped) -> (:deprecated | :experimental)")
  end

  # The scope rule. Core RBS's `Warning::category` expands to this exact member set; an author who never
  # declared an alias must not find a core one in their proposal.
  it "ignores a core / stdlib alias with the same expansion" do
    rbs = rendered_return({ "warner.rbs" => "class Warner\nend\n" })

    expect(rbs).to eq(full_union)
  end

  # Criterion: a project with no aliases renders byte-identically to the pre-#1002 output.
  it "renders byte-identically for a project with no signature_paths at all" do
    expect(rendered_return(nil)).to eq(full_union)
  end

  # Ambiguity rule, pinned: the winner is the alias whose DECLARATION POSITION sorts first by
  # (declaration file path, start line, fully-qualified name). Nothing about the order
  # `RbsLoader#each_type_alias_decl` happens to yield — an `RBS::Environment` Hash — is consulted, so the
  # winner is the same on every run. Here `a_first.rbs` sorts before `z_second.rbs`.
  it "resolves two aliases with the same expansion by declaration file order" do
    rbs = rendered_return(
      { "z_second.rbs" => "type late = :deprecated | :experimental | :performance\n",
        "a_first.rbs" => "type early = :deprecated | :experimental | :performance\n" }
    )

    expect(rbs).to eq("def category: (untyped) -> ::early")
  end

  it "resolves two aliases declared in the same file by line order" do
    rbs = rendered_return(
      { "warner.rbs" => <<~RBS }
        type upper = :deprecated | :experimental | :performance

        type lower = :deprecated | :experimental | :performance
      RBS
    )

    expect(rbs).to eq("def category: (untyped) -> ::upper")
  end

  # A single-type alias is never folded: doing so would rewrite every ordinary `String` return in a project
  # that happens to name one, which is noise rather than the long-union noise #1002 is about.
  it "does not fold an alias whose expansion is a single type" do
    single = <<~RUBY
      class Warner
        def category(_n)
          :deprecated
        end
      end
    RUBY

    rbs = rendered_return({ "warner.rbs" => "type only = :deprecated\n" }, ruby: single)

    expect(rbs).to eq("def category: (untyped) -> :deprecated")
  end

  # A generic alias has no fixed member set to key on, so it is skipped — and skipping it must not disturb
  # the non-generic alias declared beside it.
  it "skips a generic alias without disturbing a neighbouring fold" do
    rbs = rendered_return(
      { "warner.rbs" => <<~RBS }
        type boxed[T] = T | nil

        type mood = :deprecated | :experimental | :performance
      RBS
    )

    expect(rbs).to eq("def category: (untyped) -> ::mood")
  end

  # Issue #1002 review: the scope must be the project's OWN resolved `signature_paths:`, not the RBS loader's,
  # which also carries plugin signature paths, the `rbs collection` tree, Rigor's gem overlays and — as this
  # example asserts before it renders anything — every `sig/` directory discovered under the project's bundle.
  it "ignores an alias shipped by a gem in the project's own bundle" do
    gem_sig = File.join("vendor", "bundle", "ruby", "3.4.0", "gems", "faux-1.0.0", "sig", "faux.rbs")
    write(gem_sig, "type mood = :deprecated | :experimental | :performance\n")
    bundler = { "bundle_path" => File.join(tmpdir, "vendor", "bundle"),
                "auto_detect" => false, "lockfile" => nil }
    write("lib/warner.rb", three_symbol_method)
    write(File.join("sig", "warner.rbs"), "class Warner\nend\n")
    configuration = configuration_for({}, bundler: bundler)
    environment = Rigor::ProjectEnvironment.build(configuration: configuration, source_files: [])

    expect(environment.rbs_loader.signature_paths.map(&:to_s)).to include(a_string_including("faux-1.0.0"))

    rbs = rendered_return({ "warner.rbs" => "class Warner\nend\n" }, bundler: bundler)

    expect(rbs).to eq(full_union)
  end

  # Erasure is not injective. `(Integer & Comparable) | String` reaches the renderer indistinguishable from
  # `Integer | String`, so folding into it would put an intersection in the author's signature that the method
  # never returns. The companion example below proves the fixture really does reach the fold path.
  it "does not fold an alias whose body carries an intersection" do
    rbs = rendered_return({ "warner.rbs" => "type inter = (Integer & Comparable) | String\n" },
                          ruby: integer_or_string_method, method_name: :widened)

    expect(rbs).to eq("def widened: (untyped) -> (Integer | String)")
  end

  it "folds the same shape when the alias body carries no lossy form" do
    rbs = rendered_return({ "warner.rbs" => "type both = Integer | String\n" },
                          ruby: integer_or_string_method, method_name: :widened)

    expect(rbs).to eq("def widened: (untyped) -> ::both")
  end

  # A proc type translates to a bare `Proc`, losing the signature, so the same reasoning applies.
  it "does not fold an alias whose body carries a proc type" do
    proc_or_string = <<~RUBY
      class Warner
        def handler(n)
          n.zero? ? ->(x) { x } : String.new
        end
      end
    RUBY

    rbs = rendered_return({ "warner.rbs" => "type cb = ^(Integer) -> void | String\n" },
                          ruby: proc_or_string, method_name: :handler)

    expect(rbs).to eq("def handler: (untyped) -> (Proc | String)")
  end

  # Namespace proximity. Type equality alone picks names no reader expects: `:positive | :negative` is
  # type-equal to this repository's own `Analysis::FactStore::polarity` from anywhere in the tree.
  it "ignores an alias declared in a namespace that does not enclose the method's owner" do
    rbs = rendered_return(
      { "warner.rbs" => <<~RBS }
        module Elsewhere
          type mood = :deprecated | :experimental | :performance
        end
      RBS
    )

    expect(rbs).to eq(full_union)
  end

  it "folds an alias declared in an enclosing namespace of the method's owner" do
    nested = nested_three_symbol_method
    sig = <<~RBS
      module Deep
        type mood = :deprecated | :experimental | :performance
      end
    RBS
    rbs = rendered_return({ "warner.rbs" => sig }, ruby: nested)

    expect(rbs).to eq("def category: (untyped) -> ::Deep::mood")
  end

  # "Most specific, then declaration order": the nearer alias wins even though the farther one is declared in
  # a file that sorts first, which is the tie-break that decides between two EQUALLY near aliases.
  it "prefers the nearest enclosing namespace over an earlier-declared outer alias" do
    nested = <<~RUBY
      module Deep
        module Inner
          class Warner
            def category(n)
              case n
              when 0 then :deprecated
              when 1 then :experimental
              else :performance
              end
            end
          end
        end
      end
    RUBY

    rbs = rendered_return(
      { "a_outer.rbs" => "type mood = :deprecated | :experimental | :performance\n",
        "z_inner.rbs" => nested_alias_declaration },
      ruby: nested
    )

    expect(rbs).to eq("def category: (untyped) -> ::Deep::Inner::mood")
  end

  # #697 lets a project wire a loaded plugin's own `sig/` into `signature_paths:`. Those aliases are the
  # plugin's vocabulary, so the Generator subtracts `plugin_registry.signature_paths` from the index's scope.
  # Pinned at the index, the seam the Generator passes those paths to, because standing up a real plugin
  # registry would test the plugin loader rather than this rule.
  describe Rigor::SigGen::AliasIndex do
    def index_for(excluded)
      write("sig/plugin_ish.rbs", "type mood = :deprecated | :experimental | :performance\n")
      sig_dir = File.join(tmpdir, "sig")
      environment = Rigor::Environment.for_project(root: tmpdir, signature_paths: [sig_dir])
      described_class.build(environment: environment, signature_paths: [sig_dir],
                            excluded_paths: excluded ? [sig_dir] : [])
    end

    let(:union) { ":deprecated | :experimental | :performance" }

    it "folds an alias from a signature path that is not excluded" do
      expect(index_for(false).fold(union, "Warner")).to eq("::mood")
    end

    it "ignores an alias from an excluded signature path" do
      expect(index_for(true).fold(union, "Warner")).to eq(union)
    end
  end
end
