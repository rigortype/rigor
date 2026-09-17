# frozen_string_literal: true

# #392 — the template-unit seam's worked consumer, with the **identity** transform the slice ships.
#
# A `*.rbx` file is already Ruby, so the "compiler" copies the bytes and the line map is the identity: the
# unit exercises every part of the seam (the claim, the hook, the declared `self`, the ivar seeds, the
# locals, the `view:` key, the line map) without the slice also having to be right about ERB. The real
# compiler — Erubi when it resolves, stdlib `ERB` as the fallback — is #393, and it changes only
# `#template_units_for_file`.
#
# It lives here rather than under `examples/` deliberately: `examples/` is a tutorial catalogue for shipped
# contract surfaces, and what a plugin author will want to read is the ERB walkthrough, not a transform
# that does nothing.
class RigorViewDemoPlugin < Rigor::Plugin::Base
  manifest(
    id: "view-demo",
    version: "0.1.0",
    description: "Template-unit seam fixture: analyses *.rbx files as views (#392)",
    template_globs: ["app/views/**/*.rbx"]
  )

  # `app/views/users/show.rbx` → `users/show.html`. Rails' own logical name, with the handler dropped so an
  # ERB → Haml rewrite is not a rename (design note § 11.3).
  def logical_name_for(path)
    "#{path.sub(%r{\Aapp/views/}, '').sub(/\.rbx\z/, '')}.html"
  end

  # Spec knobs, so one fixture plugin can stand in for the handful of malformed-declaration cases the
  # seam has to behave under (an unresolvable `self_type:`, a unit naming the wrong path, a raising
  # transform) without a second plugin class per case. Production plugins carry nothing like this.
  class << self
    attr_accessor :spec_overrides
  end
  self.spec_overrides = {}

  def template_units_for_file(path:, source:)
    overrides = self.class.spec_overrides || {}
    raise "the demo transform was told to fail" if overrides[:raise_on_transform]

    text = source.dup.force_encoding(Encoding::UTF_8)
    name = logical_name_for(path)
    [
      Rigor::Plugin::TemplateUnit.new(
        logical_name: name,
        path: overrides[:unit_path] || path,
        # The transform is the identity on the body, plus a one-line banner — so the compiled Ruby's lines
        # are the template's lines OFF BY ONE, and a run that lost the line map would report every finding
        # one line late. A real compiler's map is far less regular; this is the smallest map that is not
        # the identity.
        ruby_source: "# rigor template unit: #{name}\n#{text}",
        line_map: (1..text.lines.length).to_h { |line| [line + 1, line] },
        self_type: overrides[:self_type] || "ViewContext",
        locals: { "size" => "String" },
        ivar_seeds: { "@user" => "User", "@title" => "String" },
        transform_id: "identity-1"
      )
    ]
  end
end

# The same transform behind an UNANCHORED claim. A glob with no directory prefix matches a `.rbx` anywhere,
# which is the shape that can reach outside the project root once an editor buffer joins the expansion by
# its absolute path — so the "a claim is over the project" guard needs a plugin that actually claims that
# widely to be testable at all.
class RigorViewDemoGlobalPlugin < RigorViewDemoPlugin
  manifest(
    id: "view-demo-global",
    version: "0.1.0",
    description: "Template-unit seam fixture with an unanchored claim (#392)",
    template_globs: ["**/*.rbx"]
  )
end
