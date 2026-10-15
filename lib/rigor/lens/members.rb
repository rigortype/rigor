# frozen_string_literal: true

require_relative "slot"
require_relative "parameters"

module Rigor
  module Lens
    # Groups the sites of the requested files into members and fills their signatures (docs/internal-spec/lens.md
    # § Members). A member is one `(owner, scope, Ruby method name)`; an `attr_accessor :a` site defines `a` and
    # `a=`. An inferred slot comes from a site's body only when the member has exactly one project definition.
    class Members
      # @param sites — every {FileReader::Site} of the requested files
      # @param omissions — every omission of the requested files
      # @param contracts — `{[owner, scope, name] => ContractReader::Contract or nil}`
      # @param elsewhere — callable `(owner, scope, name) -> [{path, line}]`: other project files defining it
      # @param site_paths — `{site key => absolute path of its file}`, to match an inline contract's buffer
      def initialize(sites:, omissions:, contracts:, elsewhere:, site_paths:)
        @sites = sites
        @omissions = omissions
        @contracts = contracts
        @elsewhere = elsewhere
        @site_paths = site_paths
      end

      def build
        groups = Hash.new { |hash, key| hash[key] = [] }
        @sites.each do |site|
          Members.scopes_of(site.data).each do |scope|
            site.data["members"].each { |name| groups[[site.data["owner"], scope, name]] << site }
          end
        end
        result = groups.sort_by { |key, _| key }.map { |key, sites| member(key, sites) }
        mark_inline_sites
        result
      end

      # The scopes a site's members live in: a module function (`module_function`) defines a private instance method
      # and a public singleton copy from one `def`.
      def self.scopes_of(data)
        data["module_function"] ? %w[instance singleton] : [data["scope"]]
      end

      private

      def member(key, sites)
        owner, scope, name = key
        contract = @contracts[key]
        also = @elsewhere.call(owner, scope, name)
        omitted = @omissions.count { |omission| [omission["owner"], omission["scope"], omission["name"]] == key }
        single = sites.size == 1 && omitted.zero? && also.empty? ? sites.first : nil
        { "owner" => owner, "scope" => scope, "name" => name, "kind" => member_kind(sites),
          "visibility" => common_visibility(sites, scope), "sites" => sites.map { |site| site.data["key"] },
          "also_defined_at" => also, "basis" => basis(contract, single),
          "overloads" => overloads(contract, sites.first, name, single, scope) }
      end

      # A member a `def` defines anywhere in the requested files is a method, whatever `attr_*` also names it.
      def member_kind(sites)
        sites.any? { |site| site.data["kind"] == "method" } ? "method" : "attribute"
      end

      def basis(contract, single)
        return "contract" if contract
        return "single_site" if single

        "contested"
      end

      # A module function's singleton copy is public; its instance method carries the site's (private) visibility.
      def common_visibility(sites, scope)
        values = sites.map do |site|
          copy = site.data["module_function"] && scope == "singleton"
          copy ? site.data["singleton_visibility"] : site.data["visibility"]
        end.uniq
        values.size == 1 ? values.first : nil
      end

      # A contested member without a contract has no overloads: its definitions may differ in arity, and each
      # method site carries its own parameter list.
      def overloads(contract, site, name, single, scope)
        return [] if contract.nil? && single.nil?

        overloads = contract ? contract_overloads(contract, single, scope) : [body_overload(site, name, single, scope)]
        overloads.map { |overload| overload.merge("rbs" => rbs_unless_unavailable(overload)) }
      end

      # A contract's overloads. A defaulted return (`inferred-return`) is inferred as for a member without a
      # contract, and its `untyped` parameters are unknown: Rigor cannot tell an authored `untyped` from a
      # defaulted one.
      def contract_overloads(contract, single, scope)
        contract.overloads.map do |overload|
          next overload.except("return_rbs") unless contract.return_inferred

          slot = inferred_return(single, scope)
          params = overload["params"]&.map do |param|
            param["type"]["type"] == "untyped" ? param.merge("type" => Slot.unavailable("not_computed")) : param
          end
          rbs = overload["rbs"]
          suffix = overload["return_rbs"]
          rbs = rbs.delete_suffix(suffix) + return_spelling(slot) if rbs && suffix && rbs.end_with?(suffix)
          overload.except("return_rbs").merge("rbs" => rbs, "params" => params, "return" => slot)
        end
      end

      # A member with no contract: its parameters as written, each `untyped` with ADR-75's undeclared-parameter
      # cause, and the return from its one body.
      def body_overload(site, name, single, scope)
        return attribute_overload(name, single) if site.data["kind"] == "attribute"

        params, block, head = Parameters.read(site.node.parameters, yields: Parameters.yields?(site.node.body))
        slot = inferred_return(single, scope)
        block_rbs = block ? " ?{ (?) -> untyped }" : ""
        { "rbs" => "#{head}#{block_rbs} -> #{return_spelling(slot)}", "params" => params, "block" => block,
          "return" => slot }
      end

      # An attribute without a contract: Rigor does not report the ivar's type in revision 1.
      def attribute_overload(name, _single)
        unknown = Slot.unavailable("not_computed")
        if name.end_with?("=")
          param = { "name" => nil, "kind" => "required", "type" => Slot.unavailable("not_computed") }
          { "rbs" => nil, "params" => [param], "block" => nil, "return" => unknown }
        else
          { "rbs" => nil, "params" => [], "block" => nil, "return" => unknown }
        end
      end

      # A module function's singleton copy has its own return reading (`singleton_body_return`).
      def inferred_return(single, scope)
        return Slot.unavailable("contested") unless single

        copy = single.data["module_function"] && scope == "singleton"
        body = copy ? single.data["singleton_body_return"] : single.data["body_return"]
        return Slot.unavailable("not_computed") if body.nil?
        return body if Slot.unavailable?(body)

        body.merge("from_site" => single.data["key"])
      end

      def return_spelling(slot)
        spelled = Slot.rbs_spelling(slot)
        spelled.include?(" | ") ? "(#{spelled})" : spelled
      end

      # `rbs` is null when any slot of the overload is unavailable: an `untyped` there would read as an assertion.
      def rbs_unless_unavailable(overload)
        slots = [overload["return"], overload.dig("block", "type")] +
                (overload["params"] || []).map { |param| param["type"] }
        slots.any? { |slot| Slot.unavailable?(slot) } ? nil : overload["rbs"]
      end

      # A site reads `contract: inline` when its own contract comments produced an inline declaration of a member
      # it defines.
      def mark_inline_sites
        @sites.each do |site|
          path = @site_paths.fetch(site.data["key"])
          asserted = site.contract_comments.any? { |comment| !comment.location.slice.match?(/\A#\s*@extrbs\b/) }
          inline = asserted && site.data["members"].any? do |name|
            contract = @contracts[[site.data["owner"], site.data["scope"], name]]
            contract&.provenance == "inline" && contract.buffers.any? { |buffer| buffer.end_with?(":#{path}") }
          end
          site.data["contract"] = inline ? "inline" : nil
        end
      end
    end
  end
end
