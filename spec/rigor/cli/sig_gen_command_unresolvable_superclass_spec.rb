# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/sig_gen_command"

# #2437 — the skipped-class warning tells a superclass the project declares in source, but this run wrote nothing
# for, apart from one no source or RBS declares: only the second is fixed by providing a gem's RBS.
RSpec.describe Rigor::CLI::SigGenCommand do
  let(:root) { Dir.mktmpdir }

  around { |example| Dir.chdir(root) { example.run } }

  before { write(".rigor.yml", "paths:\n  - lib\n") }

  after { FileUtils.remove_entry(root) }

  def write(relative, body)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def sig_gen_err
    err = StringIO.new
    described_class.new(argv: ["--write", "lib", "--config=#{File.join(root, '.rigor.yml')}"], out: StringIO.new,
                        err: err).run
    err.string
  end

  it "advises typing or declaring a project superclass whose methods were all skipped" do
    write("lib/base.rb", "module Lib\n  class Base\n    def name = 1\n  end\nend\n")
    write("lib/text_base.rb", "module Lib\n  class TextBase < Base\n    def render(x) = x.whatever\n  end\nend\n")
    write("lib/cdata.rb", "module Lib\n  class Cdata < TextBase\n    def tag = 1\n  end\nend\n")

    err = sig_gen_err

    expect(err).to include("superclass this run wrote no signature for", "  Lib::Cdata < Lib::TextBase\n")
    expect(err).not_to include("rbs collection install")
  end

  it "keeps the provide-RBS advice for a superclass nothing declares" do
    write("lib/sub.rb", "class Sub < Missing\n  def x = 1\nend\n")

    err = sig_gen_err

    expect(err).to include("superclass no loaded RBS declares", "rbs collection install", "  Sub < Missing\n")
    expect(err).not_to include("wrote no signature for")
  end

  # The root is a project class, but writing it would not help: its own superclass is a gem's, with no RBS.
  it "keeps the provide-RBS advice for a project superclass whose own chain leaves the project" do
    write("lib/application_record.rb", "class ApplicationRecord < ActiveRecord::Base\nend\n")
    write("lib/post.rb", "class Post < ApplicationRecord\n  def x = 1\nend\n")

    err = sig_gen_err

    expect(err).to include("superclass no loaded RBS declares", "  Post < ApplicationRecord\n")
    expect(err).not_to include("wrote no signature for")
  end
end
