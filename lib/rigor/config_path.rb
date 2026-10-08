# frozen_string_literal: true

module Rigor
  # Resolves a path-valued setting that a person wrote into `.rigor.yml`, or that Bundler wrote into its
  # own config (`BUNDLE_PATH: "~/gems"`), to an absolute path.
  #
  # A leading `~/` and a bare `~` expand to the invoking user's home directory — exactly what
  # `File.expand_path` does for those two spellings, and what Bundler itself does for `BUNDLE_PATH`. Every
  # other spelling goes through `File.absolute_path`, so `~drafts/x` stays a directory named `~drafts`
  # instead of `File.expand_path`'s home-of-user-`drafts` reading, which raises `ArgumentError` for a user
  # that does not exist (#1510). It never raises on a `~`.
  #
  # Paths the analysis is *given to analyse* (CLI path arguments, template units, the runner's file sets)
  # do not use this: the shell has already expanded a `~` there, so a surviving one is a directory name.
  module ConfigPath
    HOME_PREFIX = %r{\A~(?=/|\z)}

    # `base_dir` anchors a relative result and defaults to the working directory.
    def self.absolute(path, base_dir = nil)
      text = path.to_s
      return File.absolute_path(text, base_dir) unless text.match?(HOME_PREFIX)

      home = Dir.home
      File.absolute_path(text.sub(HOME_PREFIX, home), base_dir)
    rescue ArgumentError
      File.absolute_path(text, base_dir)
    end
  end
end
