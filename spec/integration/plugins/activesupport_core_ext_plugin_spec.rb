# frozen_string_literal: true

# Integration spec for `plugins/rigor-activesupport-core-ext/`.
#
# ADR-25 — the bundle is a pure RBS-bundle plugin: its manifest declares `signature_paths: ["sig"]` and the
# plugin loader feeds that directory into the RBS environment. This spec proves the end-to-end path: with the
# plugin active, ActiveSupport `core_ext` selectors type-check instead of producing `call.undefined-method` diagnostics.

require "spec_helper"

unless defined?(AS_CORE_EXT_PLUGIN_LIB)
  AS_CORE_EXT_PLUGIN_LIB = File.expand_path(
    "../../../plugins/rigor-activesupport-core-ext/lib", __dir__
  )
end
$LOAD_PATH.unshift(AS_CORE_EXT_PLUGIN_LIB) unless $LOAD_PATH.include?(AS_CORE_EXT_PLUGIN_LIB)
require "rigor-activesupport-core-ext"

RSpec.describe "plugins/rigor-activesupport-core-ext" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::ActivesupportCoreExt }

  it "is a pure RBS-bundle plugin — the manifest declares signature_paths" do
    expect(plugin_class.manifest.signature_paths).to eq(["sig"])
  end

  it "contributes the core_ext sig so ActiveSupport selectors type-check" do
    source = <<~RUBY
      a = 3.days
      b = "user_account".camelize
      c = Time.current
      d = "  x   y  ".squish
      e = Array.wrap(nil)
      f = { "k" => 1 }.symbolize_keys
      g = nil.blank?
    RUBY
    result = run_plugin(source: source)
    undefined = result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }
    expect(undefined).to be_empty
  end

  it "declares the GitLab-surfaced String / Object / Date / ERB extensions in its RBS bundle" do
    # `upcase_first` / `remove` / `in?` fired `undefined-method` on GitLab once AR typed real String
    # columns; `titlecase` / `dasherize` / `advance` / `all_day` / `Date#to_time(form)` /
    # `ERB::Util.html_escape_once` are the activesupport-core-ext gaps the survey adjudicated. The bundle
    # is validated against `rbs` by the `check-plugins` gate; this locks the specific additions.
    rbs = File.read(
      File.expand_path("../../../plugins/rigor-activesupport-core-ext/sig/active_support/core_ext.rbs", __dir__)
    )
    %w[upcase_first remove titlecase dasherize advance all_day].each do |method|
      expect(rbs).to match(/def #{method}:/), "expected RBS to declare `#{method}`"
    end
    expect(rbs).to include("def in?:")
    # `| ...` and not a plain declaration — see the collision guard below (#437).
    expect(rbs).to include("def to_time: (?Symbol form) -> Time | ...")
    expect(rbs).to include("def self.html_escape_once:")
  end

  # Issue #437. A method the plugin declares in full while a signature source ALREADY in the environment
  # declares it too makes `RBS::DefinitionBuilder` raise `DuplicatedMethodDefinitionError`. Rigor fails
  # soft, so nothing crashes — the whole class just degrades to `Dynamic[top]`, and real methods and typos
  # alike stop being witnessed. `Date#to_time` sat in that state against rbs's bundled `stdlib/date` and
  # took `Date` and `DateTime` down with it for every project following the plugin chapter.
  #
  # The collision is INVISIBLE to a fixture that loads only one signature source, which is exactly how it
  # survived: the plugin's own `sig/` parses and validates fine on its own. So the guard below builds the
  # real environment — `DEFAULT_LIBRARIES` (where rbs's `stdlib/date` enters) PLUS the plugin's `sig/` —
  # and asserts every definition in it builds. That is the shape that catches the NEXT one too.
  describe "collisions against rbs's bundled stdlib (#437)" do
    # Exactly what `Environment.for_project` assembles for a project with the plugin active: it merges
    # `DEFAULT_LIBRARIES` into every run unconditionally, then appends the registry's plugin sig paths.
    # The ADR-72 ActiveSupport gem overlay is deliberately absent — `GEM_OVERLAY_PLUGIN_IDS` stands it
    # down whenever this plugin is loaded, so the two never co-occur.
    let(:env) do
      Rigor::Environment::RbsLoader.build_env_for(
        libraries: Rigor::Environment::DEFAULT_LIBRARIES,
        signature_paths: [File.expand_path("../../../plugins/rigor-activesupport-core-ext/sig", __dir__)]
      )
    end

    let(:builder) { RBS::DefinitionBuilder.new(env: env) }

    it "builds Date and DateTime rather than collapsing them" do
      %w[::Date ::DateTime].each do |name|
        type_name = RBS::TypeName.parse(name)

        expect(builder.build_instance(type_name)).not_to be_nil
        expect(builder.build_singleton(type_name)).not_to be_nil
      end
    end

    # The reason the row is an overload continuation instead of a deletion: dropping it would have left
    # only the stdlib arity, and `date.to_time(:utc)` — correct Rails code — would draw an arity
    # diagnostic. Both arities must resolve, and the ActiveSupport one must keep its `%a{pure}` envelope.
    it "resolves both arities of Date#to_time, with %a{pure} on the ActiveSupport overload" do
      method = builder.build_instance(RBS::TypeName.parse("::Date")).methods[:to_time]
      arities = method.method_types.map { |mt| mt.type.optional_positionals.size }

      expect(arities).to contain_exactly(0, 1)
      expect(method.defs.first.member.annotations.map(&:string)).to include("pure")
    end

    # The sweep: no class or module anywhere in the plugin-active environment may fail to build. This is
    # what generalises past `Date` — every other row in the bundle is checked against rbs's stdlib here,
    # not one at a time as each collapse gets noticed in the field.
    it "builds every class and module in the plugin-active environment" do
      failures = env.class_decls.each_key.with_object([]) do |name, acc|
        builder.build_instance(name)
        builder.build_singleton(name)
      rescue StandardError => e
        acc << "#{name}: #{e.class}: #{e.message.lines.first.to_s.strip}"
      end

      expect(failures).to be_empty
    end

    # End-to-end, through a real run: a degraded class witnesses NOTHING, so a typo on a `Date` receiver
    # going unreported is the observable symptom. This example fails if the plain declaration returns.
    it "still witnesses a typo on a Date receiver" do
      result = run_plugin(source: "Date.today.no_such_method_here\nDateTime.now.no_such_method_here\n")
      undefined = result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }

      expect(undefined.size).to eq(2)
    end
  end
end
