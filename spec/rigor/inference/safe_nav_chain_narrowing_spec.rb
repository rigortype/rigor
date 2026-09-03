# frozen_string_literal: true

require "spec_helper"

# Issue #606 slice 1 — safe-nav CHAIN narrowing, pinned at the diagnostic level because the
# contract is the absence of a `call.possible-nil-receiver` false positive, not the shape of an
# intermediate scope. `Narrowing.analyse_safe_nav_receiver` already proved the receiver non-nil
# when the `&.` call IS the predicate (`if v&.foo`); these are the shapes where its result is fed
# to one more call, which is what real guards look like.
#
# Every must-narrow example is a minimal model of a site that #574's measurement round adjudicated
# as a false positive on mastodon, named in the example. Each is paired with a sibling that must
# KEEP firing, because the interesting half of this change is where the proof stops:
#
#   - `x&.y.nil?` narrows on the FALSEY edge, never the truthy one — `nil.nil?` is `true`, so a
#     truthy answer is exactly what a nil root produces.
#   - `x&.y == nil` narrows on neither — a nil root makes that comparison TRUE.
#   - a plain `x.y.present?` chain narrows on neither, because `x.y` is itself the latent nil bug
#     the rule exists to report.
RSpec.describe "safe-nav chain narrowing (#606 slice 1)" do
  def nil_receiver_diagnostics(source)
    runner = Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
    diagnostics = guarded_run_source(runner, source: source, path: "mem.rb").diagnostics
    diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
  end

  # A project class, so the union's non-nil arm is a genuine witness (`value` / `updated_at` are
  # discovered defs). Without that the rule would decline for an unrelated reason and every
  # example below would pass vacuously — the `control` examples exist to keep that honest.
  #
  # The readers deliberately return an ivar rather than a literal. A first draft returned `"x"`,
  # which made `s&.value` a `Constant`, so `.length` folded to `1` and `.start_with?("x")` to
  # `true`: the guard became statically decidable, the branch was elided, and two examples were
  # then measuring dead-code removal rather than narrowing — one falsely red, one falsely green.
  # Nothing here may constant-fold.
  def setting_class
    <<~RUBY
      class Setting
        def initialize(v, t)
          @v = v
          @t = t
        end

        def value
          @v
        end

        def updated_at
          @t
        end
      end
    RUBY
  end

  # `a` / `b` feed the constructor so the readers stay opaque; `a` also supplies the unprovable
  # operand the equality form must decline on.
  def with_setting(body)
    "#{setting_class}\ndef f(c, a, b)\n  s = c ? Setting.new(a, b) : nil\n#{body}\nend\n"
  end

  describe "must narrow" do
    # mastodon app/models/extended_description.rb:10 and app/models/privacy_policy.rb:13 (2 sites
    # each). `present?` is the one NilClass method the chain rule trusts to be falsey on nil.
    it "narrows on a truthy `custom&.value.present?` chain" do
      source = with_setting(<<~RUBY)
        if s&.value.present?
          s.value
          s.updated_at
        end
      RUBY
      expect(nil_receiver_diagnostics(source)).to be_empty
    end

    # The raise-based half of the proof: `length` is not a NilClass method, so a nil root makes
    # the guard itself raise and the branch is never entered. Same soundness, different reason —
    # this is what carries chains whose suffix is an ordinary reader rather than `present?`.
    it "narrows on a truthy chain whose suffix NilClass does not define" do
      source = with_setting(<<~RUBY)
        if s&.value.length
          s.value
        end
      RUBY
      expect(nil_receiver_diagnostics(source)).to be_empty
    end

    # mastodon app/workers/backup_worker.rb:23,27 — the guard returns, so the protected code is on
    # the FALL-THROUGH: `backup&.user` is not nil, which no nil `backup` can produce.
    it "narrows the fall-through of `return if backup&.user.nil?`" do
      source = with_setting(<<~RUBY)
        return true if s&.value.nil?

        s.value
      RUBY
      expect(nil_receiver_diagnostics(source)).to be_empty
    end

    it "narrows a safe-nav chain compared to a non-nil literal" do
      source = with_setting(<<~RUBY)
        return unless s&.value == "x"

        s.value
      RUBY
      expect(nil_receiver_diagnostics(source)).to be_empty
    end

    # `!=` proves the root non-nil on the opposite edge, for the same reason `nil?` does: a nil
    # root makes `nil != "x"` TRUE, so it is the falsey edge that excludes it.
    it "narrows the falsey edge of `x&.y != <non-nil literal>`" do
      source = with_setting(<<~RUBY)
        return if s&.value != "x"

        s.value
      RUBY
      expect(nil_receiver_diagnostics(source)).to be_empty
    end
  end

  describe "must NOT narrow" do
    it "does not narrow the TRUTHY edge of `x&.y.nil?` (a nil root is what makes it true)" do
      source = with_setting(<<~RUBY)
        if s&.value.nil?
          s.value
        end
      RUBY
      expect(nil_receiver_diagnostics(source).size).to eq(1)
    end

    it "does not narrow on `x&.y == nil` (a nil root makes the comparison true)" do
      source = with_setting(<<~RUBY)
        return unless s&.value == nil

        s.value
      RUBY
      expect(nil_receiver_diagnostics(source).size).to eq(1)
    end

    # mastodon app/services/activitypub/fetch_featured_collection_service.rb:37 — the one site of
    # #574's seven this slice deliberately does NOT fix. `other.value` types opaque, and an opaque
    # operand may be nil at runtime, in which case `nil == nil` is true and a nil root reaches the
    # branch. Declining here is the whole reason `provably_non_nil_type?` is a whitelist.
    it "does not narrow when the compared operand cannot be proved non-nil" do
      source = with_setting(<<~RUBY)
        return unless s&.value == a.value

        s.value
      RUBY
      expect(nil_receiver_diagnostics(source).size).to eq(1)
    end

    it "does not narrow a plain (non-safe-nav) chain — `x.y` is itself the bug to report" do
      source = with_setting(<<~RUBY)
        if s.value.length
          s.value
        end
      RUBY
      expect(nil_receiver_diagnostics(source)).not_to be_empty
    end

    it "does not narrow when the chain suffix takes a block" do
      source = with_setting(<<~RUBY)
        if s&.value.then { |v| v }
          s.value
        end
      RUBY
      expect(nil_receiver_diagnostics(source).size).to eq(1)
    end
  end

  describe "controls" do
    # Without these the "must narrow" group could pass because the rule stopped firing for an
    # unrelated reason (no witness, fixture unanalysed, rule renamed).
    it "still fires on an unguarded nilable local" do
      source = with_setting(<<~RUBY)
        s.value
      RUBY
      diags = nil_receiver_diagnostics(source)
      expect(diags.size).to eq(1)
      expect(diags.first.message).to eq("possible nil receiver: `value' is undefined on NilClass")
    end

    it "still fires AFTER a narrowed branch closes" do
      source = with_setting(<<~RUBY)
        if s&.value.present?
          s.value
        end
        s.updated_at
      RUBY
      diags = nil_receiver_diagnostics(source)
      expect(diags.size).to eq(1)
      expect(diags.first.message).to include("updated_at")
    end
  end
end
