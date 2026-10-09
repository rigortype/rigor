# frozen_string_literal: true

# `rigor-activerecord` publishes the models ActiveRecord loads by name from an association as
# `:reachability_roots` for `rigor unused` (ADR-102 WD3, #1721). Each positive case is paired with the
# empty-contribution control: without the roots the model IS an unused candidate.

require "spec_helper"
require "fileutils"
require "tmpdir"
require "rigor/analysis/reachability/graph"
require "rigor/analysis/reachability/plugin_roots"
require "rigor/analysis/reachability/scan"

unless defined?(ACTIVERECORD_PLUGIN_LIB)
  ACTIVERECORD_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-activerecord/lib", __dir__)
end
$LOAD_PATH.unshift(ACTIVERECORD_PLUGIN_LIB) unless $LOAD_PATH.include?(ACTIVERECORD_PLUGIN_LIB)
require "rigor-activerecord"

RSpec.describe "rigor-activerecord association roots" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Activerecord }

  def model(name, body = "", superclass: "ApplicationRecord")
    inner = body.empty? ? "" : "  #{body}\n"
    "class #{name} < #{superclass}\n#{inner}end\n"
  end

  def project(models)
    files = { "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\nend\n" }
    models.each { |path, source| files["app/models/#{path}.rb"] = source }
    files
  end

  def with_project(files)
    Dir.mktmpdir do |dir|
      files.each do |relative, contents|
        full = File.join(dir, relative)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, contents)
      end
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => [dir], "plugins" => ["rigor-activerecord"])
      )
      Dir.chdir(dir) do
        loaded = false
        contribution = Rigor::Analysis::Reachability::PluginRoots.collect(
          configuration: configuration,
          plugin_requirer: lambda do |_name|
            loaded = true
            Rigor::Plugin.register(plugin_class)
            true
          end
        )
        expect(loaded).to be(true)
        yield(contribution, dir)
      end
    end
  end

  def candidates_for(dir, files, roots)
    declarations = []
    references = []
    files.each_key do |relative|
      result = Rigor::Analysis::Reachability::Scan.call(path: relative, source: File.read(File.join(dir, relative)))
      declarations.concat(result.declarations)
      references.concat(result.references)
    end
    Rigor::Analysis::Reachability::Graph.new(
      declarations: declarations, references: references, root_fqns: roots
    ).report.candidates.map(&:fqn)
  end

  # The published roots, the candidates the roots remove (empty-contribution control minus with-roots), and
  # the candidates that stay.
  def outcome(files)
    files = files.merge("app/main.rb" => "Owner.new\n")
    with_project(files) do |contribution, dir|
      with_roots = candidates_for(dir, files, contribution.roots)
      without = candidates_for(dir, files, [])
      return { roots: contribution.roots, freed: without - with_roots, kept: with_roots }
    end
  end

  it "registers the :reachability_roots product" do
    expect(plugin_class.manifest.produces).to include(:reachability_roots)
  end

  it "roots the target of belongs_to and has_one by camelizing the name" do
    files = project(
      "owner" => model("Owner", "belongs_to :blog_user\n  has_one :profile"),
      "blog_user" => model("BlogUser"), "profile" => model("Profile"), "stray" => model("Stray")
    )
    result = outcome(files)
    expect(result[:roots]).to match_array(%w[BlogUser Profile])
    expect(result[:freed]).to match_array(%w[BlogUser Profile])
    expect(result[:kept]).to include("Stray")
  end

  it "roots the target of has_many and has_and_belongs_to_many by singularizing the name" do
    files = project(
      "owner" => model("Owner", "has_many :comments\n  has_and_belongs_to_many :categories"),
      "comment" => model("Comment"), "category" => model("Category"), "stray" => model("Stray")
    )
    result = outcome(files)
    expect(result[:roots]).to match_array(%w[Comment Category])
    expect(result[:freed]).to match_array(%w[Comment Category])
    expect(result[:kept]).to include("Stray")
  end

  it "prefers a literal class_name: (String, Symbol or rooted) over the inferred name" do
    files = project(
      "owner" => model("Owner", <<~RUBY.strip),
        belongs_to :author, class_name: "User"
          has_many :notes, class_name: :Memo
          has_one :boss, class_name: "::Manager"
      RUBY
      "user" => model("User"), "memo" => model("Memo"), "manager" => model("Manager"),
      "author" => model("Author"), "note" => model("Note"), "boss" => model("Boss")
    )
    result = outcome(files)
    expect(result[:roots]).to match_array(%w[User Memo Manager])
    expect(result[:freed]).to match_array(%w[User Memo Manager])
    expect(result[:kept]).to include(*%w[Author Note Boss])
  end

  it "declines a non-literal class_name:" do
    files = project(
      "owner" => model("Owner", "belongs_to :author, class_name: Settings.author_class\n  has_one :boss, **opts"),
      "author" => model("Author"), "boss" => model("Boss")
    )
    result = outcome(files)
    expect(result[:roots]).to be_empty
    expect(result[:freed]).to be_empty
    expect(result[:kept]).to include(*%w[Author Boss])
  end

  it "resolves against the owner's namespaces, innermost first, then top level" do
    files = project(
      "admin/owner" => "module Admin\n  class Owner < ApplicationRecord\n    belongs_to :user\n    " \
                       "has_many :logs\n    has_one :widget\n  end\nend\n",
      "admin/user" => "module Admin\n  class User < ApplicationRecord\n  end\nend\n",
      "user" => model("User"), "log" => model("Log"), "widget" => model("Widget"),
      "other" => model("Other")
    )
    with_project(files.merge("app/main.rb" => "Admin::Owner.new\n")) do |contribution, dir|
      expect(contribution.roots).to contain_exactly("Admin::User", "Log", "Widget")
      all = files.merge("app/main.rb" => "Admin::Owner.new\n")
      expect(candidates_for(dir, all, [])).to include("Admin::User", "User", "Log", "Widget")
      expect(candidates_for(dir, all, contribution.roots)).not_to include("Admin::User", "Log", "Widget")
      expect(candidates_for(dir, all, contribution.roots)).to include("User")
    end
  end

  it "tries the owner's own namespace first: Post::Comment beats a top-level Comment" do
    files = project(
      "post" => model("Post", "has_many :comments"),
      "post/comment" => model("Post::Comment"), "comment" => model("Comment")
    )
    files["app/main.rb"] = "Post.new\n"
    with_project(files) do |contribution, dir|
      expect(contribution.roots).to eq(["Post::Comment"])
      expect(candidates_for(dir, files, contribution.roots)).to include("Comment")
    end
  end

  it "declines when the first candidate is a namespace of models rather than a model" do
    files = project(
      "post" => model("Post", "has_one :email"),
      "post/email/draft" => model("Post::Email::Draft"), "email" => model("Email")
    )
    result = outcome(files)
    expect(result[:roots]).to be_empty
    expect(result[:kept]).to include("Email")
  end

  it "merges literal with_options options into the associations inside the group" do
    files = project(
      "owner" => model("Owner", <<~RUBY.strip),
        with_options class_name: "Person" do
            belongs_to :creator
            has_many :editors, class_name: "Staff"
          end
          with_options polymorphic: true do
            belongs_to :subject
          end
          with_options through: :taggings, source_type: "Tag" do
            has_many :labels
          end
      RUBY
      "person" => model("Person"), "staff" => model("Staff"), "creator" => model("Creator"),
      "editor" => model("Editor"), "subject" => model("Subject"), "label" => model("Label"),
      "tag" => model("Tag")
    )
    result = outcome(files)
    expect(result[:roots]).to match_array(%w[Person Staff Tag])
    expect(result[:kept]).to include("Creator", "Editor", "Subject", "Label")
  end

  it "lets the innermost nested with_options group win" do
    files = project(
      "owner" => model("Owner", <<~RUBY.strip),
        with_options class_name: "Person" do
            with_options class_name: "Member" do
              belongs_to :leader
            end
            belongs_to :boss
          end
      RUBY
      "person" => model("Person"), "member" => model("Member"), "leader" => model("Leader")
    )
    result = outcome(files)
    expect(result[:roots]).to match_array(%w[Person Member])
  end

  it "declines a computed name equal to the owner's own name (Rails tries ::Name first)" do
    files = project(
      "billing/account" => "module Billing\n  class Account < ApplicationRecord\n    has_one :account\n  end\nend\n",
      "account" => model("Account")
    )
    files["app/main.rb"] = "Billing::Account.new\n"
    with_project(files) do |contribution, _dir|
      expect(contribution.roots).to be_empty
    end
  end

  it "does not let a group's literal option stand in for the call's own non-literal one" do
    files = project(
      "owner" => model("Owner", <<~RUBY.strip),
        with_options class_name: "Reviewer" do
            belongs_to :checker, **OPTS
            belongs_to :auditor, OPTS
            belongs_to :tester, class_name: Settings.tester
            belongs_to :poly, polymorphic: flag
          end
      RUBY
      "reviewer" => model("Reviewer"), "checker" => model("Checker"), "auditor" => model("Auditor"),
      "tester" => model("Tester"), "poly" => model("Poly")
    )
    expect(outcome(files)[:roots]).to be_empty
  end

  it "still roots through a scope lambda argument" do
    files = project("owner" => model("Owner", "has_many :comments, -> { order(:id) }"), "comment" => model("Comment"))
    expect(outcome(files)[:roots]).to eq(["Comment"])
  end

  it "declines associations in a with_options group whose options are not literal" do
    files = project(
      "owner" => model("Owner", "with_options opts do\n    belongs_to :creator\n  end"),
      "creator" => model("Creator")
    )
    result = outcome(files)
    expect(result[:roots]).to be_empty
    expect(result[:kept]).to include("Creator")
  end

  it "roots a through: association's literal source_type: and declines anonymous_class:" do
    files = project(
      "owner" => model("Owner", "has_many :tags, through: :taggings, source_type: \"Label\"\n  " \
                                "belongs_to :thing, anonymous_class: Klass"),
      "label" => model("Label"), "tag" => model("Tag"), "thing" => model("Thing")
    )
    result = outcome(files)
    expect(result[:roots]).to eq(["Label"])
    expect(result[:kept]).to include("Tag", "Thing")
  end

  it "skips polymorphic associations" do
    files = project(
      "owner" => model("Owner", "belongs_to :commentable, polymorphic: true\n  has_many :things, as: :owner"),
      "commentable" => model("Commentable")
    )
    result = outcome(files)
    expect(result[:roots]).to be_empty
    expect(result[:freed]).to be_empty
    expect(result[:kept]).to include("Commentable")
  end

  it "roots an `as:` has_many target, which is a normal association" do
    files = project(
      "owner" => model("Owner", "has_many :comments, as: :commentable"),
      "comment" => model("Comment")
    )
    result = outcome(files)
    expect(result[:roots]).to contain_exactly("Comment")
    expect(result[:freed]).to contain_exactly("Comment")
  end

  it "roots a through: association only through a literal class_name: or source_type:" do
    files = project(
      "owner" => model("Owner", <<~RUBY.strip),
        has_many :taggings
          has_many :tags, through: :taggings
          has_many :labels, through: :taggings, class_name: "Marker"
      RUBY
      "tagging" => model("Tagging", "belongs_to :tag"),
      "tag" => model("Tag"), "label" => model("Label"), "marker" => model("Marker")
    )
    # Tag is rooted by Tagging's own belongs_to; Label is never rooted; Tagging by has_many :taggings.
    result = outcome(files)
    expect(result[:roots]).to match_array(%w[Tag Tagging Marker])
    expect(result[:freed]).to match_array(%w[Tag Tagging Marker])
    expect(result[:kept]).to include("Label")
  end

  it "does not root a name that matches no model" do
    files = project("owner" => model("Owner", "belongs_to :ghost\n  has_many :phantoms"), "other" => model("Other"))
    result = outcome(files)
    expect(result[:roots]).to be_empty
    expect(result[:freed]).to be_empty
    expect(result[:kept]).to include("Other")
  end

  it "ignores associations in `class << self`, a def or a block" do
    body = <<~RUBY.strip
      class << self
          belongs_to :alpha
        end
        def declare
          has_many :betas
        end
        included do
          has_one :gamma
        end
    RUBY
    files = project(
      "owner" => model("Owner", body),
      "alpha" => model("Alpha"), "beta" => model("Beta"), "gamma" => model("Gamma")
    )
    result = outcome(files)
    expect(result[:roots]).to be_empty
    expect(result[:freed]).to be_empty
    expect(result[:kept]).to include(*%w[Alpha Beta Gamma])
  end

  it "roots flat: an association on an otherwise unused model still roots its target" do
    files = project("owner" => model("Owner"), "dead" => model("Dead", "belongs_to :owner"))
    files["app/models/dead.rb"] = model("Dead", "has_many :comments")
    files["app/models/comment.rb"] = model("Comment")
    with_project(files) do |contribution, dir|
      expect(contribution.roots).to eq(["Comment"])
      expect(candidates_for(dir, files, contribution.roots)).to include("Dead")
      expect(candidates_for(dir, files, contribution.roots)).not_to include("Comment")
    end
  end
end
