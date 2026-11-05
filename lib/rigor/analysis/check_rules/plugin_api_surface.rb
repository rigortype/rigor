# frozen_string_literal: true

require_relative "../../reflection"
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
      module PluginApiSurface
        PLUGIN_BASE = "Rigor::Plugin::Base"

        # Bounds the superclass walk, which a malformed cyclic source cannot otherwise loop on.
        MAX_SUPERCLASS_HOPS = 32

        module_function

        def diagnostic(path, call_node, facts)
          return nil if call_node.receiver.nil?

          scope = facts.scope
          return nil if scope.nil?

          interfaces = receiver_interfaces(facts.receiver_type)
          return nil if interfaces.nil?

          environment = scope.environment
          method_name = call_node.name
          return nil if interfaces.any? { |interface| declares?(environment, interface, method_name) }
          return nil if object_member?(environment, method_name)
          return nil unless plugin_source?(scope)

          build(path, call_node, interfaces.first, method_name)
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
        # `Rigor::Plugin::Base` body has no superclass to walk, so it is not. An unrecorded nesting (a scope built
        # outside a declaration walk) is not either.
        def plugin_source?(scope)
          nesting = scope.lexical_nesting
          return false if nesting.nil? || nesting.empty?

          nesting.any? { |name| inherits_plugin_base?(scope, name) }
        end

        # Reads through `Scope#superclass_of`, which files the ADR-46 class dependency, so an incremental recheck
        # re-judges the call when a superclass declaration on the chain changes in another file.
        def inherits_plugin_base?(scope, class_name)
          current = class_name.to_s
          MAX_SUPERCLASS_HOPS.times do
            raw = scope.superclass_of(current)
            return false if raw.nil?

            candidates = scope.ancestor_name_candidates(current, raw)
            return true if candidates.include?(PLUGIN_BASE)

            current = candidates.find { |candidate| scope.known_user_class?(candidate) }
            return false if current.nil?
          end
          false
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
