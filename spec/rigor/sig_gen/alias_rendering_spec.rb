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
  def rendered_return(signatures, ruby: three_symbol_method)
    write("lib/warner.rb", ruby)
    signatures&.each { |rel, body| write(File.join("sig", rel), body) }
    paths = [File.join(tmpdir, "lib")]
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => paths,
        "signature_paths" => signatures.nil? ? nil : [File.join(tmpdir, "sig")]
      ).compact
    )
    candidates = Rigor::SigGen::Generator.new(configuration: configuration, paths: paths).run
    candidates.find { |c| c.method_name == :category }.rbs
  end

  it "renders the alias when the inferred union is exactly the alias's expansion" do
    rbs = rendered_return({ "warner.rbs" => "type mood = :deprecated | :experimental | :performance\n" })

    expect(rbs).to eq("def category: (untyped) -> mood")
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

    expect(rbs).to eq("def category: (untyped) -> early")
  end

  it "resolves two aliases declared in the same file by line order" do
    rbs = rendered_return(
      { "warner.rbs" => <<~RBS }
        type upper = :deprecated | :experimental | :performance

        type lower = :deprecated | :experimental | :performance
      RBS
    )

    expect(rbs).to eq("def category: (untyped) -> upper")
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

    expect(rbs).to eq("def category: (untyped) -> mood")
  end
end
