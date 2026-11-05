# frozen_string_literal: true

require "prism"

require_relative "../../configuration/severity_profile"
require_relative "../../reflection"
require_relative "../../source/node_walker"
require_relative "../../scope/resolution_chain"
require_relative "../../type"
require_relative "../diagnostic"
require_relative "rule_ids"

module Rigor
  module Analysis
    module CheckRules
      # ADR-128 WD6 / ADR-130 WD3 — `plugin.api-surface`. A call in plugin source on a value typed by a
      # `Rigor::Plugin` interface (`Dynamic[Rigor::Plugin::_Scope]`, ...) to a member that interface does not
      # declare. The method exists on the backing engine class, so the call works today; it is outside what Rigor
      # promises to keep, so `call.undefined-method` would be wrong and this rule says that instead.
      #
      # Authored `:warning`, resolved `:off` by every profile and promoted only by the `plugin-api-surface`
      # bleeding-edge feature (ADR-50 Decision 3, WD2), as `static.value-use.void` is.
      #
      # It fires only where all of these hold:
      #
      # - the call has an explicit receiver, typed `Dynamic[<Rigor::Plugin interface>]`, or that plus `nil` (the
      #   facet survives only where ADR-130 WD1 keeps it; a value that lost it at a join reads `Dynamic[top]`);
      # - the interface declares no member of the name, and `Object` (with `Kernel` and `BasicObject`) declares
      #   none either: `nil?`, `respond_to?` and `is_a?` are every object's surface, not the engine's;
      # - the call sits lexically inside a class whose discovered superclass chain reaches `Rigor::Plugin::Base`.
      #   `Base` itself is not such a class, so its own hooks, which hand interface values to engine helpers
      #   (`environment.class_ordering`), are not judged: they are engine code.
      #
      # The plugin-source test reads the class declarations, not a path: a third-party plugin gem keeps its plugin
      # under `lib/` as Rigor's own engine does.
      #
      # The rule runs only when its resolved severity is not `:off` ({.active?}): the runner then adds its
      # {Collector} to the shared {RuleWalk}. A default run builds no collector, so it types no extra receiver and
      # files no ADR-46 dependency for the rule.
      module PluginApiSurface
        PLUGIN_BASE = "Rigor::Plugin::Base"

        # One call the rule reports: the call and the first interface its receiver carries.
        Result = Data.define(:call_node, :interface)

        # The {RuleWalk} collector: one {Result} per reported call, in walk order.
        class Collector
          NODE_CLASSES = [Prism::CallNode].freeze

          def initialize(scope_index)
            @scope_index = scope_index
            @results = []
          end

          # The legacy single-collector walk, the oracle the ADR-53 equivalence harness compares {RuleWalk} with.
          def collect(root)
            Source::NodeWalker.each(root) { |node| visit(node) if node.is_a?(Prism::CallNode) }
            @results.freeze
          end

          def visit(node, _context = nil)
            interface = PluginApiSurface.outside_interface(node, @scope_index[node])
            @results << Result.new(call_node: node, interface: interface) if interface
          end

          def results
            @results.freeze
          end
        end

        module_function

        # Whether the rule can report in a run under `configuration`: it is not in `disable:`, and its resolved
        # severity is not `:off`. Default profiles resolve it `:off`; the `plugin-api-surface` bleeding-edge feature
        # or an explicit `severity_overrides:` entry for the id turns it on.
        def active?(configuration)
          disabled = configuration.disabled_rules
          return false if disabled.include?(RULE_PLUGIN_API_SURFACE) || disabled.include?("all")

          Configuration::SeverityProfile.resolve(
            rule: RULE_PLUGIN_API_SURFACE, authored_severity: :warning,
            profile: configuration.severity_profile, overrides: configuration.severity_overrides,
            bleeding_edge_overrides: configuration.bleeding_edge_severity_overrides
          ) != :off
        end

        # The interface the call's receiver carries when the call is outside it, or nil.
        def outside_interface(call_node, scope)
          return nil if call_node.receiver.nil? || scope.nil?

          interfaces = receiver_interfaces(scope.type_of(call_node.receiver))
          return nil if interfaces.nil?

          environment = scope.environment
          method_name = call_node.name
          return nil if interfaces.any? { |interface| declares?(environment, interface, method_name) }
          return nil if object_member?(environment, method_name)
          return nil unless plugin_source?(scope)

          interfaces.first
        end

        def diagnostics(path, results)
          results.map { |result| build(path, result.call_node, result.interface, result.call_node.name) }
        end

        # The interface facets the receiver carries, or nil when it is anything but `Dynamic[Interface]` arms and
        # `nil`. A union whose non-nil arms include another type has a member the call may resolve on.
        def receiver_interfaces(type)
          case type
          when Type::Dynamic
            facet = type.static_facet
            [facet] if facet.is_a?(Type::Interface)
          when Type::Union
            union_interfaces(type)
          end
        end

        def union_interfaces(union)
          interfaces = []
          union.members.each do |member|
            next if nil_type?(member)
            return nil unless member.is_a?(Type::Dynamic) && member.static_facet.is_a?(Type::Interface)

            interfaces << member.static_facet
          end
          interfaces.empty? ? nil : interfaces
        end

        def nil_type?(type)
          (type.is_a?(Type::Constant) && type.value.nil?) ||
            (type.is_a?(Type::Nominal) && type.class_name == "NilClass")
        end

        # An interface that does not resolve declares nothing the rule can read, so it is treated as declaring
        # every member. A guard: the carrier exists only for an interface the loader translated, so no fixture
        # reaches it.
        def declares?(environment, interface, method_name)
          definition = environment.rbs_loader.interface_definition(interface.name)
          return true if definition.nil?

          definition.methods.key?(method_name.to_sym)
        end

        def object_member?(environment, method_name)
          !Rigor::Reflection.instance_method_definition("Object", method_name, environment: environment).nil?
        end

        # Whether the call is plugin source: lexically inside a class that inherits `Rigor::Plugin::Base`. A
        # `Rigor::Plugin::Base` body is not: its chain holds `Base` only as itself. An unrecorded nesting (a scope
        # built outside a declaration walk) is not either.
        def plugin_source?(scope)
          nesting = scope.lexical_nesting
          return false if nesting.nil? || nesting.empty?

          nesting.any? { |name| inherits_plugin_base?(scope, name) }
        end

        # Whether `class_name`'s instance chain ({Scope::ResolutionChain}, the one ancestry reader) holds
        # `Rigor::Plugin::Base` below the class itself. Reading it files the ADR-46 class dependencies, so
        # an incremental recheck re-judges the call when a declaration on the chain changes in another file. A
        # truncated chain reads as no plugin: the rule withholds where it cannot see the whole chain.
        def inherits_plugin_base?(scope, class_name)
          root = class_name.to_s
          chain = Scope::ResolutionChain.for(scope, root, :instance, :methods)
          chain.record(scope)
          return false if chain.truncated?

          chain.entries.any? { |entry| entry.name != root && plugin_base_entry?(entry) }
        end

        # `Rigor::Plugin::Base` is external where only its RBS and the gem declare it, and a project entry where the
        # analysed tree holds its source (Rigor's own `lib`, or a reopen).
        def plugin_base_entry?(entry)
          entry.external? ? entry.candidates.include?(PLUGIN_BASE) : entry.name == PLUGIN_BASE
        end

        def build(path, call_node, interface, method_name)
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_PLUGIN_API_SURFACE,
            path: path,
            message: "`#{method_name}' is not part of the plugin API: `#{interface.describe}' does not declare it. " \
                     "The engine object answers it today, but Rigor does not promise to keep it; call a member the " \
                     "interface declares (sig/rigor/plugin/interfaces.rbs) or a public namespace " \
                     "(docs/internal-spec/public-api.md)",
            severity: :warning,
            receiver_type: nil,
            method_name: method_name
          )
        end
      end
    end
  end
end
