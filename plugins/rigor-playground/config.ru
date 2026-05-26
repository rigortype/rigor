# frozen_string_literal: true

# Start: bundle exec puma -C puma.rb

require_relative "lib/rigor/playground/app"

run Rigor::Playground::App.new
