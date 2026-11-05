# ADR-129 G1' witness for :threaded_block_body (the threaded-flag fixture of ADR-129 Context). The outer block's body
# is folded with threading suppressed, so the nested block, typed from the same scope object, is typed under another
# frame than the statement pass types it under: with the flag ignored, the nested tail would be typed over the entry
# binding of `d` rather than the prefix's.
[1, 2].map do |a|
  b = a.to_s
  [3].map do |c|
    d = c + 1
    d.to_s + b
  end
end
