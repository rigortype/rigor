# frozen_string_literal: true

require_relative "claims/request"
require_relative "claims/type_reader"
require_relative "claims/comparison"

module Rigor
  module Lens
    # Read-only documentation coverage against the contracts retained by this lens run.
    class Claims
      REASONS = %w[no_such_declaration unsupported_declaration declaration_mismatch unsupported_subject
                   no_authored_contract unsupported_contract_source extrbs_contract refined_contract
                   unsupported_overloads no_such_parameter unsupported_parameter_kind unmatched_parameter
                   unsupported_grammar_feature unresolved_name ambiguous_name dynamic_type unsupported_type
                   unproven].freeze
      POSITIONALS = %w[required optional rest post].freeze

      def initialize(request:, outcome:, run:)
        @request = request
        @outcome = outcome
        @run = run
      end

      def call
        @request.verify_sources!(@outcome.targets)
        { "schema" => "lens-claims/v0", "revision" => 1, "request_digest" => @request.digest,
          "grammar" => "rbs", "capabilities" => %w[return required_param required_keyword],
          "results" => @request.claims.map { |claim| result(claim) } }
      end

      private

      def result(claim)
        answer = { "id" => claim.fetch("id"), "verdict" => "unknown", "reason" => "unproven",
                   "relation" => nil, "direction" => nil, "site" => nil, "member" => nil,
                   "slot" => nil, "contract" => nil, "evidence" => [] }
        target = @outcome.targets.find { |entry| entry.absolute == @request.paths.fetch(claim.fetch("file")) }
        return answer.merge("verdict" => "unavailable", "reason" => target.status) unless target.status == "ok"

        parsed, grammar_reason = TypeReader.parse(claim.fetch("claim"))
        if grammar_reason == "syntax_error"
          return answer.merge("verdict" => "invalid_claim",
                              "reason" => "syntax_error")
        end

        site, member, reason = bind(claim.fetch("declaration"), target.reader)
        return answer.merge("reason" => reason) if reason

        answer.merge!("site" => site.data.fetch("key"), "member" => member.slice("owner", "scope", "name"))
        check_slot(claim, parsed, grammar_reason, site, member, target, answer)
      end

      def bind(declaration, reader)
        sites = reader.sites.select { |site| same_span?(site.data.fetch("span"), declaration.fetch("span")) }
        if sites.empty?
          omission = reader.omissions.any? { |entry| same_span?(entry.fetch("span"), declaration.fetch("span")) }
          return [nil, nil, omission ? "unsupported_declaration" : "no_such_declaration"]
        end
        return [nil, nil, "unsupported_declaration"] unless sites.one? && sites.first.data["kind"] == "method"

        site = sites.first
        member = @outcome.member_rows.find do |row|
          row.values_at("owner", "scope", "name") == declaration.values_at("owner", "scope", "name") &&
            row.fetch("sites").include?(site.data.fetch("key")) && declaration["kind"] == "method"
        end
        member ? [site, member, nil] : [nil, nil, "declaration_mismatch"]
      end

      def same_span?(left, right)
        left.values_at("start_offset", "end_offset") == right.values_at("start_offset", "end_offset")
      end

      def check_slot(claim, parsed, grammar_reason, site, member, target, answer)
        tag = claim.fetch("tag")
        return answer.merge("reason" => "unsupported_subject") unless supported_subject?(tag)

        raw = @run.raw_contracts[member.values_at("owner", "scope", "name")]
        overloads = member.fetch("overloads")
        reasons = member_reasons(site, member) + [grammar_reason].compact
        slot, index, subject_reason = subject(tag, site, overloads.one? ? overloads.first : nil)
        reasons << subject_reason if subject_reason
        if slot
          read_slot(slot, index, tag, overloads.first, raw, answer, reasons)
          type = authored_type(raw, tag, index)
          compare_types(parsed, type, site, target, answer, reasons) if parsed && type
        end
        reason = REASONS.find { |candidate| reasons.include?(candidate) }
        reason ? answer.merge("verdict" => "unknown", "reason" => reason, "evidence" => []) : answer
      end

      def supported_subject?(tag)
        %w[param return].include?(tag.fetch("name")) && (tag["name"] == "return" || tag["subject"])
      end

      def authored_type(raw, tag, index)
        contract_type(raw.types.first.type, tag, index) if raw&.types&.one?
      end

      def member_reasons(site, member)
        reasons = []
        overloads = member.fetch("overloads")
        reasons << "no_authored_contract" if member["basis"] != "contract"
        reasons << "unsupported_overloads" unless overloads.one? && overloads.first["params"]
        reasons << "extrbs_contract" if site.contract_comments.any? do |comment|
          comment.location.slice.match?(/\A#\s*@extrbs\b/)
        end
        reasons
      end

      def read_slot(slot, index, tag, overload, raw, answer, reasons)
        answer.merge!("relation" => "documentation_coverage", "slot" => slot,
                      "direction" => tag["name"] == "param" ? "claim_within_contract" : "contract_within_claim")
        contract = tag["name"] == "return" ? overload["return"] : overload.fetch("params")[index]["type"]
        inspect_contract(contract, raw, tag, index, answer, reasons)
      end

      def inspect_contract(contract, raw, tag, index, answer, reasons)
        if contract.nil? || contract["state"] == "unavailable" || contract["provenance"] == "inferred"
          reasons << "no_authored_contract"
          return
        end
        provenance = contract["provenance"]
        reasons << "unsupported_contract_source" if provenance == "library" || provenance&.start_with?("plugin:")
        answer["contract"] = contract.slice("type", "provenance", "path")
        reasons << "refined_contract" if refined?(raw, tag, index)
      end

      def refined?(raw, tag, index)
        return false if raw.nil?
        return raw.annotations.any? { |text| text.start_with?("rigor:v1:return:") } if tag["name"] == "return"

        raw.types.any? do |method_type|
          function = method_type.type
          param = function_params(function)[index]
          if function.respond_to?(:required_keywords)
            keyword = function.required_keywords.find do |_key, value|
              value.equal?(param)
            end
          end
          name = keyword ? keyword.first : param&.name
          name && raw.annotations.any? { |text| text.match?(/\Arigor:v1:param:\s*#{Regexp.escape(name.to_s)}\s/) }
        end
      end

      def subject(tag, site, overload)
        return [{ "kind" => "return" }, nil, nil] if tag["name"] == "return" && overload
        return [nil, nil, nil] if tag["name"] == "return"

        params = site.data["params"] || []
        param = params.find { |entry| entry["name"] == tag["subject"] }
        return [nil, nil, "no_such_parameter"] unless param
        return [nil, nil, "unsupported_parameter_kind"] unless %w[required keyreq].include?(param["kind"])
        return [nil, nil, nil] unless overload && overload["params"]

        declared = overload.fetch("params")
        index = parameter_index(param, params, declared)
        return [nil, nil, "unmatched_parameter"] unless index

        [{ "kind" => "param", "name" => param["name"], "param_kind" => param["kind"], "index" => index }, index, nil]
      end

      def parameter_index(param, params, declared)
        if param["kind"] == "keyreq"
          return declared.index { |entry| entry["kind"] == "keyreq" && entry["name"] == param["name"] }
        end

        source_positions = params.select { |entry| POSITIONALS.include?(entry["kind"]) }
        contract_positions = declared.select { |entry| POSITIONALS.include?(entry["kind"]) }
        return unless source_positions.map { |entry| entry["kind"] } == contract_positions.map { |entry| entry["kind"] }

        source_positions.index(param)
      end

      def contract_type(function, tag, index)
        tag["name"] == "return" ? function.return_type : function_params(function)[index]&.type
      end

      def function_params(function)
        return [] unless function.respond_to?(:required_positionals)

        function.required_positionals + function.optional_positionals + [function.rest_positionals].compact +
          function.trailing_positionals + function.required_keywords.values + function.optional_keywords.values +
          [function.rest_keywords].compact
      end

      def compare_types(parsed, contract, site, target, answer, reasons)
        scope = @run.claim_contexts.fetch(target.absolute)
        nesting = site.data.fetch("lexical_nesting")
        reader = TypeReader.new(scope: scope, nesting: nesting, singleton_nesting: site.data["singleton_nesting"])
        claim_arms = reader.read(parsed, claim: true)
        contract_arms = reader.read(contract)
        reasons.concat(reader.reasons.to_a)
        return unless reasons.empty?

        left, right = if answer["direction"] == "claim_within_contract"
                        [claim_arms, contract_arms]
                      else
                        [contract_arms, claim_arms]
                      end
        comparator = Comparison.new(scope.environment.rbs_loader,
                                    relative_conflict: nesting == [] && site.data["owner"] == "Object")
        verdict, reason, evidence = comparator.call(left, right)
        answer.merge!("verdict" => verdict, "reason" => reason, "evidence" => evidence)
      end
    end
  end
end
