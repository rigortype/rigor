# frozen_string_literal: true

require "digest"
require "yaml"

module Rigor
  module MCP
    # The gem-bundled `skills/` tree as the MCP Skills extension serves it (ADR-33 WD10).
    #
    # A catalog reads the served set once and freezes it: every manifest digest and size is computed from the bytes the
    # catalog then serves, so a client that verifies a file against its manifest entry always sees them agree, even if
    # the file changes on disk while the process runs. Only the standard library is loaded here: the server answers the
    # skills methods without loading `rigor/cli` or the engine.
    class SkillCatalog
      # The bundled skills live at `<gem_root>/skills/`; from `lib/rigor/mcp/` that is three directories up.
      # `rigor skill` reads the same constant.
      ROOT = File.expand_path("../../../skills", __dir__).freeze

      # What a skill directory contributes to the served set: exactly the gemspec's two `skills/` globs, so a source
      # checkout serves what the gem ships. `evals/` and `scripts/` stay out.
      SKILL_FILE = "SKILL.md"
      REFERENCE_GLOB = "references/*.md"

      URI_SCHEME = "skill://"
      MIME_TYPE = "text/markdown"

      # One served file: its URI, its text, and the manifest fields computed from those bytes.
      Resource = Data.define(:uri, :path, :text, :digest, :size) do
        def manifest_entry
          { uri: uri, digest: digest, size: size }
        end
      end

      # One served skill. `frontmatter` is the SKILL.md front matter, parsed and otherwise unchanged.
      Skill = Data.define(:name, :uri, :frontmatter, :resources) do
        def entry
          { uri: uri, frontmatter: frontmatter, resources: resources.map(&:manifest_entry) }
        end
      end

      # Reads the served set under `root`. A skill whose SKILL.md is missing, has no front matter, or whose front matter
      # `name` is not its directory name is left out and reported on `err` (ADR-5): one bad skill does not stop the
      # others from being served. `spec/rigor/mcp/skill_catalog_spec.rb` keeps the bundled tree free of such skills.
      def self.load(root: ROOT, err: nil)
        skills = []
        if File.directory?(root)
          Dir.children(root).sort.each do |name|
            dir = File.join(root, name)
            next unless File.file?(File.join(dir, SKILL_FILE))

            skill = read_skill(dir, name, err)
            skills << skill if skill
          end
        end
        new(skills)
      end

      def self.read_skill(dir, name, err)
        paths = [File.join(dir, SKILL_FILE)] + Dir.glob(REFERENCE_GLOB, base: dir).sort.map { File.join(dir, it) }
        resources = paths.map { read_resource(dir, name, it) }
        frontmatter = parse_frontmatter(resources.first.text)
        problem = skill_problem(name, frontmatter)
        if problem
          err&.puts("rigor mcp: not serving skill #{name.inspect}: #{problem}")
          return nil
        end

        Skill.new(name: name, uri: resources.first.uri, frontmatter: frontmatter.freeze, resources: resources.freeze)
      end

      def self.read_resource(dir, name, path)
        bytes = File.binread(path)
        relative = path.delete_prefix("#{dir}/")
        Resource.new(uri: "#{URI_SCHEME}#{name}/#{relative}", path: path,
                     text: bytes.dup.force_encoding(Encoding::UTF_8).freeze,
                     digest: "sha256:#{Digest::SHA256.hexdigest(bytes)}", size: bytes.bytesize)
      end

      # The YAML between a leading `---` line and the next `---` line, or nil when SKILL.md does not open with one.
      def self.parse_frontmatter(text)
        match = text.match(/\A---\r?\n(.*?)^---\r?$/m)
        return nil unless match

        parsed = YAML.safe_load(match[1])
        parsed.is_a?(Hash) ? parsed : nil
      rescue Psych::Exception
        nil
      end

      def self.skill_problem(name, frontmatter)
        return "SKILL.md has no YAML front matter" unless frontmatter
        return "front matter has no string `description`" unless frontmatter["description"].is_a?(String)
        return nil if frontmatter["name"] == name

        "front matter name #{frontmatter['name'].inspect} is not the directory name"
      end

      private_class_method :read_skill, :read_resource, :skill_problem

      attr_reader :skills

      def initialize(skills)
        @skills = skills.freeze
        @skills_by_uri = skills.to_h { [it.uri, it] }.freeze
        @resources_by_uri = skills.flat_map(&:resources).to_h { [it.uri, it] }.freeze
        freeze
      end

      # The `skills/list` and `skills/get` entry of each skill.
      def entries
        skills.map(&:entry)
      end

      # The skill whose SKILL.md URI is `uri`, or nil.
      def skill(uri)
        @skills_by_uri[uri]
      end

      # The served file at `uri`, or nil.
      def resource(uri)
        @resources_by_uri[uri]
      end

      # The `resources/read` contents of the file at `uri`, or nil.
      def contents(uri)
        resource = resource(uri)
        resource && [{ uri: resource.uri, mimeType: MIME_TYPE, text: resource.text }]
      end

      # The `resources/list` entries: every served file. A SKILL.md takes its name and description from its front
      # matter, as the Skills extension recommends; a reference file is named by its path under `skills/`.
      def resource_list
        skills.flat_map do |skill|
          skill.resources.map do |resource|
            listed = { uri: resource.uri, name: resource.uri.delete_prefix(URI_SCHEME), mimeType: MIME_TYPE,
                       size: resource.size }
            next listed unless resource.uri == skill.uri

            listed.merge(name: skill.name, description: skill.frontmatter["description"])
          end
        end
      end
    end
  end
end
