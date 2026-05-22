# frozen_string_literal: true

# Wiring for the demo app: build a RigWeb router and register the
# two controllers. This is the snippet from the rigor-web README,
# made into a real analysable file.
#
# Run the analysis from this `demo/` directory with the plugin on
# the load path:
#
#   RUBYLIB=$PWD/../lib bundle exec rigor check

require_relative "rig_web"
require_relative "controller/home_controller"
require_relative "controller/hello_controller"

# define routes
router = RigWeb.new
router.get("/", [HomeController, :get])
router.get("/hello", [HelloController, :get])
