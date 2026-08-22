# frozen_string_literal: true

module Rigor
  # A mistake in the project's configuration — a value `Configuration` cannot proceed on (the tier-2
  # failures `docs/internal-spec/config.md` enumerates), or a `.rigor.yml` key the loader accepted whose
  # meaning only resolves later, like an `effects.snapshot.reach:` preset name.
  #
  # It exists so the CLI can tell **the user got the file wrong** apart from **Rigor got itself wrong**.
  # Both used to reach the terminal as an uncaught `ArgumentError` with a thirty-frame backtrace naming a
  # file inside `lib/rigor/`, which reads as a crash: the reader's first move is to file a bug, not to
  # fix the key the message already named (#433). {CLI#run} rescues this class and renders it as a single
  # `rigor:` line.
  #
  # It stays an `ArgumentError` subclass deliberately. `Configuration` raised `ArgumentError` from every
  # coercion since the beginning, that is the documented tier-2 contract, and callers outside the CLI —
  # the language server, embedders, the suite — rescue it by that name. Narrowing the class is a
  # presentation change, not a contract change.
  class ConfigurationError < ArgumentError
  end
end
