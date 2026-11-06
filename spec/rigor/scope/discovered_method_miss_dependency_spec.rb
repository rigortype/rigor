# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "rigor/protection/discovery_seed"

# Issue #2689 — `Scope#discovered_method_through_ancestors?` read while a dependency recording is active files the
# ADR-46 negative edges of a miss: `method:<entry><sep><name>` and `class:<entry>` for each project entry on the walked
# chain, the edges the def walk files for the same miss. A hit files neither.
RSpec.describe Rigor::Scope, "#discovered_method_through_ancestors? negative edges (#2689)" do
  let(:dir) { Dir.mktmpdir("rigor-discovered-miss-") }
  let(:scope) do
    tables = Rigor::Protection::DiscoverySeed.discovery_tables(Dir[File.join(dir, "*.rb")])
    base = described_class.empty
    base.with_discovery(base.discovery.with(**tables))
  end

  after { FileUtils.rm_rf(dir) }

  before do
    File.write(File.join(dir, "a.rb"), <<~RUBY)
      module Helper
        attr_reader :helped
      end
      class Base < StandardError
        def self.where = 1
      end
      class Child < Base
        include Helper
        extend Helper
        attr_reader :own
      end
    RUBY
  end

  def read
    answer = nil
    record = Rigor::Analysis::DependencyRecorder.record_for(File.join(dir, "c.rb")) { answer = yield }
    [answer, record.missing.grep(/\A(?:method|class):/).grep(/foo|where|helped|own|\Aclass:/).to_set]
  end

  it "files each instance-chain entry's method edge and class edge on an :instance miss" do
    answer, missing = read { scope.discovered_method_through_ancestors?("Child", :foo, :instance) }

    expect(answer).to be(false)
    expect(missing).to eq(Set["method:Child#foo", "method:Helper#foo", "method:Base#foo",
                              "class:Child", "class:Helper", "class:Base"])
  end

  it "files the class objects' singleton edges and the extended module's instance edge on a :singleton miss" do
    answer, missing = read { scope.discovered_method_through_ancestors?("Child", :foo, :singleton) }

    expect(answer).to be(false)
    expect(missing).to eq(Set["method:Child.foo", "method:Helper#foo", "method:Base.foo",
                              "class:Child", "class:Helper", "class:Base"])
  end

  it "files the same method and class edges as the def walk for the same miss" do
    _, discovered = read { scope.discovered_method_through_ancestors?("Child", :foo, :singleton) }
    _, by_def = read { scope.singleton_def_through_ancestors("Child", :foo) }

    expect(discovered).to eq(by_def)
  end

  it "files no negative edge for the name on a hit, either kind" do
    [%i[helped instance], %i[where singleton], %i[helped singleton]].each do |name, kind|
      answer, missing = read { scope.discovered_method_through_ancestors?("Child", name, kind) }

      expect(answer).to be(true), [name, kind].inspect
      expect(missing.grep(/\Amethod:.*#{name}\z/)).to be_empty, [name, kind].inspect
      expect(missing).not_to include("class:Child", "class:Base"), [name, kind].inspect
    end
  end

  it "files the edges through Reflection.project_method_defined(source: :discovered)" do
    _, missing = read do
      Rigor::Reflection.project_method_defined("Child", :foo, kind: :singleton, source: :discovered, scope: scope)
    end

    expect(missing).to include("method:Child.foo", "method:Base.foo", "class:Base")
  end
end
