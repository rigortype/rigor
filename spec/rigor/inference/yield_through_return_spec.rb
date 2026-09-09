# frozen_string_literal: true

# Issue #720 — a method whose value comes from a callee that `yield`s.
#
# `yield` evaluates the block the CALLER passed, so when a body is re-typed on behalf of one call site the
# block's value type is what `yield` produces. Before the fix `yield` was unconditionally `Dynamic[top]`, so
# `during_internal_demand { … }` was `untyped` at every position and `sig-gen` declined the whole method on
# `:untyped_return` — while the SAME logic written inline was emitted. The wrapper is the idiom for a scoped
# concern (`with_run`, save/restore, instrumentation), so the opacity spread outward from a shape chosen for
# good design reasons.
#
# The false-positive bound is the point of the negative arms below: the block's type reaches the caller only
# because the callee's body EVALUATES to the yield. A wrapper that yields for effect and answers with its own
# value keeps that value — nothing here makes a return concrete by pattern-matching "this method yields".
RSpec.describe "yield-through return inference" do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  def write_fixture(rel_path, contents)
    full = File.join(tmpdir, rel_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, contents)
    full
  end

  # `{ method_name => emitted RBS }` for every method `sig-gen` would write, so an example can assert both
  # what a signature says and that a method was skipped (absent from the hash).
  def emitted_signatures(source)
    path = write_fixture("lib/fixture.rb", source)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => [path])
    )
    candidates = Rigor::SigGen::Generator.new(configuration: configuration, paths: [path]).run
    candidates.each_with_object({}) do |candidate, map|
      # A skipped candidate is still reported, carrying no RBS; dropping it here is what makes an absent key
      # mean "sig-gen declined this method".
      map[candidate.method_name] = candidate.rbs if candidate.rbs
    end
  end

  # The issue's own four-variant fixture: one yielding helper with a `rescue` and one without, then the four
  # spellings of the same logic.
  def four_variants
    <<~RUBY
      class Loader
        def during_internal_demand
          yield
        end

        def guarded
          yield
        rescue StandardError
          []
        end

        def via_guarded_helper(name)
          guarded do
            [name.to_s]
          end
        end

        def inlined(name)
          [name.to_s]
        rescue StandardError
          []
        end

        def local_from_helper(name)
          result = during_internal_demand do
            [name.to_s]
          end
          result
        end

        def via_plain_helper(name)
          during_internal_demand do
            [name.to_s]
          end
        end
      end
    RUBY
  end

  # Three callees a fix that keyed on "this method yields" would type as their caller's block.
  def negative_arms
    <<~RUBY
      class Wrapper
        def announce
          yield
          "done"
        end

        def counted
          yield
          42
        end

        def plain
          "plain"
        end

        def uses_announce
          announce { [1, 2, 3] }
        end

        def uses_counted
          counted { "str" }
        end

        def uses_plain
          plain { [1, 2, 3] }
        end
      end
    RUBY
  end

  # The issue's own four-variant table, which is what isolates the defect: the inlined variant was emitted
  # while all three yield-through spellings were skipped, so the gap was never about the `rescue` and never
  # about the local.
  describe "the issue's four variants" do
    {
      # shape                                          => emitted RBS
      "value of a helper that yields (the shipped shape)" =>
        [:via_guarded_helper, "def via_guarded_helper: (untyped) -> ([untyped] | [])"],
      "the same logic inlined, rescue kept" =>
        [:inlined, "def inlined: (untyped) -> [untyped]"],
      "the helper's value assigned to a local, then returned" =>
        [:local_from_helper, "def local_from_helper: (untyped) -> [untyped]"],
      "yield-through, no rescue" =>
        [:via_plain_helper, "def via_plain_helper: (untyped) -> [untyped]"]
    }.each do |shape, (method_name, rbs)|
      it "emits a signature for #{shape}" do
        expect(emitted_signatures(four_variants)[method_name]).to eq(rbs)
      end
    end

    # The `guarded` arm carries the rescue's `[]` because the WHOLE callee body is re-typed, not just its
    # `yield`; nothing special-cases the exception handler.
    it "keeps the yielding helpers themselves untyped" do
      # A helper's own signature is `[T] () { () -> T } -> T`, which is a generic this fix does not produce —
      # with no caller there is no block, so `yield` stays `Dynamic[top]` and sig-gen still declines.
      emitted = emitted_signatures(four_variants)

      expect(emitted).not_to have_key(:during_internal_demand)
      expect(emitted).not_to have_key(:guarded)
    end
  end

  it "carries a precise block value through the wrapper" do
    source = <<~RUBY
      class Loader
        def during_internal_demand
          yield
        end

        def label
          during_internal_demand do
            "ready"
          end
        end
      end
    RUBY

    expect(emitted_signatures(source)[:label]).to eq('def label: () -> "ready"')
  end

  # The false-positive arm. A fix that propagated on "the callee yields" rather than on "the callee's value IS
  # the yield" would type every one of these as the block's value.
  describe "a callee whose value is not its block's" do
    {
      "a helper that yields for effect and answers with its own value" =>
        [:uses_announce, 'def uses_announce: () -> "done"'],
      "a helper that substitutes a value after yielding" =>
        [:uses_counted, "def uses_counted: () -> 42"],
      "a helper that never yields, called with a block anyway" =>
        [:uses_plain, 'def uses_plain: () -> "plain"']
    }.each do |shape, (method_name, rbs)|
      it "leaves #{shape} unchanged" do
        expect(emitted_signatures(negative_arms)[method_name]).to eq(rbs)
      end
    end
  end

  describe "the shapes the whole-body re-typing covers for free" do
    it "unions a conditional yield with the nil the guard falls through to" do
      source = <<~RUBY
        class Wrapper
          def maybe
            yield if block_given?
          end

          def uses_maybe
            maybe { "s" }
          end
        end
      RUBY

      expect(emitted_signatures(source)[:uses_maybe]).to eq('def uses_maybe: () -> ("s" | nil)')
    end

    it "reads a `yield` written inside a nested block as this method's block" do
      # Ruby binds `yield` to the enclosing METHOD's block, not to whatever block encloses it lexically, so
      # the reachability scan that gates the propagation must cross a `BlockNode`.
      source = <<~RUBY
        class Wrapper
          def each_through
            [1].map { yield }
          end

          def uses_each_through
            each_through { "e" }
          end
        end
      RUBY

      expect(emitted_signatures(source)[:uses_each_through]).to eq('def uses_each_through: () -> ["e"]')
    end

    it "does not let a blockless callee reached from a yielding body see the outer block" do
      # `inner` is re-typed while `outer`'s frame is live; its own `yield` names a block `outer` never passed
      # it, so the frame installed for `inner` must be empty rather than inherited.
      source = <<~RUBY
        class Wrapper
          def inner
            yield
          end

          def outer
            yield
            inner_value = inner
            inner_value
          end

          def uses_outer
            outer { "block" }
          end
        end
      RUBY

      expect(emitted_signatures(source)).not_to have_key(:uses_outer)
    end
  end

  describe "two call sites of the same wrapper" do
    it "keeps their block types apart" do
      # The return memo is keyed per call site's block type; without that dimension the first site to reach
      # the def would serve its answer to the second.
      source = <<~RUBY
        class Wrapper
          def wrap
            yield
          end

          def a_site
            wrap { "text" }
          end

          def b_site
            wrap { 7 }
          end
        end
      RUBY

      emitted = emitted_signatures(source)

      expect(emitted[:a_site]).to eq('def a_site: () -> "text"')
      expect(emitted[:b_site]).to eq("def b_site: () -> 7")
    end
  end
end
