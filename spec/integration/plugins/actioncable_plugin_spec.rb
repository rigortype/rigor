# frozen_string_literal: true

# Integration spec for `plugins/rigor-actioncable/`. Tier 3F of the Rails plugins roadmap. Discovers channel
# classes by walking `app/channels/` and validates `<Channel>.broadcast_to(...)` and
# `ActionCable.server.broadcast(stream_name, ...)` calls.

require "spec_helper"

ACTIONCABLE_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-actioncable/lib", __dir__)
$LOAD_PATH.unshift(ACTIONCABLE_PLUGIN_LIB) unless $LOAD_PATH.include?(ACTIONCABLE_PLUGIN_LIB)
require "rigor-actioncable"

DEFAULT_CHANNELS = {
  "app/channels/application_cable_channel.rb" => <<~RUBY,
    module ApplicationCable
      class Channel
      end
    end
  RUBY
  "app/channels/chat_channel.rb" => <<~RUBY,
    class ChatChannel < ApplicationCable::Channel
      def subscribed
        stream_from "chat_room_5"
      end

      def speak(data)
        data
      end

      def whisper(data)
        data
      end
    end
  RUBY
  "app/channels/notifications_channel.rb" => <<~RUBY
    class NotificationsChannel < ApplicationCable::Channel
      def subscribed
        stream_from "notifications_global"
      end

      def mark_read(data)
        data
      end
    end
  RUBY
}.freeze

DEFAULT_PLUGIN_ENTRY = {
  "gem" => "rigor-actioncable",
  "id" => "actioncable",
  "config" => { "channel_base_classes" => ["ApplicationCable::Channel"] }
}.freeze

