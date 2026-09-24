# frozen_string_literal: true

require "tmpdir"

require "rigor"
require "rigor/analysis/runner"

# `LocalOwnership.allocation?` is the witness for both `mutate.local` rules: a local whose every assignment allocates
# and never escapes, and a receiver that is itself an allocation. It accepted any call named `new`, and a `new` on
# something other than a class object is only a method that shares the name. An ActiveRecord association's `new`
# builds a record into the association's own target, so `user.posts.new.title = "x"` changes an object the caller
# reaches through `user` — and read as `[mutate.local]`, exhaustive and trivial, because a gem's `new` gives no edge
# that would carry the association's effect to the caller.
#
# `new` now counts only on a receiver written as a class object: a constant path, `self` (explicit or implicit), or
# `self.class`. `dup` and `clone` are untouched (ADR-76 reads them as allocating).
RSpec.describe "the allocation witness behind mutate.local" do
  def configuration
    data = { "paths" => ["lib"], "parallel" => { "workers" => 0 }, "effects" => {} }
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(data))
  end

  let(:table) do
    Dir.mktmpdir("rigor-allocation-witness-") do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p(%w[lib sig])
        File.write("lib/writer.rb", <<~RUBY)
          class Draft
            def self.fresh
              draft = new
              draft.title = "x"
            end

            def self.explicit_self
              self.new.title = "x"
            end

            def retitled
              self.class.new.title = "x"
            end
          end

          class Writer
            def through_association(user)
              user.posts.new.title = "x"
            end

            def through_association_local(user)
              post = user.posts.new
              post.title = "x"
            end

            def through_constant
              Blog::Record.new.title = "x"
            end

            def through_constant_local
              post = Blog::Record.new
              post.title = "x"
            end

            def through_class_parameter(klass)
              klass.new.title = "x"
            end

            def through_dup(post)
              post.dup.title = "x"
            end
          end
        RUBY
        # `Blog::Record` and `Posts` have signatures and no Ruby body: they stand in for a gem's model and association
        # proxy, whose methods the project cannot see into and whose effects therefore reach no caller through an
        # edge. `Draft#title=` is declared the same way, so its edge carries nothing back either.
        File.write("sig/writer.rbs", <<~RBS)
          module Blog
            class Record
              attr_accessor title: String
            end
          end

          class Posts
            def new: () -> Blog::Record
          end

          class User
            def posts: () -> Posts
          end

          class Draft
            attr_accessor title: String

            def self.fresh: () -> String
            def self.explicit_self: () -> String
            def retitled: () -> String
          end

          class Writer
            def through_association: (User user) -> String
            def through_association_local: (User user) -> String
            def through_constant: () -> String
            def through_constant_local: () -> String
            def through_class_parameter: (singleton(Blog::Record) klass) -> String
            def through_dup: (Blog::Record post) -> String
          end
        RBS

        runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
        guarded_run(runner, ["lib"])
        runner.effect_table
      end
    end
  end

  # The hole: the record the association builds is reachable from the parameter, so its write is not frame-local and
  # the method is not effect-free.
  it "does not read an association's `new` as an allocation" do
    entry = table["Writer#through_association"]

    expect(entry.proven).to be_empty
    expect(entry).not_to be_exhaustive
    expect(entry.causes.map(&:first)).to eq(["unknown-ownership"])
  end

  it "does not let an association's `new` make a local frame-owned" do
    entry = table["Writer#through_association_local"]

    expect(entry.proven).to be_empty
    expect(entry).not_to be_exhaustive
    expect(entry.causes.map(&:first)).to eq(["unknown-ownership"])
  end

  it "reads `new` on a written constant path as an allocation" do
    %w[Writer#through_constant Writer#through_constant_local].each do |key|
      expect(table[key].proven.to_a).to eq(["mutate.local"])
      expect(table[key]).to be_trivial
    end
  end

  it "reads `new` on `self`, implicit or explicit, and on `self.class` as an allocation" do
    %w[Draft.fresh Draft.explicit_self Draft#retitled].each do |key|
      expect(table[key].proven.to_a).to eq(["mutate.local"])
      expect(table[key]).to be_trivial
    end
  end

  # The cost of reading syntax: a class held in a parameter or a local is a class object at run time, but the
  # receiver's spelling cannot tell it from an association, so its write is a taint rather than a proven label.
  it "leaves `new` on a class held in a parameter unproven" do
    entry = table["Writer#through_class_parameter"]

    expect(entry.proven).to be_empty
    expect(entry.causes.map(&:first)).to eq(["unknown-ownership"])
  end

  it "keeps `dup` as an allocation, as ADR-76 reads it" do
    expect(table["Writer#through_dup"].proven.to_a).to eq(["mutate.local"])
    expect(table["Writer#through_dup"]).to be_trivial
  end
end
