# frozen_string_literal: true

# Integration spec for `examples/rigor-activestorage/`.
# Mirrors the structure of the `rigor-activerecord` spec —
# materialises model files on disk, runs the analyser, and
# asserts both the diagnostic stream and the per-model
# attachment index.

require "spec_helper"
require "fileutils"
require "tmpdir"

unless defined?(ACTIVESTORAGE_PLUGIN_LIB)
  ACTIVESTORAGE_PLUGIN_LIB = File.expand_path("../../../examples/rigor-activestorage/lib", __dir__)
end
$LOAD_PATH.unshift(ACTIVESTORAGE_PLUGIN_LIB) unless $LOAD_PATH.include?(ACTIVESTORAGE_PLUGIN_LIB)
require "rigor-activestorage"

RSpec.describe "examples/rigor-activestorage" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Activestorage }

  # rubocop:disable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration
  USER_WITH_ATTACHMENTS = <<~RUBY
    class User < ApplicationRecord
      has_one_attached :avatar
      has_many_attached :photos
    end
  RUBY
  POST_WITHOUT_ATTACHMENTS = "class Post < ApplicationRecord\nend\n"
  APPLICATION_RECORD = "class ApplicationRecord\nend\n"
  USER_RBS = <<~RBS
    class User
      attr_accessor name: String
    end
  RBS
  # rubocop:enable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration

  # Materialises a project tree on disk + runs `rigor check`
  # against `demo.rb`; returns `[result, attachment_index]`
  # so specs can assert against the diagnostic stream AND
  # the structured per-model state captured by the plugin.
  def run_as(source, models: { "app/models/application_record.rb" => APPLICATION_RECORD,
                               "app/models/user.rb" => USER_WITH_ATTACHMENTS,
                               "app/models/post.rb" => POST_WITHOUT_ATTACHMENTS },
             sig: { "sig/user.rbs" => USER_RBS })
    files = models.merge(sig).merge("demo.rb" => source)
    Dir.mktmpdir do |dir|
      materialize_files(dir, files)
      Dir.chdir(dir) do
        configuration = Rigor::Configuration.new(
          "paths" => ["demo.rb"],
          "signature_paths" => ["sig"],
          "plugins" => ["rigor-activestorage"]
        )
        runner = Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: nil,
          collect_stats: false,
          plugin_requirer: build_plugin_requirer
        )
        result = runner.run
        plugin = runner.plugin_registry.find("activestorage")
        [result, plugin&.send(:attachment_index)]
      end
    end
  end

  describe "attachment discovery" do
    it "records `has_one_attached :avatar` as a singular attachment on User" do
      _result, index = run_as("x = 1\n")
      attachments = index.attachments_for("User")
      avatar = attachments.find { |a| a[:name] == "avatar" }

      expect(avatar).to include(name: "avatar", kind: :singular)
    end

    it "records `has_many_attached :photos` as a collection attachment on User" do
      _result, index = run_as("x = 1\n")
      attachments = index.attachments_for("User")
      photos = attachments.find { |a| a[:name] == "photos" }

      expect(photos).to include(name: "photos", kind: :collection)
    end

    it "leaves models without `has_*_attached` macros absent from the index" do
      _result, index = run_as("x = 1\n")

      expect(index.attachments_for("Post")).to be_nil
    end
  end

  describe "diagnostic emission" do
    it "surfaces `attachment-call` info on a recognised attachment access" do
      result, _index = run_as("User.avatar\n")
      info = result.diagnostics.find { |d| d.rule == "attachment-call" }

      expect(info).not_to be_nil
      expect(info.severity).to eq(:info)
      expect(info.message).to include("User.avatar")
      expect(info.message).to include("ActiveStorage::Attached::One")
    end

    it "stays silent on calls to non-attached attribute names" do
      result, _index = run_as("User.nope\n")
      info = result.diagnostics.find { |d| d.rule == "attachment-call" }

      expect(info).to be_nil
    end

    it "stays silent on calls to classes without attachments" do
      result, _index = run_as("Post.something\n")
      info = result.diagnostics.find { |d| d.rule == "attachment-call" }

      expect(info).to be_nil
    end
  end

  describe "flow_contribution_for return-type narrowing" do
    it "narrows `user.avatar` to `Nominal[ActiveStorage::Attached::One]`" do
      _result, index = run_as("x = 1\n")
      plugin = Rigor::Plugin::Activestorage.allocate
      plugin.instance_variable_set(:@attachment_index, index)

      call_node = Prism.parse("user.avatar").value.statements.body.first
      scope = Object.new
      scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.nominal_of("User")
      end
      contribution = plugin.flow_contribution_for(call_node: call_node, scope: scope)

      expect(contribution).to be_a(Rigor::FlowContribution)
      expect(contribution.return_type).to eq(
        Rigor::Type::Combinator.nominal_of("ActiveStorage::Attached::One")
      )
    end

    it "narrows `user.photos` to `Nominal[ActiveStorage::Attached::Many]`" do
      _result, index = run_as("x = 1\n")
      plugin = Rigor::Plugin::Activestorage.allocate
      plugin.instance_variable_set(:@attachment_index, index)

      call_node = Prism.parse("user.photos").value.statements.body.first
      scope = Object.new
      scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.nominal_of("User")
      end
      contribution = plugin.flow_contribution_for(call_node: call_node, scope: scope)

      expect(contribution.return_type).to eq(
        Rigor::Type::Combinator.nominal_of("ActiveStorage::Attached::Many")
      )
    end

    it "declines on non-Nominal receivers (e.g., untyped)" do
      _result, index = run_as("x = 1\n")
      plugin = Rigor::Plugin::Activestorage.allocate
      plugin.instance_variable_set(:@attachment_index, index)

      call_node = Prism.parse("user.avatar").value.statements.body.first
      scope = Object.new
      scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.untyped
      end
      contribution = plugin.flow_contribution_for(call_node: call_node, scope: scope)

      expect(contribution).to be_nil
    end

    it "declines on attachment-name calls with arguments" do
      _result, index = run_as("x = 1\n")
      plugin = Rigor::Plugin::Activestorage.allocate
      plugin.instance_variable_set(:@attachment_index, index)

      call_node = Prism.parse("user.avatar(some_arg)").value.statements.body.first
      scope = Object.new
      scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.nominal_of("User")
      end
      contribution = plugin.flow_contribution_for(call_node: call_node, scope: scope)

      expect(contribution).to be_nil
    end

    it "declines on unknown class names" do
      _result, index = run_as("x = 1\n")
      plugin = Rigor::Plugin::Activestorage.allocate
      plugin.instance_variable_set(:@attachment_index, index)

      call_node = Prism.parse("unknown.avatar").value.statements.body.first
      scope = Object.new
      scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.nominal_of("Unknown")
      end
      contribution = plugin.flow_contribution_for(call_node: call_node, scope: scope)

      expect(contribution).to be_nil
    end
  end
end