RSpec.describe "plugins/rigor-actioncable" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Actioncable }

  # Do NOT opt into the shared per-process `Cache::Store`: examples in this file test custom roots and empty
  # channels across distinct temporary directories, which causes empty channel cache entries to bleed across
  # examples when run under random seeds (issue #704).

  describe "broadcast_to recognition" do
    it "emits a `broadcast-target` info diagnostic for `<Channel>.broadcast_to(...)`" do
      result = run_plugin(
        source: 'ChatChannel.broadcast_to(@room, message: "hi")' + "\n", # rubocop:disable Style/StringConcatenation
        files: DEFAULT_CHANNELS,
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "broadcast-target" }
      expect(info).not_to be_nil
      expect(info.severity).to eq(:info)
      expect(info.message).to include("ChatChannel")
    end

    it "flags an unknown-channel call with a did-you-mean suggestion" do
      result = run_plugin(
        source: %(ChartChannel.broadcast_to(@room, message: "hi")\n),
        files: DEFAULT_CHANNELS,
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "unknown-channel" }
      expect(err).not_to be_nil
      expect(err.message).to include("ChartChannel")
      expect(err.message).to include("ChatChannel")
    end

    it "ignores `<NonChannelClass>.broadcast_to(...)` (likely an unrelated method)" do
      result = run_plugin(
        source: %(SomeClass.broadcast_to(@thing, data: 1)\n),
        files: DEFAULT_CHANNELS,
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      diags = plugin_diagnostics(result)
      expect(diags).to be_empty
    end
  end

  # #621 — the discoverer used to key `class ::ChatChannel` as `"::ChatChannel"` (and, nested inside a
  # module, as the nonsense `"Admin::::ChatChannel"`), and the analyzer papered over the first spelling with
  # a `find(name) || find("::#{name}")` retry. The base-class match had the mirror bug: a channel written
  # `< ::ApplicationCable::Channel` was not discovered at all, so its own `broadcast_to` call sites reported
  # `unknown-channel` on correct code. Keys and base-class names are de-rooted at the producer now, which
  # makes a rooted declaration and a plain reopen collide on ONE key — so the actions and stream names union
  # instead of the last file in the glob clobbering the first.
  describe "rooted declarations and reopens (#621)" do
    let(:rooted_files) do
      DEFAULT_CHANNELS.except("app/channels/chat_channel.rb").merge(
        "app/channels/a_chat_channel.rb" => <<~RUBY
          class ::ChatChannel < ApplicationCable::Channel
            def subscribed
              stream_from "chat_room_5"
            end

            def speak(data)
              data
            end
          end
        RUBY
      )
    end

    # A later-sorting file reopens the rooted declaration plainly, adding its own stream.
    let(:reopen_files) do
      rooted_files.merge(
        "app/channels/z_chat_channel_ext.rb" => <<~RUBY
          class ChatChannel < ApplicationCable::Channel
            def subscribed
              stream_from "chat_room_9"
            end
          end
        RUBY
      )
    end

    it "recognises a rooted channel declaration under its plain spelling" do
      result = run_plugin(
        source: %(ChatChannel.broadcast_to(@room, message: "hi")\n),
        files: rooted_files,
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "unknown-channel" }).to be_empty
      expect(diags.find { |d| d.rule == "broadcast-target" }).not_to be_nil
    end

    it "recognises a channel whose base class is written rooted" do
      files = DEFAULT_CHANNELS.merge(
        "app/channels/rooted_base_channel.rb" => <<~RUBY
          class RootedBaseChannel < ::ApplicationCable::Channel
            def subscribed
              stream_from "rooted_base"
            end
          end
        RUBY
      )
      result = run_plugin(
        source: %(RootedBaseChannel.broadcast_to(@room, message: "hi")\n),
        files: files,
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "unknown-channel" }).to be_empty
      expect(diags.find { |d| d.rule == "broadcast-target" }).not_to be_nil
    end

    it "recognises a channel declared rooted INSIDE a module as the top-level constant it names" do
      files = DEFAULT_CHANNELS.merge(
        "app/channels/admin_alert_channel.rb" => <<~RUBY
          module Admin
            class ::AlertChannel < ApplicationCable::Channel
              def subscribed
                stream_from "alerts"
              end
            end
          end
        RUBY
      )
      result = run_plugin(
        source: %(AlertChannel.broadcast_to(@room, message: "hi")\n),
        files: files,
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "unknown-channel" }).to be_empty
      expect(diags.find { |d| d.rule == "broadcast-target" }).not_to be_nil
    end

    it "keeps the rooted declaration's streams when a later file reopens the channel plainly" do
      result = run_plugin(
        source: %(ActionCable.server.broadcast("chat_room_5", message: "hi")\n),
        files: reopen_files,
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "unknown-stream" }).to be_empty
      expect(diags.find { |d| d.rule == "broadcast-stream" }).not_to be_nil
    end

    it "also keeps the reopen's own stream" do
      result = run_plugin(
        source: %(ActionCable.server.broadcast("chat_room_9", message: "hi")\n),
        files: reopen_files,
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      expect(plugin_diagnostics(result).find { |d| d.rule == "broadcast-stream" }).not_to be_nil
    end

    it "still flags a stream name no declaration registers" do
      result = run_plugin(
        source: %(ActionCable.server.broadcast("chat_room_404", message: "hi")\n),
        files: reopen_files,
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "unknown-stream" }
      expect(err).not_to be_nil
      expect(err.message).to include("chat_room_404")
    end

    it "still flags a channel constant no declaration introduces" do
      result = run_plugin(
        source: %(NopeChannel.broadcast_to(@room, message: "hi")\n),
        files: reopen_files,
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "unknown-channel" }
      expect(err).not_to be_nil
      expect(err.message).to include("NopeChannel")
    end
  end

  describe "ActionCable.server.broadcast recognition" do
    let(:files_with_dynamic_channel) do
      DEFAULT_CHANNELS.merge(
        "app/channels/dynamic_channel.rb" => <<~RUBY
          class DynamicChannel < ApplicationCable::Channel
            def subscribed
              stream_from "dyn_\#{params[:room_id]}"
            end
          end
        RUBY
      )
    end

    it "emits a `broadcast-stream` info when the stream name matches a `stream_from` registration" do
      result = run_plugin(
        source: %(ActionCable.server.broadcast("chat_room_5", message: "hi")\n),
        files: DEFAULT_CHANNELS,
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "broadcast-stream" }
      expect(info).not_to be_nil
      expect(info.message).to include("chat_room_5")
    end

    it "warns when the literal stream name is not registered, with a did-you-mean suggestion" do
      result = run_plugin(
        source: %(ActionCable.server.broadcast("chat_room_42", message: "hi")\n),
        files: DEFAULT_CHANNELS,
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      warn = plugin_diagnostics(result).find { |d| d.rule == "unknown-stream" }
      expect(warn).not_to be_nil
      expect(warn.message).to include("chat_room_42")
      expect(warn.message).to include("chat_room_5")
    end

    it "does not warn when the stream argument is not a literal string" do
      result = run_plugin(
        source: "name = 'chat_room_42'\nActionCable.server.broadcast(name, message: 'hi')\n",
        files: DEFAULT_CHANNELS,
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "unknown-stream" }).to be_empty
    end

    it "suppresses unknown-stream warnings when any discovered channel uses dynamic streams" do
      result = run_plugin(
        source: %(ActionCable.server.broadcast("chat_room_42", x: 1)\n),
        files: files_with_dynamic_channel,
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "unknown-stream" }).to be_empty
    end
  end

  describe "stream_for recognition" do
    let(:files_with_stream_for_channel) do
      DEFAULT_CHANNELS.merge(
        "app/channels/room_channel.rb" => <<~RUBY
          class RoomChannel < ApplicationCable::Channel
            def subscribed
              stream_for room
            end
          end
        RUBY
      )
    end

    it "treats `stream_for record` as a dynamic stream registration" do
      result = run_plugin(
        source: %(ActionCable.server.broadcast("anything", x: 1)\n),
        files: files_with_stream_for_channel,
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      # No unknown-stream warning — the dynamic registration via `stream_for` suppresses it.
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "unknown-stream" }).to be_empty
    end
  end

  describe "configuration" do
    let(:custom_files) do
      {
        "lib/cable/widget_channel.rb" => <<~RUBY
          class WidgetChannel < MyBaseChannel
            def subscribed
              stream_from "widgets"
            end
          end
        RUBY
      }
    end

    let(:custom_plugin_entry) do
      {
        "gem" => "rigor-actioncable",
        "id" => "actioncable",
        "config" => {
          "channel_search_paths" => ["lib/cable"],
          "channel_base_classes" => ["MyBaseChannel"]
        }
      }
    end

    it "respects custom `channel_search_paths` and `channel_base_classes`" do
      result = run_plugin(
        source: %(WidgetChannel.broadcast_to(@thing, x: 1)\n),
        files: custom_files,
        plugin_entry: custom_plugin_entry
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "broadcast-target" }
      expect(info).not_to be_nil
    end
  end

  # ADR-28 provide half: `#receive(data)` is ActionCable's framework-dispatched catch-all action (invoked
  # with the decoded JSON payload when an incoming message carries no explicit "action" key), so `data` is
  # always a Hash. The engine substitutes `Hash` for the usual `Dynamic[Top]` fallback inside a matching
  # `#receive` body, so a misuse surfaces as an ordinary core diagnostic.
  describe "#receive(data) parameter-type provision" do
    let(:body) do
      <<~RUBY
        class %<name>s < ApplicationCable::Channel
          def receive(data)
            data.no_such_actioncable_method
          end
        end
      RUBY
    end

    def core_diagnostics(result)
      result.diagnostics.reject { |d| d.source_family.to_s.start_with?("plugin.") }
    end

    it "surfaces a core diagnostic for data misuse inside a channel's #receive" do
      result = run_plugin(
        source: "# entry point\n",
        files: { "app/channels/typo_channel.rb" => format(body, name: "TypoChannel") },
        paths: ["app/channels/typo_channel.rb"],
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      offending = core_diagnostics(result).select { |d| d.message.include?("no_such_actioncable_method") }
      expect(offending).not_to be_empty
    end

    it "stays silent for the identical body outside channel_search_paths" do
      result = run_plugin(
        source: "# entry point\n",
        files: { "app/models/receive_lookalike.rb" => format(body, name: "ReceiveLookalike") },
        paths: ["app/models/receive_lookalike.rb"],
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      offending = core_diagnostics(result).select { |d| d.message.include?("no_such_actioncable_method") }
      expect(offending).to be_empty
    end

    it "types data as Hash — ordinary Hash usage inside #receive raises no diagnostic" do
      result = run_plugin(
        source: "# entry point\n",
        files: {
          "app/channels/echo_channel.rb" => <<~RUBY
            class EchoChannel < ApplicationCable::Channel
              def receive(data)
                data["body"]
                data.fetch("body", nil)
              end
            end
          RUBY
        },
        paths: ["app/channels/echo_channel.rb"],
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      expect(core_diagnostics(result)).to be_empty
    end
  end

  describe "the channel_search_paths config override" do
    let(:custom_receive_channel) do
      {
        "lib/cable/typo_channel.rb" => <<~RUBY
          class TypoChannel < MyBaseChannel
            def receive(data)
              data.no_such_actioncable_method
            end
          end
        RUBY
      }
    end
    let(:receive_body) do
      <<~RUBY
        class %<name>s < ApplicationCable::Channel
          def receive(data)
            data.no_such_actioncable_method
          end
        end
      RUBY
    end
    let(:multi_root_files) do
      {
        "app/channels/typo_channel.rb" => format(receive_body, name: "TypoChannel"),
        "engines/chat/app/channels/other_typo_channel.rb" => format(receive_body, name: "OtherTypoChannel")
      }
    end

    def core_diagnostics(result)
      result.diagnostics.reject { |d| d.source_family.to_s.start_with?("plugin.") }
    end

    it "retargets the #receive contract to a single custom root" do
      result = run_plugin(
        source: "# entry point\n",
        files: custom_receive_channel,
        paths: ["lib/cable/typo_channel.rb"],
        plugin_entry: {
          "gem" => "rigor-actioncable",
          "id" => "actioncable",
          "config" => { "channel_search_paths" => ["lib/cable"], "channel_base_classes" => ["MyBaseChannel"] }
        }
      )
      offending = core_diagnostics(result).select { |d| d.message.include?("no_such_actioncable_method") }
      expect(offending).not_to be_empty
    end

    it "leaves the default glob non-matching for a custom root" do
      result = run_plugin(
        source: "# entry point\n",
        files: custom_receive_channel,
        paths: ["lib/cable/typo_channel.rb"],
        plugin_entry: DEFAULT_PLUGIN_ENTRY
      )
      offending = core_diagnostics(result).select { |d| d.message.include?("no_such_actioncable_method") }
      expect(offending).to be_empty
    end

    it "covers every configured root when channel_search_paths lists more than one" do
      result = run_plugin(
        source: "# entry point\n",
        files: multi_root_files,
        paths: multi_root_files.keys,
        plugin_entry: {
          "gem" => "rigor-actioncable",
          "id" => "actioncable",
          "config" => {
            "channel_search_paths" => ["app/channels", "engines/chat/app/channels"],
            "channel_base_classes" => ["ApplicationCable::Channel"]
          }
        }
      )
      offending = core_diagnostics(result).select { |d| d.message.include?("no_such_actioncable_method") }
      expect(offending.size).to eq(2)
    end
  end
end
