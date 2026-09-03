# frozen_string_literal: true

require "ethon"

easy = Ethon::Easy.new(url: "http://example.com")
code = easy.perform
puts "HTTP status: #{code}"
