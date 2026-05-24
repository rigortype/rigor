# frozen_string_literal: true
# Start: bundle exec puma -C puma.rb

require_relative "lib/playground/app"

run Playground::App.new
