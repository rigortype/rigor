# frozen_string_literal: true

require "prism"

module Rigor
  module Effects
    # Callee resolution for plugin attribution rows (#1048; ADR-103 WD10 / WD13; design note § 11.2).
    #
    # A framework method can be an **edge** as well as a label. `render :show` inside `UsersController`
    # runs `app/views/users/show.html.erb`, synchronously and in-process, and since #393 that template is
    # an effect unit keyed `view:users/show.html` sitting in the very same summaries table. Nothing
    # produced the edge, because the only plugin-facing edge surface ({Plugin::EffectEdge}) names a
    # receiver *class* and mints units on a class body, and {Plugin::EffectAttribution} carried labels but
    # no callee.
    #
    # This module is the missing half, and it is deliberately shaped exactly like {Narrowing}: the plugin
    # writes a **rule name** on its row (`callee: "rails_render"`) and the engine owns the strategy. A
    # block would have to run inside the per-file effect scan — the one place ADR-103 WD13 forbids
    # anything that resolves, walks or types — and would not survive the fork-pool / Ractor boundary. A
    # name is a String: declarative, Marshal-clean, and reviewable in the plugin's manifest.
    #
    # ## What a rule may read
    #
    # **The call's own argument literals, the unit's owner class, and the unit's own key.** No dataflow,
    # no typer question, no filesystem. A rule that needed to know whether `app/views/users/show.html.erb`
    # exists would make a plugin row's meaning a function of the view tree, which the scan does not have
    # and must not read; instead an unresolvable answer is `nil` and a resolvable-looking one that no unit
    # answers is **dropped by the propagator**, which restores the row's taint from
    # {FileCollection::Edge#taint_if_unresolved}. So "the template is not in the table" and "the argument
    # was computed" both keep the `template-not-analysed` taint, and only a render that reached a real
    # unit clears it.
    #
    # ## Two kinds of rule
    #
    # - a **site rule** ({SITE_RULES}) answers for one call node — `render :show`, `render partial: "card"`;
    # - a **unit rule** ({UNIT_RULES}) answers for a whole unit and reads no node at all. Rails' *implicit*
    #   render is the case that needs one: an action that falls off its end without rendering still renders
    #   `<controller>/<action>`, and the fact that produces the edge is the **absence** of a call. Only the
    #   unit scan can observe that, which is why the rule is applied there rather than in
    #   {FrameworkUnits} — a class body cannot see which of its methods responded.
    #
    #   A unit rule contributes an **edge and nothing else**: no labels, no taint. That is what keeps it
    #   FP-safe on the private helper a controller also defines — `def load_user` gets an edge to
    #   `view:users/load_user.html`, no unit answers it, and the unit is exactly as it was.
    module CalleeRule
      # The callee an applied rule names, as the two halves {FileCollection::Edge} carries. The key the
      # propagator reconstructs is `"#{receiver}.#{selector}"` — `view:users/show` + `html`.
      #
      # `fallbacks` is the ordered list of selectors the propagator retries when `selector` resolves to
      # nothing (#1065), or nil for none. The rule only COPIES it off the plugin's table: whether
      # `view:users/_row.js` exists is a question about the merged table, which the scan cannot ask.
      Callee = Data.define(:receiver, :selector, :fallbacks) do
        def initialize(fallbacks: nil, **) = super
      end

      # Must agree with {MethodKey::TEMPLATE_UNIT_PREFIX} and `Plugin::TemplateUnit::KEY_PREFIX`; pinned
      # equal by spec.
      TEMPLATE_PREFIX = "view:"

      # The format a controller action renders absent a `formats:` override — Rails' own default, and the
      # only one a `render :show` with no other evidence may be read as.
      DEFAULT_FORMAT = "html"

      # Rules that answer for one call node.
      SITE_RULES = %w[rails_render rails_render_partial].freeze

      # Rules that answer for a whole unit, from its owner and its own key. A UNIT rule may additionally
      # be applied **per format arm** of a `respond_to` block (#1071): the arm is the unit's own body, and
      # the arm's format is a literal the unit scan read, so it travels as data the same way the unit's key
      # does.
      UNIT_RULES = %w[rails_implicit_render].freeze

      RULES = (SITE_RULES + UNIT_RULES).freeze

      # `render json:` / `plain:` / `inline:` and friends render no template. They are listed so the rule
      # can decline rather than read a `partial:` that is not there — declining keeps the row's taint,
      # which is the conservative answer for a shape this rule does not model.
      NON_TEMPLATE_OPTIONS = %w[json xml plain text html body js inline file nothing].freeze

      # Template handlers, which a logical name never carries: `Plugin::TemplateUnit#logical_name` is
      # `users/show.html`, not `users/show.html.erb`. An author may still write the handler out —
      # `render template: "users/show.html.erb"` is legal Rails — so it is stripped rather than left to
      # build a key no unit could ever answer.
      HANDLERS = %w[erb haml slim jbuilder builder rabl ruby].freeze

      module_function

      def known?(name)
        RULES.include?(name.to_s)
      end

      def site_rule?(name)
        SITE_RULES.include?(name.to_s)
      end

      def unit_rule?(name)
        UNIT_RULES.include?(name.to_s)
      end

      # Applies a site rule to one call node.
      #
      # @param name — the row's `callee:`
      # @param node — the `Prism::CallNode` the row matched
      # @param owner_class — the unit's owner (`"UsersController"`, `"ActionView::Base"`)
      # @param unit_key — the unit's own key: a selector for a method, `view:users/show.html` for a
      #   template unit
      # @param fallbacks — the row's `callee_fallbacks:` table (#1065). Only a rule whose selector the
      #   CONTEXT supplied consults it; see {rails_render_partial}.
      # @return the {Callee} the rule named, or nil whenever it cannot settle the target from
      #   literals alone
      def site(name, node, owner_class:, unit_key: nil, fallbacks: nil)
        case name.to_s
        when "rails_render" then rails_render(node, owner_class)
        when "rails_render_partial" then rails_render_partial(node, unit_key, fallbacks)
        end
      end

      # Applies a unit rule. Reads no node; a `format:` from a `respond_to` arm (#1071) narrows the
      # template the rule names from the default to that arm's own. Nil, or absent (`DEFAULT_FORMAT`).
      #
      # @return the {Callee} the rule named, or nil.
      def unit(name, owner_class:, unit_key: nil, format: nil)
        case name.to_s
        when "rails_implicit_render" then rails_implicit_render(owner_class, unit_key, format: format)
        end
      end

      # `render` inside a controller. The positional form names an **action template**
      # (`render :show` → `users/show`), which is the one place a controller and a view disagree about
      # what a bare string means.
      #
      # Never consults a format fallback (#1065). The format here is either one the author wrote, or
      # Rails' `html` default standing in for a REQUEST format the rule cannot see — and the lookup order
      # a controller-side render follows is derived from that request (`request.formats`, an `Accept`
      # header), not from anything in the source.
      def rails_render(node, owner_class)
        directory = controller_directory(owner_class)
        return nil if directory.nil?

        format = format_for(node, DEFAULT_FORMAT)
        return nil if format.nil?

        name = template_name(node, directory) || partial_name(node, directory, layout: false)
        name.nil? ? nil : template_callee(name, format)
      end

      # `render` inside a template. A bare positional argument is a **partial** here, and so is `layout:`
      # — in a view `render layout: "shared/wrapper"` names `shared/_wrapper`, not an `app/views/layouts`
      # file, because `RenderingHelper#render` rewrites `layout:` to `partial:` when a block is given.
      # Since #1047 a layout compiles to a unit like any other template, so such an edge resolves where
      # the named partial exists and keeps its taint where it does not.
      #
      # **The format fallback (#1065).** The format travels from the enclosing unit, and while a `.js.erb`
      # template is rendering Rails' lookup context holds `[:js, :html]` — `LookupContext#formats=` appends
      # `:html` to a lone `:js`, and `AbstractRenderer#prepend_formats` puts the template's own format in
      # front of the request's. So `render partial: "watchers"` from `_set_watcher.js.erb` runs
      # `_watchers.js.erb` where one exists and `_watchers.html.erb` otherwise. The rule copies the row's
      # table for the inherited format onto the callee, and the propagator takes the first key that
      # resolves.
      #
      # The table is consulted only for an INHERITED format. A `formats:` / `format:` keyword or a format
      # spelled into the name is the author's word, and the fallback stands down: that is the direction
      # that keeps a taint rather than guessing at a lookup the call overrode.
      def rails_render_partial(node, unit_key, fallbacks)
        directory, inherited = template_context(unit_key)
        return nil if directory.nil?

        format = format_for(node, inherited)
        return nil if format.nil?

        retry_formats = format_keyword?(node) ? nil : fallbacks&.fetch(format, nil)
        explicit = keyword_name(node, "template")
        return template_callee(qualify(explicit, directory), format, retry_formats) if explicit

        name = partial_name(node, directory) || positional_partial(node, directory)
        name.nil? ? nil : template_callee(name, format, retry_formats)
      end

      # Rails' implicit render: an action that never rendered still renders `<controller>/<action>`. A
      # `respond_to` arm (#1071) is the same convention per format: `format.js` with no responding block
      # renders `<controller>/<action>.js`, so the rule narrows the format it answers for, and an arm that
      # IS answered outright is not applied at all (the unit scan decides that half and calls with the
      # arm's format only for arms that still fall through).
      def rails_implicit_render(owner_class, unit_key, format: nil)
        directory = controller_directory(owner_class)
        return nil if directory.nil? || unit_key.nil?

        action = unit_key.to_s
        return nil unless /\A[a-z_][A-Za-z0-9_]*[?!=]?\z/.match?(action)
        return nil if action.end_with?("?", "!", "=")

        template_callee("#{directory}/#{action}", format || DEFAULT_FORMAT)
      end

      # `UsersController` → `users`; `Admin::UsersController` → `admin/users`. A class whose name does not
      # end in `Controller` is not one this rule can read a view directory off, and answers nil.
      def controller_directory(owner_class)
        return nil if owner_class.nil?

        segments = owner_class.to_s.split("::")
        last = segments.pop
        return nil unless last&.end_with?("Controller") && last != "Controller"

        segments.push(last.delete_suffix("Controller"))
        segments.map { |segment| underscore(segment) }.join("/")
      end

      # `[directory, format]` for a template unit's own key — `view:users/show.html` → `["users", "html"]`.
      # A partial rendered from a `.json` template is a `.json` partial, which is why the format travels.
      def template_context(unit_key)
        key = unit_key.to_s
        return [nil, nil] unless key.start_with?(TEMPLATE_PREFIX)

        logical = key.delete_prefix(TEMPLATE_PREFIX)
        name, _, format = logical.rpartition(".")
        return [nil, nil] if name.empty?

        directory = name.include?("/") ? name[0...name.rindex("/")] : ""
        [directory, format]
      end

      # The explicit template spellings: `template: "users/show"` and `action: :edit`.
      def template_name(node, directory)
        explicit = keyword_name(node, "template")
        return qualify(explicit, directory) if explicit

        action = keyword_name(node, "action")
        return "#{directory}/#{action}" if action && !action.include?("/")
        return action if action

        positional_template(node, directory)
      end

      # `render :show` / `render "show"` / `render "admin/form"`, but only when no option keyword the rule
      # does not model is present.
      def positional_template(node, directory)
        name = literal_name(positional(node).first)
        return nil if name.nil?

        qualify(name, directory)
      end

      # `render "card"` inside a template — the same literal, read as a partial.
      def positional_partial(node, directory)
        name = literal_name(positional(node).first)
        name.nil? ? nil : partialize(qualify(name, directory))
      end

      # `partial: "card"` / `partial: "users/card"`, and the view-side `layout:`. `collection:` changes
      # how many times the partial runs and not which one, so it is read and ignored on purpose: an
      # effect summary is an upper bound over the body, not a count.
      def partial_name(node, directory, layout: true)
        name = keyword_name(node, "partial") || (layout ? keyword_name(node, "layout") : nil)
        name.nil? ? nil : partialize(qualify(name, directory))
      end

      # The requested format, or nil to decline. Absent is `fallback`; a literal narrows; anything
      # computed is genuinely unknown and must not be guessed at `html`.
      def format_for(node, fallback)
        return nil if non_template?(node)

        value = keyword_argument(node, "formats") || keyword_argument(node, "format")
        return fallback if value.nil?

        literal = literal_name(value) || literal_name(array_head(value))
        literal&.split(".")&.last
      end

      def format_keyword?(node)
        !(keyword_argument(node, "formats") || keyword_argument(node, "format")).nil?
      end

      def non_template?(node)
        NON_TEMPLATE_OPTIONS.any? { |option| keyword_argument(node, option) }
      end

      def array_head(node)
        node.elements.first if node.is_a?(Prism::ArrayNode)
      end

      # `fallbacks` survives only when the name spelled no format of its own: `render "row.json"` from a
      # `.js` template is the author naming `json`, and a `js` table has nothing to say about it.
      def template_callee(name, format, fallbacks = nil)
        spelled = split_suffixes(name, nil).last
        name, format = split_suffixes(name, format)
        return nil if name.nil? || name.empty? || format.nil? || format.empty?
        return nil if name.include?(" ") || format.include?(" ") || format.include?(".")

        fallbacks = nil unless spelled.nil? && fallbacks && !fallbacks.empty?
        Callee.new(receiver: "#{TEMPLATE_PREFIX}#{name}", selector: format, fallbacks: fallbacks)
      end

      # Splits a written handler and format off the name's last segment, so `render "show.json"` names
      # `view:users/show` + `json` and `render template: "users/show.html.erb"` names
      # `view:users/show` + `html` rather than the impossible `view:users/show.html.erb.html`. A name
      # that spells a format wins over the rule's default, because the author said so; a name that
      # spells only a handler keeps the default.
      def split_suffixes(name, format)
        return [name, format] if name.nil?

        directory, separator, base = name.rpartition("/")
        segments = base.split(".")
        return [name, format] if segments.length <= 1

        stem = segments.shift
        segments.reject! { |segment| HANDLERS.include?(segment) }
        ["#{directory}#{separator}#{stem}", segments.first || format]
      end

      # `"card"` in `users` → `"users/_card"`; `"admin/card"` → `"admin/_card"`. A name already spelled
      # with the underscore keeps it, because that is what Rails accepts too.
      def partialize(name)
        return nil if name.nil?

        directory, separator, base = name.rpartition("/")
        return base.start_with?("_") ? name : "_#{name}" if separator.empty?

        base.start_with?("_") ? name : "#{directory}/_#{base}"
      end

      # A name with a `/` is rooted at the views directory; a bare one is relative to the rendering
      # unit's own directory.
      def qualify(name, directory)
        return nil if name.nil? || name.empty?
        return name if name.include?("/") || directory.nil? || directory.empty?

        "#{directory}/#{name}"
      end

      def keyword_name(node, key)
        literal_name(keyword_argument(node, key))
      end

      def literal_name(value)
        case value
        when Prism::SymbolNode, Prism::StringNode then value.unescaped
        end
      end

      def positional(node)
        node.arguments&.arguments&.grep_v(Prism::KeywordHashNode) || []
      end

      def keyword_argument(node, name)
        hash = node.arguments&.arguments&.find { |argument| argument.is_a?(Prism::KeywordHashNode) }
        pair = hash&.elements&.find do |element|
          element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode) &&
            element.key.unescaped == name
        end
        pair&.value
      end

      # `ActiveStorage` → `active_storage`. The engine's own reading of a constant segment; deliberately
      # not an inflector call, because a rule may read nothing outside the strings it was given.
      def underscore(segment)
        segment.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end

      private_class_method :rails_render, :rails_render_partial, :rails_implicit_render,
                           :controller_directory, :template_context, :template_name,
                           :positional_template, :positional_partial, :partial_name,
                           :format_for, :format_keyword?, :non_template?, :array_head, :template_callee,
                           :split_suffixes, :partialize,
                           :qualify, :keyword_name, :literal_name, :positional, :keyword_argument,
                           :underscore
    end
  end
end
