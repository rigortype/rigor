# frozen_string_literal: true

require "sassc"

engine = SassC::Engine.new("$blue: #00f; body { color: $blue; }")
puts engine.render
