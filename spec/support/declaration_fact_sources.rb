# frozen_string_literal: true

# #1507 — the source census the declaration-fact gates share (`spec/rigor/declaration_facts/`): the Ruby files under
# `lib/` and `plugins/*/lib/`, read once, with their comment lines dropped so a mention in prose never counts as code.
module DeclarationFactSources
  REPO_ROOT = File.expand_path("../..", __dir__)

  module_function

  # `{relative path => code}` for every covered file under `base`, full-line comments removed.
  def code_under(base = REPO_ROOT)
    paths = Dir.glob("lib/**/*.rb", base: base) + Dir.glob("plugins/*/lib/**/*.rb", base: base)
    paths.sort.to_h { |path| [path, code_of(File.read(File.join(base, path)))] }
  end

  def code_of(source)
    source.each_line.reject { |line| line.lstrip.start_with?("#") }.join
  end
end
