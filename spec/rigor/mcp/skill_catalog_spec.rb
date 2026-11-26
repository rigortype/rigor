# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require "rigor/mcp/skill_catalog"

RSpec.describe Rigor::MCP::SkillCatalog do
  def write(root, relative, text)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def skill_md(name, description: "Does #{name}.")
    "---\nname: #{name}\ndescription: >-\n  #{description}\nlicense: MPL-2.0\nmetadata:\n  version: 0.1.0\n---\n\n" \
      "# #{name}\n"
  end

  let(:root) { Dir.mktmpdir("skill-catalog") }
  let(:err) { StringIO.new }
  let(:catalog) { described_class.load(root: root, err: err) }

  after { FileUtils.rm_rf(root) }

  describe ".load" do
    before do
      write(root, "alpha/SKILL.md", skill_md("alpha"))
      write(root, "alpha/references/02-second.md", "second\n")
      write(root, "alpha/references/01-first.md", "first ✓\n")
      write(root, "alpha/evals/evals.json", "{}\n")
      write(root, "alpha/scripts/run.sh", "true\n")
      write(root, "alpha/references/nested/deep.md", "not a reference\n")
    end

    it "serves SKILL.md and references/*.md only, SKILL.md first" do
      uris = catalog.skill("skill://alpha/SKILL.md").resources.map(&:uri)
      expect(uris).to eq(%w[skill://alpha/SKILL.md skill://alpha/references/01-first.md
                            skill://alpha/references/02-second.md])
    end

    it "computes each digest and size from the bytes it serves" do
      resource = catalog.resource("skill://alpha/references/01-first.md")
      bytes = "first ✓\n".b
      expect(resource.text).to eq("first ✓\n")
      expect(resource.size).to eq(bytes.bytesize)
      expect(resource.digest).to eq("sha256:#{Digest::SHA256.hexdigest(bytes)}")
    end

    it "passes the front matter through as parsed" do
      expect(catalog.skill("skill://alpha/SKILL.md").frontmatter).to eq(
        "name" => "alpha", "description" => "Does alpha.", "license" => "MPL-2.0",
        "metadata" => { "version" => "0.1.0" }
      )
    end

    it "keeps serving the snapshot after the file changes on disk" do
      before_edit = catalog.contents("skill://alpha/SKILL.md")
      write(root, "alpha/SKILL.md", skill_md("alpha", description: "Edited."))
      expect(catalog.contents("skill://alpha/SKILL.md")).to eq(before_edit)
    end

    it "leaves out a skill whose name is not its directory, and says so" do
      write(root, "beta/SKILL.md", skill_md("gamma"))
      expect(catalog.skills.map(&:name)).to eq(["alpha"])
      expect(err.string).to include('not serving skill "beta"')
    end

    it "leaves out a skill without front matter" do
      write(root, "delta/SKILL.md", "# delta\n")
      expect(catalog.skills.map(&:name)).to eq(["alpha"])
      expect(err.string).to include("no YAML front matter")
    end

    it "serves nothing when the root is missing" do
      expect(described_class.load(root: File.join(root, "absent")).skills).to be_empty
    end
  end

  describe "lookups" do
    before { write(root, "alpha/SKILL.md", skill_md("alpha")) }

    it "answers nil for a URI it does not serve" do
      expect(catalog.skill("skill://alpha/references/x.md")).to be_nil
      expect(catalog.resource("skill://omega/SKILL.md")).to be_nil
      expect(catalog.contents("skill://omega/SKILL.md")).to be_nil
    end

    it "lists a SKILL.md under its front matter name and description" do
      expect(catalog.resource_list).to eq(
        [{ uri: "skill://alpha/SKILL.md", name: "alpha", description: "Does alpha.",
           mimeType: "text/markdown", size: skill_md("alpha").bytesize }]
      )
    end

    it "builds the skills/list entry from the manifest" do
      entry = catalog.entries.first
      expect(entry.keys).to eq(%i[uri frontmatter resources])
      expect(entry[:resources]).to eq([catalog.resource("skill://alpha/SKILL.md").manifest_entry])
    end
  end

  # The real tree this gem ships. These are the gates of ADR-33 WD10.
  describe "the bundled skills/ tree" do
    let(:catalog) { described_class.load(err: err) }
    let(:skill_dirs) do
      Dir.children(described_class::ROOT).select do |name|
        File.file?(File.join(described_class::ROOT, name, "SKILL.md"))
      end
    end

    # Claude Code's limits on the skills one MCP server serves (https://code.claude.com/docs/en/mcp § "Use skills from
    # MCP servers", read 2026-11-27): "Each server shows up to 100 skills" and "100 KB per text file, 400 KB per skill".
    # They are tighter than the Skills extension's own 512 files / 16 MiB per skill, and a skill over them does not
    # load. Read as decimal kilobytes, the stricter reading. When Claude Code changes them, change these lines.
    let(:claude_code_max_skills) { 100 }
    let(:claude_code_max_file_bytes) { 100_000 }
    let(:claude_code_max_skill_bytes) { 400_000 }

    it "serves every skill directory, with its name equal to its front matter name" do
      expect(catalog.skills.map(&:name)).to match_array(skill_dirs)
      expect(err.string).to be_empty
    end

    it "lists, in each manifest, the digest and size of the bytes resources/read serves" do
      catalog.skills.each do |skill|
        skill.resources.each do |entry|
          text = catalog.contents(entry.uri).first.fetch(:text)
          expect(entry.manifest_entry).to eq(
            uri: entry.uri, digest: "sha256:#{Digest::SHA256.hexdigest(text.b)}", size: text.bytesize
          )
          expect(text.b).to eq(File.binread(entry.path))
        end
      end
    end

    it "passes each SKILL.md's front matter through unchanged" do
      catalog.skills.each do |skill|
        served = catalog.contents(skill.uri).first.fetch(:text)
        expect(skill.entry[:frontmatter]).to eq(described_class.parse_frontmatter(served))
      end
    end

    it "serves exactly the skills/ files the gemspec ships" do
      gemspec = Gem::Specification.load(File.expand_path("../../../rigortype.gemspec", __dir__))
      shipped = gemspec.files.grep(%r{\Askills/}).map { File.expand_path(it, File.dirname(described_class::ROOT)) }
      expect(catalog.skills.flat_map(&:resources).map(&:path)).to match_array(shipped)
    end

    it "stays within Claude Code's limits on skills, file size and skill size" do
      expect(catalog.skills.size).to be <= claude_code_max_skills
      catalog.skills.each do |skill|
        skill.resources.each do |resource|
          expect(resource.size).to be <= claude_code_max_file_bytes, "#{resource.uri} is #{resource.size} bytes"
        end
        total = skill.resources.sum(&:size)
        expect(total).to be <= claude_code_max_skill_bytes, "#{skill.uri} totals #{total} bytes"
      end
    end

    # A client reads only the files a skill's manifest lists, and resolves a relative link against the skill's root
    # (the Skills extension § URIs). A link out of the skill, into the repository or into another skill, resolves to
    # nothing the client may read; in an installed gem it already pointed at nothing.
    it "links, relatively, only to files the same skill serves" do
      catalog.skills.each do |skill|
        served = skill.resources.map(&:path)
        skill.resources.each do |resource|
          prose = resource.text.gsub(/^(```|~~~).*?^\1/m, "")
          prose.scan(/\]\(([^)\s]+)/).flatten.each do |target|
            next if target.match?(/\A(?:[a-z][a-z0-9+.-]*:|#)/i)

            resolved = File.expand_path(target.sub(/#.*\z/, ""), File.dirname(resource.path))
            expect(served).to include(resolved), "#{resource.uri} links #{target}, which #{skill.name} does not serve"
          end
        end
      end
    end

    # The server answers the skills methods before the engine loads, so a slow boot never pushes a client past its
    # `server/discover` probe (ADR-33 WD10 d). Bundler's setup may load `rigor/version` through the gemspec; nothing
    # else of Rigor's may load.
    it "loads with neither rigor/cli nor the engine" do
      lib = File.expand_path("../../../lib", __dir__)
      script = 'require "rigor/mcp/skill_catalog"; Rigor::MCP::SkillCatalog.load; ' \
               "puts $LOADED_FEATURES.grep(%r{/lib/rigor/}).map { it[%r{/lib/(rigor/.*)}, 1] }"
      out, status = Open3.capture2(RbConfig.ruby, "-I", lib, "-e", script, stdin_data: "")
      expect(status).to be_success
      expect(out.split - ["rigor/version.rb"]).to eq(["rigor/mcp/skill_catalog.rb"])
    end
  end
end
