# frozen_string_literal: true

# Integration spec for `plugins/rigor-alba/` (issue #1682).
#
# Contract:
#
# 1. The block of `Alba.serialize` / `Alba.hashify` runs on an anonymous `Alba::Resource` class, so the DSL
#    calls inside no longer read as `call.unresolved-toplevel`.
# 2. The plugin contributes no return type: every alba call reads exactly as it does without the plugin.
# 3. An association that makes alba infer its resource class roots that class for `rigor unused` — and only
#    when the association names no resource and a class of the inferred name exists.
# 4. The plugin never adds a diagnostic.
#
# Every positive example has a control that runs the same project with the plugin switched off, so none of
# them can pass for an unrelated reason.

require "spec_helper"

require "fileutils"
require "tmpdir"

require "rigor/analysis/reachability/graph"
require "rigor/analysis/reachability/plugin_roots"
require "rigor/analysis/reachability/scan"

ALBA_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-alba/lib", __dir__)
$LOAD_PATH.unshift(ALBA_PLUGIN_LIB) unless $LOAD_PATH.include?(ALBA_PLUGIN_LIB)
require "rigor-alba"

RSpec.describe "rigor-alba integration" do
  let(:plugin_class) { Rigor::Plugin::Alba }

  let(:resource_files) do
    {
      "app/resources/user_resource.rb" => <<~RUBY,
        class UserResource
          include Alba::Resource
          attributes :id
        end
      RUBY
      "app/resources/base_resource.rb" => <<~RUBY,
        class BaseResource
          include Alba::Resource
        end
        class AdminUserResource < BaseResource
        end
      RUBY
      "app/resources/over_resource.rb" => <<~RUBY,
        module Serializes
          def serialize(**) = { a: 1 }
        end
        class OverChild
          include Alba::Resource
          include Serializes
        end
        class DefinedByMacro
          include Alba::Resource
          define_method(:serialize) { |**| { a: 1 } }
        end
        class OwnDef
          include Alba::Resource
        end
      RUBY
      "lib/reopen.rb" => "class OwnDef\n  def serialize(**) = { a: 1 }\nend\n",
      "app/models/plain.rb" => "class Plain\n  def serialize = 1\nend\n"
    }
  end

  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  def run_alba(source, files: resource_files, enabled: true)
    run_plugin(
      source: source, files: files, paths: %w[demo.rb app],
      plugin_entry: { "gem" => "rigor-alba", "enabled" => enabled }
    )
  end

  def dump_types(result)
    result.diagnostics.select { |d| d.qualified_rule == "dump.type" }
          .sort_by(&:line).map { |d| d.message.sub("dump_type: ", "") }
  end

  def unresolved(result)
    result.diagnostics.select { |d| d.qualified_rule == "call.unresolved-toplevel" }
  end

  it "registers a manifest targeting alba that produces reachability roots" do
    manifest = plugin_class.manifest
    expect(manifest.id).to eq("alba")
    expect(manifest.target_gems).to eq(["alba"])
    expect(manifest.produces).to include(:reachability_roots)
    expect(manifest.open_receivers).to include("Alba", "Alba::Resource")
  end

  describe "block self of Alba.serialize / Alba.hashify" do
    let(:source) do
      <<~RUBY
        a = Alba.serialize(1) { attributes :id }
        b = Alba.hashify(1) do
          attributes :id
          attribute(:x) { |o| o }
        end
      RUBY
    end

    it "resolves the DSL calls inside the block" do
      expect(unresolved(run_alba(source))).to be_empty
    end

    it "fires call.unresolved-toplevel for each DSL call without the plugin" do
      rows = unresolved(run_alba(source, enabled: false))
      expect(rows.map(&:line)).to eq([1, 3, 4])
    end
  end

  describe "return types" do
    # The plugin contributes none: `Alba.serialize(obj)` runs the project's `<Class>Resource#serialize`, which
    # may return anything, so every shape below must read exactly as it does without the plugin.
    it "leaves Alba.serialize, hashify and instance methods as the engine resolves them" do
      source = <<~RUBY
        class Boxed; end
        Rigor.dump_type(Alba.serialize(Boxed.new))
        Rigor.dump_type(Alba.serialize(Boxed.new).keys)
        Rigor.dump_type(Alba.serialize(1, with: UserResource))
        Rigor.dump_type(Alba.serialize(1, root_key: :a))
        Rigor.dump_type(Alba.hashify(1))
        Rigor.dump_type(UserResource.new(1).to_h)
        Rigor.dump_type(OverChild.new(1).serialize.fetch(:a))
        Rigor.dump_type(DefinedByMacro.new(1).serialize)
        Rigor.dump_type(OwnDef.new(1).serialize)
        Rigor.dump_type(Plain.new.serialize)
      RUBY
      with = run_alba(source, files: resource_files)
      without = run_alba(source, files: resource_files, enabled: false)
      expect(dump_types(with)).to eq(dump_types(without))
      expect(with.diagnostics.map(&:qualified_rule)).to eq(without.diagnostics.map(&:qualified_rule))
    end

    it "does not type Alba.serialize over a resource that overrides #serialize" do
      files = resource_files.merge(
        "app/resources/boxed_resource.rb" => "class BoxedResource\n  include Alba::Resource\n  " \
                                             "def serialize(**) = { a: 1 }\nend\n"
      )
      source = "class Boxed; end\nAlba.serialize(Boxed.new).keys\n"
      with = run_alba(source, files: files)
      expect(with.diagnostics.map(&:qualified_rule)).not_to include("call.undefined-method")
    end
  end

  describe "the plugin adds no diagnostic" do
    it "emits nothing of its own and no core diagnostic the plugin-less run lacks" do
      source = <<~RUBY
        x = Alba.serialize(UserResource.new(1)) { attributes :id }
        y = UserResource.new(1, params: { a: 1 }).serialize
        Alba.bogus_thing
        UserResource.attributes :more
        UserResource.new(1).bogus
        Rigor.dump_type(x)
      RUBY
      with = run_alba(source)
      without = run_alba(source, enabled: false)
      tally = lambda do |result|
        result.diagnostics.reject { |d| d.severity == :info }.map { |d| [d.path, d.line, d.qualified_rule] }.tally
      end
      without_tally = tally.call(without)

      expect(plugin_diagnostics(with)).to be_empty
      added = tally.call(with).select { |key, count| count > without_tally.fetch(key, 0) }
      expect(added).to be_empty
    end
  end

  describe "inferred association resources as `rigor unused` roots" do
    let(:files) do
      {
        "app/main.rb" => "UserResource.new(1)\n",
        "app/resources/article_resource.rb" => "class ArticleResource\n  include Alba::Resource\nend\n",
        "app/resources/comment_serializer.rb" => "class CommentSerializer\n  include Alba::Resource\nend\n",
        "app/resources/orphan_resource.rb" => "class OrphanResource\n  include Alba::Resource\nend\n",
        "app/resources/review_resource.rb" => "class ReviewResource\n  include Alba::Resource\nend\n",
        "app/resources/user_resource.rb" => <<~RUBY
          class UserResource
            include Alba::Resource
            many :articles
            has_many "comments"
            many :reviews, resource: Elsewhere
            many :tags
          end
        RUBY
      }
    end

    def roots_for(files)
      Dir.mktmpdir do |dir|
        files.each do |relative, contents|
          full = File.join(dir, relative)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, contents)
        end
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge("paths" => [dir], "plugins" => ["rigor-alba"])
        )
        loaded = false
        Dir.chdir(dir) do
          contribution = Rigor::Analysis::Reachability::PluginRoots.collect(
            configuration: configuration,
            plugin_requirer: lambda do |_name|
              loaded = true
              Rigor::Plugin.register(plugin_class)
              true
            end
          )
          # PluginRoots.collect is fail-soft: without this an empty answer cannot tell "declined" from "never ran".
          expect(loaded).to be(true)
          yield(contribution, dir)
        end
      end
    end

    def candidates_for(dir, files, contribution)
      declarations = []
      references = []
      files.each_key do |relative|
        result = Rigor::Analysis::Reachability::Scan.call(path: relative, source: File.read(File.join(dir, relative)))
        declarations.concat(result.declarations)
        references.concat(result.references)
      end
      Rigor::Analysis::Reachability::Graph.new(
        declarations: declarations, references: references, root_fqns: contribution.roots
      ).report.candidates.map(&:fqn)
    end

    it "roots the classes alba infers, and only those" do
      roots_for(files) do |contribution, _dir|
        expect(contribution.roots).to contain_exactly("ArticleResource", "CommentSerializer")
      end
    end

    it "takes the inferred resources out of the unused candidates and keeps the rest" do
      roots_for(files) do |contribution, dir|
        expect(candidates_for(dir, files, contribution)).to contain_exactly("OrphanResource", "ReviewResource")
      end
    end

    it "lists every resource as a candidate when nothing is rooted" do
      Dir.mktmpdir do |dir|
        files.each do |relative, contents|
          FileUtils.mkdir_p(File.dirname(File.join(dir, relative)))
          File.write(File.join(dir, relative), contents)
        end
        none = Rigor::Analysis::Reachability::PluginRoots::Contribution.new(roots: [], references: [])
        expect(candidates_for(dir, files, none)).to include("ArticleResource", "CommentSerializer")
      end
    end

    it "publishes no root for an association that names a resource, a serializer, a block or a second argument" do
      files = {
        "app/resources/article_resource.rb" => "class ArticleResource\n  include Alba::Resource\nend\n",
        "app/resources/tag_resource.rb" => "class TagResource\n  include Alba::Resource\nend\n",
        "app/resources/note_resource.rb" => "class NoteResource\n  include Alba::Resource\nend\n",
        "app/resources/item_resource.rb" => "class ItemResource\n  include Alba::Resource\nend\n",
        "app/resources/thing_resource.rb" => "class ThingResource\n  include Alba::Resource\nend\n",
        "app/resources/name_from_variable_resource.rb" =>
          "class NameFromVariableResource\n  include Alba::Resource\nend\n",
        "app/resources/user_resource.rb" => <<~RUBY
          class UserResource
            include Alba::Resource
            many :articles, resource: Other
            many :tags, serializer: Other
            many :notes do
              attributes :id
            end
            many :items, proc { |x| x }
            many :things, **opts
            many name_from_variable
          end
        RUBY
      }
      roots_for(files) { |contribution, _dir| expect(contribution.roots).to be_empty }
    end

    it "publishes no root for an inferred name that no class matches" do
      files = {
        "app/resources/user_resource.rb" => "class UserResource\n  include Alba::Resource\n  many :ghosts\nend\n",
        "app/resources/other_resource.rb" => "class OtherResource\n  include Alba::Resource\nend\n"
      }
      roots_for(files) { |contribution, _dir| expect(contribution.roots).to be_empty }
    end

    it "does not read a non-alba class's has_many as an association" do
      files = {
        "app/models/user.rb" => "class User\n  has_many :articles\nend\n",
        "app/resources/article_resource.rb" => "class ArticleResource\n  include Alba::Resource\nend\n"
      }
      roots_for(files) { |contribution, _dir| expect(contribution.roots).to be_empty }
    end

    it "resolves under the resource's namespace first, then the top level, Resource before Serializer" do
      files = {
        "app/a.rb" => <<~RUBY,
          module Admin
            class ReportResource
              include Alba::Resource
              many :entries
              many :tags
              many :users
            end
            class EntryResource; end
          end
          class EntryResource; end
          class TagResource; end
          class UserSerializer; end
          class UserResource; end
        RUBY
        "app/b.rb" => <<~RUBY
          module Admin
            class UserSerializer; end
          end
        RUBY
      }
      roots_for(files) do |contribution, _dir|
        expect(contribution.roots).to contain_exactly("Admin::EntryResource", "TagResource", "UserResource")
      end
    end

    it "follows a superclass the project defines when deciding who is a resource" do
      files = {
        "app/resources/base_resource.rb" => "class BaseResource\n  include Alba::Resource\nend\n",
        "app/resources/user_resource.rb" => "class UserResource < BaseResource\n  many :articles\nend\n",
        "app/resources/article_resource.rb" => "class ArticleResource < BaseResource\nend\n"
      }
      roots_for(files) { |contribution, _dir| expect(contribution.roots).to eq(["ArticleResource"]) }
    end

    it "tries only top-level candidates for an association inside a trait, nested or association block" do
      files = {
        "app/a.rb" => <<~RUBY
          module Admin
            class UserResource
              include Alba::Resource
              trait(:x) { many :comments }
              many :notes do
                many :tags
              end
            end
            class CommentResource; end
            class TagResource; end
          end
          class CommentResource; end
          class TagResource; end
        RUBY
      }
      roots_for(files) do |contribution, _dir|
        expect(contribution.roots).to contain_exactly("CommentResource", "TagResource")
      end
    end

    it "resolves a compact header's superclass against the lexical scope, not the class's own namespace" do
      files = {
        "app/a.rb" => <<~RUBY
          class BaseResource
            include Alba::Resource
          end
          module Admin
            class BaseResource; end
          end
          class Admin::UserResource < BaseResource
            many :articles
          end
          class ArticleResource; end
        RUBY
      }
      roots_for(files) { |contribution, _dir| expect(contribution.roots).to eq(["ArticleResource"]) }
    end

    it "keeps the owner's nesting for an association in a block of an ordinary call" do
      files = {
        "app/a.rb" => <<~RUBY
          module N
            class OwnerResource
              include Alba::Resource
              %i[x].each { many :doodads }
            end
            class DoodadResource; end
          end
          class DoodadResource; end
        RUBY
      }
      roots_for(files) { |contribution, _dir| expect(contribution.roots).to eq(["N::DoodadResource"]) }
    end
  end
end
