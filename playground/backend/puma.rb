# frozen_string_literal: true

bind "tcp://127.0.0.1:9292"
workers 0      # single-process (no fork); Rigor requires no shared mutable state
threads 1, 1   # single thread; Rigor::CLI.start is not reentrant across threads
