root = File.expand_path(ARGV[0]); target_root = File.expand_path(ARGV[1]); args = ARGV[2..]
Dir.chdir(target_root); $LOAD_PATH.unshift(File.join(root, "lib")); require "rigor/cli"
begin
  Rigor::CLI.new(args, out: $stdout, err: $stderr).run
rescue SystemExit
end
