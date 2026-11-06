# frozen_string_literal: true

require "json"

module Rigor
  module Lens
    class Claims
      class IntegrityError < StandardError; end

      # Validates transport and source identity before the incremental session is started.
      class Request
        attr_reader :claims, :digest, :paths

        def self.read(path, root:, arguments:)
          bytes = File.binread(path).force_encoding(Encoding::UTF_8)
          raise IntegrityError, "claims request is not UTF-8" unless bytes.valid_encoding?

          new(JSON.parse(bytes), digest: Lens.digest(bytes), root: root, arguments: arguments)
        rescue SystemCallError, JSON::ParserError => e
          raise IntegrityError, "cannot read claims request: #{e.message}"
        end

        def initialize(data, digest:, root:, arguments:)
          @digest = digest
          @root = root
          @arguments = arguments.map { |argument| File.expand_path(argument, root) }
          validate_header(data)
          @claims = data.fetch("claims")
          @files = data.fetch("files")
          @paths = {}
          @readable_paths = Set.new
          @preflight = true
          @files.each { |file| validate_file(file) }
          ids = []
          @claims.each do |claim|
            validate_claim(claim)
            ids << claim.fetch("id")
          end
          require_value(ids.uniq.size == ids.size, "duplicate claim id")
          verify_sources!
          @preflight = false
        end

        def verify_sources!(targets = [])
          @files.each do |file|
            absolute = @paths.fetch(file.fetch("path"))
            bytes = readable(absolute)
            target = targets.find { |entry| entry.absolute == absolute }
            require_value(bytes || (!@readable_paths.include?(absolute) && !target&.reader),
                          "source became unreadable during analysis: #{file['path']}")
            @readable_paths << absolute if @preflight && bytes
            next unless bytes

            require_value(Lens.digest(bytes) == file.fetch("digest"), "stale claims digest: #{file['path']}")
            if target&.reader
              require_value(target.reader.digest == file.fetch("digest"),
                            "source changed during analysis: #{file['path']}")
            end
            verify_spans(file, bytes.bytesize)
          end
        end

        private

        def verify_spans(file, size)
          @claims.select { |claim| claim.fetch("file") == file.fetch("path") }.each do |claim|
            %w[declaration tag].each do |field|
              require_value(claim.fetch(field).fetch("span").fetch("end_offset") <= size,
                            "#{field} span outside #{file['path']}")
            end
          end
        end

        def validate_header(data)
          require_value(data.is_a?(Hash), "claims request must be an object")
          require_value(data["schema"] == "lens-claims-request/v0", "unsupported claims schema")
          require_value(data["revision"].is_a?(Integer) && data["revision"] == 1, "unsupported claims revision")
          require_value(data["grammar"] == "rbs", "unsupported claims grammar")
          %w[files claims].each { |field| require_value(data[field].is_a?(Array), "#{field} must be an array") }
        end

        def validate_file(file)
          strings(file, %w[path digest])
          path = file.fetch("path")
          absolute = File.expand_path(path, @root)
          relative = Pathname(absolute).relative_path_from(Pathname(@root)).to_s
          require_value(path == relative, "file path must be root-relative: #{path}")
          require_value(@arguments.include?(absolute), "claims file is not a target: #{path}")
          require_value(!@paths.key?(path), "duplicate claims file: #{path}")
          require_value(file.fetch("digest").match?(/\Axxh3-64:[0-9a-f]{16}\z/), "invalid claims file digest")
          @paths[path] = absolute
        end

        def validate_claim(claim)
          strings(claim, %w[id file claim])
          require_value(@paths.key?(claim.fetch("file")), "claim file is missing from files")
          declaration = claim["declaration"]
          strings(declaration, %w[kind owner scope name])
          tag = claim["tag"]
          strings(tag, %w[name])
          require_value(tag.key?("subject") && (tag["subject"].nil? || tag["subject"].is_a?(String)),
                        "tag subject must be a string or null")
          [declaration, tag].each { |entry| validate_span(entry["span"]) }
        end

        def validate_span(span)
          require_value(span.is_a?(Hash), "span must be an object")
          start = span["start_offset"]
          finish = span["end_offset"]
          require_value(start.is_a?(Integer) && finish.is_a?(Integer) && start >= 0 && finish >= start,
                        "invalid byte span")
        end

        def strings(object, fields)
          require_value(object.is_a?(Hash), "claims entry must be an object")
          fields.each { |field| require_value(object[field].is_a?(String), "#{field} must be a string") }
        end

        def require_value(condition, message)
          raise IntegrityError, message unless condition
        end

        def readable(path)
          File.binread(path) if File.file?(path)
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
