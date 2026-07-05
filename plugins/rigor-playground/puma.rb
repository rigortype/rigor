# frozen_string_literal: true

# ADR-29 WD5 — bind 127.0.0.1 for local development, 0.0.0.0 in containers (Fly.io and the included
# Dockerfile). The Dockerfile / fly.toml export `PORT=8080`; absent that the dev default keeps the old 9292
# binding so `bundle exec puma -C puma.rb` is unchanged for contributors.
host = ENV.fetch("RACK_ENV", "development") == "production" ? "0.0.0.0" : "127.0.0.1"
port = ENV.fetch("PORT", "9292").to_i
bind "tcp://#{host}:#{port}"

workers 0      # single-process (no fork); Rigor requires no shared mutable state
threads 1, 1   # single thread; Rigor::CLI.start is not reentrant across threads
