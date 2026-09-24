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
# `new` now counts only on a receiver written as a class object: a constant path, a `class` call, or `self` (explicit
# or implicit) in a singleton-method body. `dup` and `clone` are untouched (ADR-76 reads them as allocating).
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

            class << self
              def eigen
                new.title = "x"
              end
            end

            def retitled
              self.class.new.title = "x"
            end

            # Methods of the class itself, although neither a `def self.` nor a `def` in `class << self` spells one.
            class << self
              define_method(:eigen_defined) do
                new.title = "x"
              end
            end

            singleton_class.class_eval do
              def evaluated
                new.title = "x"
              end
            end
          end

          # An association extension's shape: in an instance method, `self` is the proxy, and its `new` is the
          # proxy's own.
          class DraftPosts < Posts
            def draft
              new.title = "x"
            end

            def draft_self
              self.new.title = "x"
            end

            def draft_local
              post = new
              post.title = "x"
            end

            # Instance methods, although a singleton method defines them.
            def self.define_drafts
              def nested_draft
                new.title = "x"
              end

              define_method(:defined_draft) do
                new.title = "x"
              end
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

            def through_bare_constant
              Note.new.title = "x"
            end

            def through_constant_path
              Blog::Record.new.title = "x"
            end

            def through_constant_local
              post = Blog::Record.new
              post.title = "x"
            end

            def through_class_of(post)
              post.class.new.title = "x"
            end

            def through_class_parameter(klass)
              klass.new.title = "x"
            end

            def through_dup(post)
              post.dup.title = "x"
            end
          end
        RUBY
        # `Note`, `Blog::Record` and `Posts` have signatures and no Ruby body: they stand in for a gem's models and
        # association proxy, whose methods the project cannot see into and whose effects therefore reach no caller
        # through an edge. `Draft#title=` is declared the same way, so its edge carries nothing back either.
        File.write("sig/writer.rbs", <<~RBS)
          class Note
            attr_accessor title: String
          end

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
            def self.eigen: () -> String
            def self.eigen_defined: () -> String
            def self.evaluated: () -> String
            def retitled: () -> String
          end

          class DraftPosts < Posts
            def draft: () -> String
            def draft_self: () -> String
            def draft_local: () -> String
            def self.define_drafts: () -> Symbol
            def nested_draft: () -> String
            def defined_draft: () -> String
          end

          class Writer
            def through_association: (User user) -> String
            def through_association_local: (User user) -> String
            def through_bare_constant: () -> String
            def through_constant_path: () -> String
            def through_constant_local: () -> String
            def through_class_of: (Blog::Record post) -> String
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

  def expect_unproven(key)
    entry = table[key]

    expect(entry.proven).to be_empty, "#{key}: #{entry.proven.to_a}"
    expect(entry).not_to be_exhaustive
    expect(entry.causes.map(&:first)).to eq(["unknown-ownership"]), "#{key}: #{entry.causes.to_a}"
  end

  def expect_allocation(key)
    entry = table[key]

    expect(entry.proven.to_a).to eq(["mutate.local"]), "#{key}: #{entry.proven.to_a}"
    expect(entry).to be_trivial
  end

  # The hole: the record the association builds is reachable from the parameter, so its write is not frame-local and
  # the method is not effect-free.
  it "does not read an association's `new` as an allocation" do
    expect_unproven("Writer#through_association")
  end

  it "does not let an association's `new` make a local frame-owned" do
    expect_unproven("Writer#through_association_local")
  end

  it "does not read `new` on `self` in an instance method as an allocation, implicit, explicit or through a local" do
    %w[DraftPosts#draft DraftPosts#draft_self DraftPosts#draft_local].each { |key| expect_unproven(key) }
  end

  it "reads `new` on a constant, bare or a path, as an allocation" do
    %w[Writer#through_bare_constant Writer#through_constant_path Writer#through_constant_local].each do |key|
      expect_allocation(key)
    end
  end

  it "reads `new` on `self` in a singleton-method body as an allocation, implicit or explicit" do
    %w[Draft.fresh Draft.explicit_self Draft.eigen].each { |key| expect_allocation(key) }
  end

  # The gate reads the unit's singleton bit, so it is only as good as the scanner's keying. A `def` and a
  # `define_method` inside `def self.define_drafts` define instance methods, where `new` is the proxy's own.
  it "does not read `new` as an allocation in an instance method a singleton method defines" do
    %w[DraftPosts#nested_draft DraftPosts#defined_draft].each { |key| expect_unproven(key) }
  end

  it "reads `new` as an allocation in a singleton method `define_method` defines inside `class << self`" do
    expect_allocation("Draft.eigen_defined")
  end

  # The typer does not type a body inside `singleton_class.class_eval` yet, so the unit also carries the taints of the
  # calls it could not resolve. The gate's own part is the `mutate.local`, and no `unknown-ownership` beside it.
  it "reads `new` as an allocation in a singleton method `singleton_class.class_eval` defines" do
    entry = table["Draft.evaluated"]

    expect(entry.proven.to_a).to eq(["mutate.local"])
    expect(entry.causes.map(&:first)).not_to include("unknown-ownership")
  end

  it "reads `new` on a `class` call as an allocation" do
    %w[Draft#retitled Writer#through_class_of].each { |key| expect_allocation(key) }
  end

  # The cost of reading syntax: a class held in a parameter or a local is a class object at run time, but the
  # receiver's spelling cannot tell it from an association, so its write is a taint rather than a proven label.
  it "leaves `new` on a class held in a parameter unproven" do
    expect_unproven("Writer#through_class_parameter")
  end

  it "keeps `dup` as an allocation, as ADR-76 reads it" do
    expect_allocation("Writer#through_dup")
  end
end
