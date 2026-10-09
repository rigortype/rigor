# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Issue #1703 — a `key?` guard's narrowing is a diagnostic aid inside one method body. sig-gen must publish what the
# method returns without it, the miss `nil` included, as it does for a read with no guard: the guard rests on the key
# expression re-reading the same value, and nothing in a signature can say so.
RSpec.describe "sig-gen under a key? guard with a non-literal key" do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  def rendered(method_name)
    FileUtils.mkdir_p(File.join(tmpdir, "lib"))
    File.write(File.join(tmpdir, "lib", "lookup.rb"), <<~RUBY)
      class Lookup
        TABLE = { a: "x", b: "y" }.freeze

        def plain(name)
          return "none" unless TABLE.key?(name)
          TABLE[name]
        end

        def chained(prop)
          return "none" unless TABLE.key?(prop.kind)
          TABLE[prop.kind]
        end
      end
    RUBY
    paths = [File.join(tmpdir, "lib")]
    configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => paths))
    candidates = Rigor::SigGen::Generator.new(configuration: configuration, paths: paths).run
    candidates.find { |c| c.method_name == method_name }.rbs
  end

  it "keeps the miss nil in the return of a method that reads under the guard" do
    expect(rendered(:plain)).to eq('def plain: (untyped) -> ("none" | "x" | "y" | nil)')
    expect(rendered(:chained)).to eq('def chained: (untyped) -> ("none" | "x" | "y" | nil)')
  end
end
