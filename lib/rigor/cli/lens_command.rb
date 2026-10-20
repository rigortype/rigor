# frozen_string_literal: true

require "json"
require "optparse"

require_relative "command"
require_relative "options"
require_relative "check_runner_factory"
require_relative "../configuration"
require_relative "../lens"

module Rigor
  class CLI
    # `rigor lens FILE...` — a declaration map of the files with type provenance, computed as `rigor check`
    # computes them (ADR-113; output contract docs/internal-spec/lens.md). Experimental until `lens/v1`.
    class LensCommand < Command
      USAGE = "Usage: rigor lens [--format=text|json] [--config=PATH] [--workers=N] FILE..."
      FORMATS = %w[text json].freeze

      def run
        options = parse_options
        return CLI::EXIT_USAGE if options.nil?

        config = options.fetch(:config)
        configuration = Configuration.load(config)
        config_path = options.fetch(:config) || Configuration.discover
        # The working directory: Rigor auto-detects sig/ and the lockfiles there (lens.md § Serialization).
        root = Dir.pwd
        workers = CheckRunnerFactory.resolve_workers(options, configuration)
        outcome = Lens::Run.new(configuration: configuration, root: root, arguments: @argv, workers: workers).call
        document = Lens::Document.new(outcome: outcome, configuration: configuration, root: root,
                                      config_path: config_path).to_h
        @err.puts("rigor lens: #{outcome.warm ? 'warm' : 'cold'} — #{@argv.size} target(s)")
        render(document, options.fetch(:format))
        outcome.targets.any? { |target| target.status == "ok" } ? 0 : 1
      end

      private

      def parse_options
        options = { format: "text", config: nil, workers: nil }
        OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on("--format=FORMAT", "Output format: text (default) or json") { |value| options[:format] = value }
          opts.on("--workers=N", Integer, "Worker processes for a cold run") { |value| options[:workers] = value }
          Options.add_config(opts, options)
        end.parse!(@argv)
        return usage_error("--format must be text or json") unless FORMATS.include?(options[:format])
        return usage_error("no FILE given") if @argv.empty?

        options
      rescue OptionParser::ParseError => e
        usage_error(e.message)
      rescue Rigor::ConfigurationError => e
        # The shared --config check (CLI::Options.config_path). Mapped here the way Rigor::CLI#run maps it, so a
        # direct LensCommand run exits with the usage code too.
        @err.puts("rigor: #{e.message}")
        nil
      end

      def usage_error(message)
        @err.puts("rigor lens: #{message}")
        @err.puts(USAGE)
        nil
      end

      def render(document, format)
        if format == "json"
          @out.puts(JSON.generate(document))
        else
          TextRenderer.new(document, @out).render
        end
      end

      # The text rendering for agents and people. Its layout is not a contract; the `LINE:HASH` anchor token is.
      class TextRenderer
        def initialize(document, out)
          @document = document
          @out = out
          @members = document["members"].each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |member, index|
            member["sites"].each { |key| index[key] << member }
          end
        end

        def render
          @document["files"].each { |file| render_file(file) }
        end

        private

        def render_file(file)
          unless file["status"] == "ok"
            @out.puts("#{file['argument']}  #{file['status']}: #{file['reason']}")
            return
          end

          omitted = file["omissions"].empty? ? "" : "  (#{file['omissions'].size} omitted)"
          @out.puts("#{file['path']}  #{file['digest']}#{omitted}")
          file["sites"].each { |site| render_site(site) }
          file["omissions"].each do |omission|
            @out.puts("  omitted #{omission['kind']} #{omission['name']} (line #{omission.dig('span', 'start_line')})")
          end
          file["diagnostics"].each do |diagnostic|
            @out.puts("  #{diagnostic['line']}:#{diagnostic['column']} #{diagnostic['severity']} " \
                      "#{diagnostic['message']} [#{diagnostic['rule']}]")
          end
        end

        def render_site(site)
          case site["kind"]
          when "class", "module" then @out.puts("  #{site['anchor']}  #{site['kind']} #{site['name']}")
          else
            @members[site["key"]].each { |member| render_member(site, member) }
          end
        end

        def render_member(site, member)
          separator = member["scope"] == "singleton" ? "." : "#"
          if member["overloads"].empty?
            elsewhere = member["also_defined_at"].map { |entry| "#{entry['path']}:#{entry['line']}" }
            @out.puts("  #{site['anchor']}  #{site['owner']}#{separator}#{member['name']}  " \
                      "[#{member['basis']}#{"; also #{elsewhere.join(', ')}" unless elsewhere.empty?}]")
          end
          member["overloads"].each do |overload|
            signature = overload["rbs"] || "(signature unavailable: #{unavailable_reasons(overload).join(', ')})"
            @out.puts("  #{site['anchor']}  #{site['owner']}#{separator}#{member['name']}: #{signature}  " \
                      "[#{member['basis']}#{provenance_note(overload)}]")
          end
        end

        def provenance_note(overload)
          provenances = ([overload["return"]] + (overload["params"] || []).map { |param| param["type"] })
                        .filter_map { |slot| slot["provenance"] }.uniq
          provenances.empty? ? "" : " #{provenances.join('+')}"
        end

        def unavailable_reasons(overload)
          ([overload["return"]] + (overload["params"] || []).map { |param| param["type"] })
            .filter_map { |slot| slot["reason"] }.uniq
        end
      end
    end
  end
end
