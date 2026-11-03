# frozen_string_literal: true

require "rbs"

# ADR-128 WD4 — the spec-only gate on the plugin API boundary.
#
# A `TracePoint` over `:call` and `:c_call` records every method a frame under `plugins/` or `examples/` calls on
# an engine object that `Rigor::Plugin` exposes through an interface, and every method it calls on a module under
# `Rigor::Inference`. `:c_call` is needed because `attr_reader`s (`self_type`, `environment`, the bucket
# accessors) fire only that event. The gate wraps nothing and costs production nothing; its coverage is whatever
# the plugin specs exercise.
#
# The attribution is by the CALLER frame (a plugin path), never the callee's: a plugin's call into the engine is
# the reach, and the engine calling its own object is not. A recorded method passes when
#
# - it is declared on the interface the object is exposed as (read from `sig/rigor/plugin/interfaces.rbs`, so the
#   RBS stays the one source of truth), or
# - it belongs to the `Object` / `Kernel` / `BasicObject` protocol (`nil?`, `respond_to?`, `is_a?`, `==`, …), or
# - an {ALLOW_LIST} row names it, with the plugin and the filed issue that owns the reach.
#
# Anything else is a violation. `Rigor::Reflection` and `Rigor::Type::Combinator` are public namespaces that a
# plugin reaches by constant as well as through `services`, so a call on them cannot be attributed to the
# interface and they are not watched.
module PluginBoundary
  REPO_ROOT = File.expand_path("../..", __dir__)
  INTERFACES_RBS = File.join(REPO_ROOT, "sig/rigor/plugin/interfaces.rbs")

  # interface name => the runtime class that backs it.
  BACKING = {
    "Rigor::Plugin::_Scope" => "Rigor::Scope",
    "Rigor::Plugin::_Environment" => "Rigor::Environment",
    "Rigor::Plugin::_Services" => "Rigor::Plugin::Services",
    "Rigor::Plugin::_FactStore" => "Rigor::Plugin::FactStore",
    "Rigor::Plugin::_Configuration" => "Rigor::Configuration"
  }.freeze

  # Modules whose methods are engine internals (`public-api.md`: `Rigor::Inference::*`): a plugin frame calling
  # into one is a reach even though no interface backs it.
  INTERNAL_NAMESPACES = ["Rigor::Inference"].freeze

  # A known reach, tracked by an issue. `plugin` is the directory under `plugins/` / `examples/`; `owner` matches
  # the module that owns the called method. A row allows nothing outside its plugins and its owner.
  AllowRow = Data.define(:plugin, :owner, :issue)

  ALLOW_LIST = [
    AllowRow.new(plugin: "rigor-alba", owner: /\ARigor::Inference::DeclarationWalk(::|\z)/,
                 issue: "rigortype/rigor#2708"),
    AllowRow.new(plugin: "rigor-typelizer", owner: /\ARigor::Inference::DeclarationWalk(::|\z)/,
                 issue: "rigortype/rigor#2708")
  ].freeze

  # The protocol every object answers. Reading or writing another object's instance variables is not part of it:
  # that is a reach into its internals, and the gate reports it.
  OBJECT_PROTOCOL = (
    Object.instance_methods + Object.private_instance_methods +
    BasicObject.instance_methods + BasicObject.private_instance_methods + Kernel.instance_methods -
    %i[instance_variable_get instance_variable_set instance_variables]
  ).to_set.freeze

  # Bound by hand: the recorder runs inside traced code, where a `BasicObject` receiver has no `class`, and a class
  # may define `self.name` with parameters.
  CLASS_OF = Kernel.instance_method(:class)
  NAME_OF = Module.instance_method(:name)

  Call = Data.define(:target, :name, :plugin, :location)

  # Raised by {check!}; its message names every reach and the way out.
  class Violation < StandardError; end

  # The plugin integration specs: `spec/integration/plugins/` and `spec/integration/examples/`. Matched on the path
  # RSpec reports for an example (`example.metadata[:file_path]`), which may be relative to the working directory.
  INTEGRATION_SPEC = %r{(?:\A|/)spec/integration/(?:plugins|examples)/}

  module_function

  # Whether an example's spec file is one of the plugin integration specs.
  def integration_spec?(path)
    INTEGRATION_SPEC.match?(path.to_s)
  end

  # Raises {Violation} unless the recorder saw only calls the interfaces, the `Object` protocol or the allow-list
  # account for.
  #
  # `require_root_file:` also fails a recorder none of whose roots holds a file in `$LOADED_FEATURES`, but only when
  # `integration_ran:` says the run executed a plugin integration example (see {integration_spec?}). A gate whose
  # roots match no file checks nothing, and would otherwise pass for want of anything to judge; a run with no
  # integration example has no plugin code to judge at all. It reads what was loaded, never what a plugin called,
  # so a run whose plugins make no engine call still passes.
  def check!(recorder, require_root_file: false, integration_ran: false, **)
    if require_root_file && integration_ran && !recorder.root_file_loaded?
      raise Violation, "the plugin-boundary gate loaded no file under #{recorder.roots.join(', ')}: " \
                       "it checked nothing (wrong roots, or no plugin file was required)"
    end

    found = recorder.violations(**)
    return if found.empty?

    lines = found.sort_by { |c| [c.plugin, c.target, c.name.to_s] }.map do |c|
      "  #{c.plugin}: #{c.target}##{c.name} at #{c.location}"
    end
    raise Violation, <<~MSG
      #{found.size} call(s) from a bundled plugin reach past the plugin-facing interfaces (ADR-128 WD4):
      #{lines.join("\n")}
      Move the plugin onto a method an interface (sig/rigor/plugin/interfaces.rbs) carries, or add a public facade
      for the question it asks. Admit a member to an interface only per ADR-128's admission rule; an engine
      internal that already has a tracking issue goes on PluginBoundary::ALLOW_LIST with that issue.
    MSG
  end

  # interface name => Set of the method names its RBS declares, read from `sig/rigor/plugin/interfaces.rbs`.
  def interface_members(path = INTERFACES_RBS)
    _buffer, _directives, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: path, content: File.read(path)))
    collect_interfaces(decls, "", {})
  end

  def collect_interfaces(decls, prefix, into)
    decls.each do |decl|
      case decl
      when RBS::AST::Declarations::Module
        collect_interfaces(decl.members, "#{prefix}#{decl.name.to_s.delete_prefix('::')}::", into)
      when RBS::AST::Declarations::Interface
        names = decl.members.grep(RBS::AST::Members::MethodDefinition).map { |m| m.name.to_s }
        into["#{prefix}#{decl.name}"] = names.to_set
      end
    end
    into
  end

  # Records the calls a plugin frame makes into the engine while the block runs.
  class Recorder
    attr_reader :calls, :roots

    # roots: absolute directories whose files count as plugin code (`<repo>/plugins`, `<repo>/examples`).
    def initialize(roots: [File.join(REPO_ROOT, "plugins"), File.join(REPO_ROOT, "examples")])
      @roots = roots.map { |root| File.join(File.expand_path(root), "") }
      @backing = BACKING.values.to_h { |name| [name, Object.const_get(name)] }
      @calls = {}
      @by_class = {}.compare_by_identity
      @module_targets = {}.compare_by_identity
      @trace = TracePoint.new(:call, :c_call) { |event| observe(event) }
    end

    def record(&)
      @trace.enable(&)
      self
    end

    def start = @trace.enable
    def stop = @trace.disable

    # Calls that no interface member, `Object` protocol entry or allow-list row accounts for.
    def violations(members: PluginBoundary.interface_members, allow_list: ALLOW_LIST)
      by_backing = BACKING.to_h { |iface, klass| [klass, members.fetch(iface)] }
      calls.values.reject do |call|
        OBJECT_PROTOCOL.include?(call.name) ||
          by_backing[call.target]&.include?(call.name.to_s) ||
          allow_list.any? { |row| row.plugin == call.plugin && row.owner.match?(call.target) }
      end
    end

    # Whether a file under one of the roots has been required: the one fact the liveness check reads.
    def root_file_loaded?
      $LOADED_FEATURES.any? { |feature| @roots.any? { |root| feature.start_with?(root) } }
    end

    private

    # The hot path: it runs for every Ruby and C call in the process, so a receiver nothing watches is turned away
    # on one identity-hash lookup, before any caller frame is read.
    def observe(event)
      recv = event.self
      klass = CLASS_OF.bind_call(recv)
      kind = @by_class.fetch(klass) { @by_class[klass] = classify(klass) }
      return unless kind

      target = kind == :module ? module_target(recv) : kind
      target = internal_owner(event) if target == :internal
      return unless target

      location, plugin = plugin_caller(event)
      return unless plugin

      name = event.callee_id || event.method_id
      @calls[[target, name, plugin]] ||= Call.new(target: target, name: name, plugin: plugin, location: location)
    end

    # What a receiver's class means for the recorder: the backing class name (an instance of an interface's class),
    # `:module` (a Module or Class, whose own name decides per receiver), `:internal` (a class with an
    # `Rigor::Inference` ancestor, whose method's owner decides), or nil (nothing to record).
    def classify(klass)
      return :module if [Module, Class].include?(klass)

      @backing.each { |name, backing| return name if klass <= backing }
      :internal if klass.ancestors.any? { |mod| internal_name(NAME_OF.bind_call(mod)) }
    end

    # A call on a module or class: a backing class itself, or a module under {INTERNAL_NAMESPACES}.
    def module_target(recv)
      @module_targets.fetch(recv) do
        @module_targets[recv] = backing_name(recv) || internal_name(NAME_OF.bind_call(recv))
      end
    end

    # The module that owns the called method, when it is under {INTERNAL_NAMESPACES}.
    def internal_owner(event)
      owner = event.defined_class
      named = owner.singleton_class? && Module === event.self ? event.self : owner # rubocop:disable Style/CaseEquality
      internal_name(NAME_OF.bind_call(named))
    end

    def backing_name(mod)
      @backing.each { |name, backing| return name if backing.equal?(mod) }
      nil
    end

    def internal_name(name)
      return nil unless name

      name if INTERNAL_NAMESPACES.any? { |ns| name == ns || name.start_with?("#{ns}::") }
    end

    # [location string, plugin directory name] for the frame that made the call, or nil when it is not a plugin's.
    def plugin_caller(event)
      # `:c_call` reports the caller's own file and line; `:call` reports the callee's, so its caller is one up.
      path, lineno = if event.event == :c_call
                       [event.path, event.lineno]
                     else
                       frame = caller_locations(4, 1)&.first
                       [frame&.absolute_path || frame&.path, frame&.lineno]
                     end
      return unless path

      root = @roots.find { |r| path.start_with?(r) }
      return unless root

      ["#{path.delete_prefix("#{REPO_ROOT}/")}:#{lineno}", path.delete_prefix(root).split("/", 2).first]
    end
  end
end
