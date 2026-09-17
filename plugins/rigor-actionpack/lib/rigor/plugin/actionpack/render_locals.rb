# frozen_string_literal: true

require "prism"

require_relative "controller_scan"
require_relative "erb_compiler"
require_relative "view_assigns"
require_relative "view_units"

module Rigor
  module Plugin
    class Actionpack < Rigor::Plugin::Base
      # #1047 — the locals a render site passes, indexed by the template they are passed TO.
      #
      # #393 seeded a template's `locals:` from the Rails 7.1 strict-locals comment only, so a partial
      # without one read its own parameters as method calls on the view context. That absence has a
      # measured cost rather than a theoretical one: redmine's `app/views/common/_other.html.erb` opens
      # with the standard optional-local preamble
      #
      #     <% path = nil unless defined? path %>
      #
      # and the compiled Ruby really does assign nil there, because nothing told the unit that `path` is
      # bound — so the flow rules folded three live branches and `flow.` had to join `call.` in the
      # plugin's default suppressed set for that reason alone
      # (`docs/notes/20260917-erb-template-units.md` § 4). Tracing the render site is what lets the flow
      # rules back into a view.
      #
      # ## Why over-binding is the safe direction and under-binding is not
      #
      # A name this index seeds that the render site did not really pass costs nothing: the local binds
      # `Dynamic`, `defined?` reads it as bound, and no rule folds anything. A name it MISSES is the
      # false positive above. So the union across render sites is deliberately generous — a name bound at
      # only some of a partial's render sites is seeded anyway, typed `Dynamic`, never left absent — and
      # every shape below that cannot be settled from literals contributes a NAME with no type rather
      # than nothing.
      #
      # The one thing that is not generous is the TYPE. A type is a claim the engine acts on, so a name
      # keeps a concrete type only when every site that passes it passes the same one; anything else is
      # {ViewUnits::UNKNOWN_LOCAL}, which the engine binds `Dynamic[top]` (ADR-5).
      #
      # ## What a render site is read for
      #
      # Both sides of the render, because both bind the same thing:
      #
      # - a **controller** site, through {Analyzer.render_target_for} — `render partial: "card",
      #   locals: { user: @user }`;
      # - a **template** site, in the compiled Ruby of every view — the same keyword form, plus the
      #   positional-hash form `render "card", user: @user`, which is locals in a view and OPTIONS in a
      #   controller (`ActionView::Helpers::RenderingHelper#render(options, locals)` against
      #   `ActionController::Base#render(options)`). Reading the controller form as locals would seed a
      #   `status` local for every `render :show, status: :ok` in the corpus.
      #
      # `collection:` and `object:` bind a local named after the partial, or after `as:` when given, and a
      # collection additionally binds the `_counter` and `_iteration` companions Rails provides.
      #
      # ## The compiled-source cache
      #
      # Building the index compiles every template in the project, and `#template_units_for_file` is about
      # to compile each of them again. So the builder keeps what it compiled, keyed by path and guarded by
      # the template's own scrubbed bytes, and the hook reuses it — a full run does exactly the compile
      # work it did before this feature, one pass instead of two. What it does not preserve is #1038's
      # per-keystroke property: an editor buffer bound to ONE template still builds the whole index, so an
      # LSP publish on a view costs one project-wide compile pass rather than one file. Recorded in the
      # manual; the fix is an index that is itself carried, which is the same slice as making template
      # units first-class incremental dependents.
      class RenderLocals
        # What a name is seeded with when no site settled a type for it, or when two disagreed.
        UNKNOWN = ViewUnits::UNKNOWN_LOCAL

        # Finders and constructors whose Rails implementation raises rather than returning nil — the same
        # closed set {ViewAssigns::NON_NIL_PRODUCERS} names, and for the same reason: a nil-free nominal
        # standing in for a runtime nil licenses folds that report correct code.
        NON_NIL_PRODUCERS = ViewAssigns::NON_NIL_PRODUCERS

        # `{ "common/_other" => { "path" => UNKNOWN, … } }`, keyed by logical name with the format
        # stripped — a partial's locals do not depend on which format rendered it.
        attr_reader :by_template

        def initialize(by_template, compiled = {})
          @by_template = by_template.freeze
          @compiled = compiled.freeze
          freeze
        end

        def self.empty
          new({})
        end

        # `common/_other.html` → the names every site that renders `common/_other` passed.
        def seeds_for(logical_name)
          @by_template.fetch(logical_name.to_s.sub(%r{\.[^./]+\z}, ""), {})
        end

        # The `[compiled, line_map, transform_id, parse_ok]` this index already computed for `path`, or nil
        # when it read different bytes (an editor buffer) or never saw the file. The bytes are compared
        # rather than trusted: a unit compiled from the file on disk must never stand in for one the editor
        # is holding.
        def compiled_for(path, text)
          entry = @compiled[path.to_s]
          return nil if entry.nil? || entry.first != text

          entry.drop(1)
        end

        # Builds the index from the controller sources and the templates the plugin claims.
        class Builder
          def initialize(io_boundary:, controller_search_paths:, view_search_paths:, view_assigns:)
            @io_boundary = io_boundary
            @controller_search_paths = controller_search_paths
            @view_search_paths = view_search_paths
            @view_assigns = view_assigns
            # `{ target => [ { name => type_name_or_nil }, … ] }` — one hash per render site, merged only
            # once every site has been seen, because "bound at some sites" is a property of the whole set.
            @sites = Hash.new { |hash, key| hash[key] = [] }
          end

          def build
            harvest_controllers
            compiled = harvest_templates
            RenderLocals.new(@sites.transform_values { |sites| merge(sites) }, compiled)
          end

          private

          # Two sites that agree on a name and its type keep the type; anything else — a disagreement, a
          # site that settled no type, or a site that did not pass the name at all — is `Dynamic`.
          def merge(sites)
            names = sites.flat_map(&:keys).uniq
            names.to_h do |name|
              types = sites.map { |site| site.key?(name) ? site[name] : :absent }.uniq
              [name, types.length == 1 && types.first.is_a?(String) ? types.first : UNKNOWN]
            end
          end

          def harvest_controllers
            source_files(@controller_search_paths, "*.rb").each do |path|
              tree = parse_file(path)
              next if tree.nil?

              ControllerScan.each_controller(tree, []) do |node, namespace|
                harvest_controller(node, namespace)
              end
            end
          end

          def harvest_controller(node, namespace)
            segments = namespace + ControllerScan.constant_segments(node.constant_path)
            prefix = ControllerScan.controller_path(segments)
            return if prefix.nil?

            ControllerScan.method_bodies(node).each do |action, body|
              ivars = @view_assigns.seeds_for("#{prefix}/#{action}")
              ControllerScan.each_render(body) do |call|
                record(controller_target(call, prefix), call, ivars, view_side: false)
              end
            end
          end

          # {Analyzer.render_target_for} already answers this for a controller: `render :edit`,
          # `render "admin/shared/form"`, `render partial: "card"`. Its `[:template, name]` /
          # `[:partial, name]` pair reduces to the name, because the locals of a template and of a partial
          # are seeded the same way.
          def controller_target(call, prefix)
            Analyzer.render_target_for(call, prefix)&.last
          end

          # Every claimed template, compiled once. Returns the `{ path => [text, compiled, map, id, ok] }`
          # cache `#template_units_for_file` reuses.
          def harvest_templates
            source_files(@view_search_paths, "*.erb").each_with_object({}) do |path, compiled|
              text = read(path)
              next if text.nil?

              text = ErbCompiler.scrub(text)
              source, line_map, transform = ErbCompiler.compile(text)
              result = Prism.parse(source)
              compiled[path] = [text, source, line_map, transform, result.errors.empty?]
              next unless result.errors.empty?

              harvest_template(path, result.value)
            end
          rescue ErbCompiler::Unmappable
            {}
          end

          def harvest_template(path, tree)
            name = ViewUnits.logical_name(path, @view_search_paths).sub(%r{\.[^./]+\z}, "")
            directory = name.include?("/") ? File.dirname(name) : ""
            ivars = @view_assigns.seeds_for(name)
            ControllerScan.each_render(tree) do |call|
              record(template_target(call, directory), call, ivars, view_side: true)
            end
          end

          # The view-side reading of a render target, which differs from the controller's in exactly one
          # place: a bare positional name is a PARTIAL here. `template:` is the escape hatch an author uses
          # when they mean otherwise, and `layout:` in a view names a partial too — the same reading
          # {Effects::CalleeRule.rails_render_partial} takes, for the same reason.
          def template_target(call, directory)
            explicit = string_option(call, "template")
            return qualify(explicit, directory) if explicit

            partial = string_option(call, "partial") || string_option(call, "layout")
            return partialize(qualify(partial, directory)) if partial

            positional = (call.arguments&.arguments || []).grep_v(Prism::KeywordHashNode).first
            return nil unless positional.is_a?(Prism::StringNode) || positional.is_a?(Prism::SymbolNode)

            partialize(qualify(positional.unescaped, directory))
          end

          def record(target, call, ivars, view_side:)
            return if target.nil? || target.empty?

            locals = locals_at(call, target, ivars, view_side: view_side)
            @sites[target] << locals
          end

          # The names one render site binds, and the type of each where the site settled one.
          def locals_at(call, target, ivars, view_side:)
            arguments = call.arguments&.arguments || []
            options = arguments.find { |argument| argument.is_a?(Prism::KeywordHashNode) }
            locals = {}
            # `render "card", user: @user` — the view's second positional argument IS the locals hash, and
            # the controller's is options. Read alongside an explicit `locals:` rather than instead of it,
            # because over-binding is the safe direction.
            collect_pairs(options, locals, ivars) if view_side && !arguments.first.is_a?(Prism::KeywordHashNode)
            collect_pairs(option(call, "locals"), locals, ivars)
            collect_object_locals(call, target, locals, ivars)
            locals
          end

          # `locals: { user: @user }` and its hashrocket spelling. A key that is not a literal symbol or
          # string — a computed key, a `**splat` — names nothing this can seed, and is skipped rather than
          # guessed at.
          def collect_pairs(hash, locals, ivars)
            return unless hash.is_a?(Prism::HashNode) || hash.is_a?(Prism::KeywordHashNode)

            hash.elements.each do |element|
              next unless element.is_a?(Prism::AssocNode)

              name = literal_name(element.key)
              next if name.nil? || !name.match?(/\A[a-z_][A-Za-z0-9_]*\z/)

              locals[name] = value_type(element.value, ivars)
            end
          end

          # `object:` binds one local named after the partial; `collection:` binds the same name plus the
          # `_counter` and `_iteration` companions Rails provides, and never a type — the local is the
          # ELEMENT, and nothing at the site names the element's class.
          def collect_object_locals(call, target, locals, ivars)
            base = literal_name(option(call, "as")) || File.basename(target).delete_prefix("_")
            return unless base.match?(/\A[a-z_][A-Za-z0-9_]*\z/)

            object = option(call, "object")
            collection = option(call, "collection")
            locals[base] = value_type(object, ivars) if object
            return if collection.nil?

            locals[base] = nil
            locals["#{base}_counter"] = nil
            locals["#{base}_iteration"] = nil
          end

          # The two shapes a render site settles a type from, and nothing else: a non-nil-able finder or
          # constructor on a constant (`User.find(params[:id])`), and an ivar the rendering unit's own
          # seeds already typed. Anything else is a name with no type.
          def value_type(node, ivars)
            case node
            when Prism::InstanceVariableReadNode then ivars[node.name.to_s]
            when Prism::CallNode then produced_type(node)
            end
          end

          def produced_type(call)
            return nil unless NON_NIL_PRODUCERS.include?(call.name)

            receiver = call.receiver
            return nil unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)

            name = ControllerScan.constant_segments(receiver).join("::")
            name.empty? ? nil : name
          end

          def option(call, key)
            hash = call.arguments&.arguments&.find { |argument| argument.is_a?(Prism::KeywordHashNode) }
            pair = hash&.elements&.find do |element|
              element.is_a?(Prism::AssocNode) && literal_name(element.key) == key
            end
            pair&.value
          end

          def string_option(call, key)
            value = option(call, key)
            value.is_a?(Prism::StringNode) || value.is_a?(Prism::SymbolNode) ? value.unescaped : nil
          end

          def literal_name(node)
            node.unescaped if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
          end

          def qualify(name, directory)
            return nil if name.nil? || name.empty?
            return name if name.include?("/") || directory.empty?

            "#{directory}/#{name}"
          end

          def partialize(name)
            return nil if name.nil?

            directory, separator, base = name.rpartition("/")
            return base.start_with?("_") ? name : "_#{name}" if separator.empty?

            base.start_with?("_") ? name : "#{directory}/_#{base}"
          end

          # Project-relative paths, the spelling `#template_units_for_file` is handed and the spelling the
          # compiled cache is keyed by.
          def source_files(roots, pattern)
            root_prefix = "#{Dir.pwd}#{File::SEPARATOR}"
            roots.flat_map do |root|
              absolute = File.expand_path(root)
              next [] unless @io_boundary.directory?(absolute)

              Dir.glob(File.join(absolute, "**", pattern)).map { |path| path.delete_prefix(root_prefix) }
            end
          end

          def read(path)
            @io_boundary.read_file(File.expand_path(path))
          rescue Plugin::AccessDeniedError, Errno::ENOENT
            nil
          end

          def parse_file(path)
            contents = read(path)
            return nil if contents.nil?

            result = Prism.parse(contents)
            result.errors.empty? ? result.value : nil
          end
        end
      end
    end
  end
end
