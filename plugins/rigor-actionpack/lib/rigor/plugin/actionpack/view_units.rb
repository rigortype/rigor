# frozen_string_literal: true

module Rigor
  module Plugin
    class Actionpack < Rigor::Plugin::Base
      # #393 — the naming and binding rules that turn one ERB file into a {Plugin::TemplateUnit}.
      # The compiler is {ErbCompiler}; the controller-side seeds are {ViewAssigns}.
      module ViewUnits
        # The `self` every view body is typed as. A bare, RBS-declared, OPEN nominal: `sig/action_view.rbs`
        # names the class so the constant resolves and `open_receivers:` keeps its method surface lenient,
        # which is what makes `link_to`, `form_with`, `t`, `turbo_frame_tag` and every other helper —
        # including the project's own `ApplicationHelper` methods, which are implicit-self calls on this
        # receiver — resolve lenient-to-`Dynamic` rather than drawing a finding per line.
        #
        # Enumerating the helper surface in RBS was considered and refused, for the reason
        # `sig/action_controller.rbs` gives about `ActionController::Parameters`: a declared class drops
        # every member its signature omits, and no signature completes a surface that `helper_method`,
        # every `*Helper` module in the project and a dozen gems all extend. The per-controller view class
        # the design note describes (§ 11.3 — `ActionView::Base` + `ApplicationHelper` + `<C>Helper` +
        # route helpers) is the same shape one level finer, and needs a way for a plugin to synthesise a
        # class; it is the follow-up named in `docs/internal-spec/macro-substrate.md`.
        SELF_TYPE = "ActionView::Base"

        # The type a strict-locals name is seeded with. Deliberately NOT declared in `sig/action_view.rbs`
        # and deliberately not a real class: the engine binds an unresolvable name to `Dynamic[top]`
        # (`Analysis::TemplateUnits#resolve`), which is the honest reading — the comment states the
        # parameter's NAME, and Rails' strict-locals syntax carries no type. What the seed buys is the
        # name: without it Prism reads a bare `user` as a method call and the binding is never consulted.
        UNKNOWN_LOCAL = "ActionView::UnknownLocal"

        # Rails 7.1's strict-locals magic comment: `<%# locals: (user:, size: :md) %>`. Only the first one
        # counts, as in Rails, and only the names are read — a default value is a default, not a type.
        STRICT_LOCALS = /<%#-?\s*locals:\s*\(([^)]*)\)\s*-?%>/
        private_constant :STRICT_LOCALS

        LOCAL_NAME = /([a-z_][A-Za-z0-9_]*):/
        private_constant :LOCAL_NAME

        module_function

        # `app/views/users/show.html.erb` → `users/show.html`; `app/views/users/_card.html.erb` →
        # `users/_card.html`. The handler is dropped and the format is kept, which is Rails' own logical
        # name and what the seam asks for so an ERB → Haml rewrite is not a rename. A template with no
        # format segment (`users/show.erb`) keeps the name it has.
        def logical_name(path, roots)
          relative = strip_root(path, roots)
          relative.sub(/\.erb\z/, "")
        end

        def strip_root(path, roots)
          roots.each do |root|
            prefix = "#{root.to_s.sub(%r{\A\./}, '').chomp('/')}/"
            return path.delete_prefix(prefix) if path.start_with?(prefix)
          end
          path
        end

        # `{ "user" => UNKNOWN_LOCAL }` for a template carrying the strict-locals comment, `{}` otherwise.
        def strict_locals(source)
          match = STRICT_LOCALS.match(source)
          return {} if match.nil?

          match[1].scan(LOCAL_NAME).flatten.to_h { |name| [name, UNKNOWN_LOCAL] }
        end
      end
    end
  end
end
