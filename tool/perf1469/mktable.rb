# encoding: utf-8
require "json"
r = JSON.parse(File.read("rows.json"))
fmt = ->(n) { s = n.abs.to_s.reverse.scan(/\d{1,3}/).join(",").reverse; n.negative? ? "−" + s : s }
sg = ->(n) { n.positive? ? "+" + fmt.(n) : (n.zero? ? "0" : fmt.(n)) }
out = ["| # | merge | PR | allocations | Δ | diags | wall s | title |", "| ---: | --- | --- | ---: | ---: | ---: | ---: | --- |"]
out << "| 0 | `5ae05195` (v0.3.9) | | 23,705,247 | | 1 | 14.49 | the base engine |"
r.each_with_index do |(sha, pr, a, d, dg, w, t), i|
  t = t.gsub("|", "\\|")
  t = t[0, 90] + "…" if t.size > 91
  prc = pr ? "[##{pr}]" : ""
  out << "| #{i + 1} | `#{sha[0, 8]}` | #{prc} | #{fmt.(a)} | #{sg.(d)} | #{dg} | #{w} | #{t} |"
end
File.write("table.md", out.join("\n") + "\n")
File.write("links.md", r.map { _1[1] }.compact.uniq.map(&:to_i).sort.map { "[##{_1}]: https://github.com/rigortype/rigor/pull/#{_1}" }.join("\n") + "\n")
puts out.size, r.count { _1[1].nil? }
