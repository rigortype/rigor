require "json"
a = JSON.parse(File.read(ARGV[0])); b = JSON.parse(File.read(ARGV[1]))
n = (ARGV[2] || 30).to_i
puts "total #{a['total']} -> #{b['total']} (#{b['total'] - a['total']})"
keys = a["rows"].keys | b["rows"].keys
d = keys.map { |k| x = a["rows"][k] || [0, 0]; y = b["rows"][k] || [0, 0]; [k, y[0] - x[0], x[0], y[0], x[1], y[1]] }
d.sort_by { -_2.abs }.first(n).each { |k, dd, x, y, cx, cy| printf("%+10d  %9d -> %9d  calls %7d -> %7d  %s\n", dd, x, y, cx, cy, k) }
