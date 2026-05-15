# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    # ADR-16 Tier A worked plugin: recognises Sinatra's class-
    # level route DSL.
    #
    # Sinatra's modular style:
    #
    #     class MyApp < Sinatra::Base
    #       get "/hello" do
    #         "Hello #{params['name']}"
    #       end
    #
    #       post "/bye" do
    #         halt 403 if params["forbidden"]
    #         redirect "/landing"
    #       end
    #     end
    #
    # At runtime `Sinatra::Base#generate_method`
    # (`lib/sinatra/base.rb:1788-1793`) does `define_method(name,
    # &block); remove_method`, turning each block into a real
    # instance method of the user's app class. The substrate's
    # Tier A hook (`Rigor::Inference::MacroBlockSelfType`)
    # replays the same contract statically: the block runs with
    # `self : Nominal[MyApp]`, so bare identifiers (`params`,
    # `redirect`, `halt`, `session`, `headers`, `content_type`,
    # `body`, `status`, `erb`, …) resolve through
    # `Sinatra::Base`'s RBS via rigor's normal inference path.
    #
    # ## Reach
    #
    # All nine class-level HTTP verb methods Sinatra exposes:
    # `get`, `post`, `put`, `delete`, `head`, `options`, `patch`,
    # `link`, `unlink` (`lib/sinatra/base.rb:1531-1553`). Both
    # modular-style subclasses of `Sinatra::Base` and `Sinatra::Application`
    # (classic top-level style, when used via `class App <
    # Sinatra::Application`) match because the receiver
    # constraint accepts every subclass.
    #
    # ## What the plugin does NOT do (yet)
    #
    # - **Routing diagnostics.** Path uniqueness, conflict
    #   detection, named-route reverse lookup — none of these
    #   are in slice 1c's scope.
    # - **Custom helpers.** `helpers do ... end` blocks that
    #   inject module methods into the app's instance namespace
    #   are Tier C / Tier B work, not Tier A.
    # - **Configure / settings.** `configure do ... end` and
    #   `set :session_secret, "..."` are settings DSL, not
    #   route DSL — handled by separate substrate entries when
    #   demand surfaces.
    # - **Classic-style top-level routes.** A bare
    #   `get '/path' do ... end` at the top of a script (no
    #   enclosing `class < Sinatra::Base`) is the classic-mode
    #   pattern (`lib/sinatra/main.rb`). Tier A as currently
    #   wired requires the receiver's class to be visible at
    #   the call site; a top-level call's receiver is the
    #   classic-mode `Sinatra::Application`, which the
    #   `Sinatra::Delegator` mixin forwards from `main`. The
    #   classic style is deferred until the demand justifies
    #   the extra match shape.
    #
    # See `examples/rigor-sinatra/README.md` for usage and the
    # demo script under `examples/rigor-sinatra/demo/`.
    class Sinatra < Rigor::Plugin::Base
      manifest(
        id: "sinatra",
        version: "0.1.0",
        description: "Recognises Sinatra's class-level route DSL via ADR-16 Tier A.",
        block_as_methods: [
          Rigor::Plugin::Macro::BlockAsMethod.new(
            receiver_constraint: "Sinatra::Base",
            verbs: %i[get post put delete head options patch link unlink]
          )
        ]
      )
    end

    Rigor::Plugin.register(Sinatra)
  end
end
