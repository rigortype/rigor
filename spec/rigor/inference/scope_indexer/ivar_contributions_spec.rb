# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "prism"
require "tmpdir"

# Issues #2079 / #2170 — `ScopeIndexer::IvarContributions` joins other files' `:own_write_type` census entries into
# the class-ivar census of the file a scope names. A scope that names no file joins nothing.
RSpec.describe Rigor::Inference::ScopeIndexer::IvarContributions do
  let(:source) { "class K\n  def initialize = (@x = 1)\nend\n" }
  let(:census) { Set[[:own_write_type, "K", :@x, :dynamic, "other.rb"].freeze] }

  def census_of(scope)
    program = Prism.parse(source).value
    Rigor::Inference::ScopeIndexer.index(program, default_scope: scope)[program].class_ivars_for("K")[:@x].describe
  end

  def seeded(path)
    discovery = Rigor::Scope::DiscoveryIndex::EMPTY.with(discovered_global_write_census: census)
    Rigor::Scope.empty(environment: Rigor::Environment.default, source_path: path).with_discovery(discovery)
  end

  it "joins another file's entry into a file the scope names" do
    expect(census_of(seeded("k.rb"))).to eq("1 | Dynamic[top]")
  end

  it "joins nothing when the scope names no file" do
    expect(census_of(seeded(nil))).to eq("1")
  end

  # Guard: `rigor sig-gen` indexes each file under a scope that names none and carries no project census, so its
  # proposals read the file's own writes whether or not the no-path check stands.
  it "leaves rigor sig-gen's proposal to the file's own writes" do
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      File.write(File.join(lib, "a.rb"), "class E\n  def initialize = (@x = nil)\n  def get = @x\nend\n")
      File.write(File.join(lib, "b.rb"), "class E\n  def set(v) = (@x = v)\nend\n")
      configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => [lib]))
      candidates = Rigor::SigGen::Generator.new(configuration: configuration, paths: [lib]).run
      expect(candidates.find { |c| c.method_name == :get }&.rbs).to eq("def get: () -> nil")
    end
  end
end
