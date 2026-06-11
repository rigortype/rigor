# frozen_string_literal: true

require "spec_helper"

# Structural guard: EVERY bundled plugin (`plugins/*`) and example
# (`examples/*`) that overrides a `Rigor::Plugin::Base` contract hook
# must override it with a *call-compatible* signature — one the engine
# can actually invoke the way it invokes the base method.
#
# This is the rule-based half of "constrain plugin files with the
# contract" (ADR-37). The RBS half (`sig/rigor/plugin/base.rbs`) lets
# Steep / `rigor check lib` check Base's own implementation, but neither
# tool enforces override compatibility on a plugin subclass that ships
# no RBS of its own: Steep types `self` as the bare `Base` (so it would
# false-positive on every call to the plugin's *own* un-RBS'd helper
# methods, which is why a strict Steep target over the plugin tree is
# not viable), and `rigor check` does not exercise the plugin tree.
#
# A pure-Ruby `Method#parameters` comparison sidesteps both problems: it
# needs no per-plugin RBS, raises no false positive on a plugin's own
# methods, and catches the one violation that actually breaks a plugin
# at runtime — an override that cannot receive the engine's call (e.g.
# `def diagnostics_for_file(path:)` dropping the required `scope:` /
# `root:` keywords, which raises `ArgumentError` the moment the runner
# dispatches the file).
#
# The check is deliberately lenient on the override side per the
# robustness principle (ADR-5, Postel's law for types): a wider override
# — extra optional positionals, a `*rest`, extra optional keywords, or a
# `**keyrest` catch-all — is always accepted. Only a *narrower* override
# (one that omits a parameter the engine supplies, or demands one it
# does not) fails.

CONTRACT_REPO_ROOT = File.expand_path("../..", __dir__)

CONTRACT_PLUGIN_DIRS = (
  Dir[File.join(CONTRACT_REPO_ROOT, "plugins", "*", "")] +
  Dir[File.join(CONTRACT_REPO_ROOT, "examples", "*", "")]
).sort.freeze

# `rigor-playground` is a Rack app, not a plugin (mirrors
# `all_plugins_load_spec.rb`).
CONTRACT_PLUGIN_SKIP = %w[rigor-playground].freeze

CONTRACT_LOADABLE_DIRS = CONTRACT_PLUGIN_DIRS.reject do |dir|
  CONTRACT_PLUGIN_SKIP.include?(File.basename(dir))
end.freeze

# The author-overridable hooks on `Plugin::Base`. The engine invokes
# each with a fixed argument shape; an override must stay callable with
# it. The required shape is derived from Base's *own* parameters at run
# time, so changing Base's signature carries the contract automatically.
CONTRACT_OVERRIDABLE_HOOKS = %i[init prepare diagnostics_for_file].freeze

# Put every plugin's lib on the load path so meta-gem entries resolve
# regardless of example order (same prelude as the load guard).
CONTRACT_LOADABLE_DIRS.each do |dir|
  lib = File.join(dir, "lib")
  $LOAD_PATH.unshift(lib) if Dir.exist?(lib) && !$LOAD_PATH.include?(lib)
end

RSpec.describe "plugin contract hook-override conformance (structural guard)" do
  # Decompose a `Method#parameters` list into the call surface we need.
  # `params` is an Array of `[kind, name]` pairs, not a Hash.
  def parameter_shape(params)
    {
      req_positional: params.count { |kind, _| kind == :req },
      opt_positional: params.count { |kind, _| kind == :opt },
      rest: params.any? { |kind, _| kind == :rest },
      req_keywords: params.filter_map { |kind, name| name if kind == :keyreq },
      opt_keywords: params.filter_map { |kind, name| name if kind == :key },
      keyrest: params.any? { |kind, _| kind == :keyrest }
    }
  end

  # True when a method with `override` parameters can receive a call that
  # passes `positional` positional arguments and exactly the `keywords`
  # set — the call the engine makes (read off Base's own signature).
  def callable_with?(override, positional:, keywords:)
    shape = parameter_shape(override)

    # Positional: the override must not demand more than supplied, and
    # (absent a *rest) must have room for all supplied.
    return false if shape[:req_positional] > positional
    return false if !shape[:rest] && (shape[:req_positional] + shape[:opt_positional]) < positional

    # Keywords: every keyword the override *requires* must be supplied,
    # and every keyword the engine supplies must be accepted (named or
    # absorbed by **keyrest).
    return false unless (shape[:req_keywords] - keywords).empty?
    return false if !shape[:keyrest] && !(keywords - (shape[:req_keywords] + shape[:opt_keywords])).empty?

    true
  end

  # The engine's call shape for `hook`, derived from Base's signature:
  # the positional count and the union of keyword names Base declares.
  def engine_call_shape(hook)
    base = parameter_shape(Rigor::Plugin::Base.instance_method(hook).parameters)
    {
      positional: base[:req_positional],
      keywords: base[:req_keywords] + base[:opt_keywords]
    }
  end

  def plugin_classes
    Rigor::Plugin.constants
                 .map { |const| Rigor::Plugin.const_get(const) }
                 .select { |value| value.is_a?(Class) && value < Rigor::Plugin::Base }
  end

  # Idempotent: `require` no-ops after the first load, so calling this
  # per example is cheap and avoids a state-leaking `before(:all)`.
  before do
    CONTRACT_LOADABLE_DIRS.each do |dir|
      entry = File.join(dir, "lib", "#{File.basename(dir)}.rb")
      require entry if File.file?(entry)
    end
  end

  CONTRACT_OVERRIDABLE_HOOKS.each do |hook|
    describe "##{hook} overrides" do
      it "are all callable with the engine's invocation" do
        call = engine_call_shape(hook)

        offenders = plugin_classes.filter_map do |klass|
          method = klass.instance_method(hook)
          # Only check classes that actually OVERRIDE the hook — an
          # inherited Base method trivially conforms.
          next if method.owner == Rigor::Plugin::Base

          next if callable_with?(method.parameters, positional: call[:positional], keywords: call[:keywords])

          "#{klass}##{hook}#{method.parameters.inspect}"
        end

        expect(offenders).to(
          be_empty,
          "these overrides cannot receive the engine call " \
          "#{hook}(positional=#{call[:positional]}, keywords=#{call[:keywords].inspect}): " \
          "#{offenders.join(', ')}"
        )
      end
    end
  end
end
