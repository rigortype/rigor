require "rigor/testing"
require "cgi/util"
require "uri"
include Rigor::Testing

# Regexp.escape / Regexp.quote — deterministic folding over literal strings.
# The escape tier is wired after ShellwordsFolding in dispatch_precise_tiers.

# --- Regexp.escape / quote ---

_regexp_escaped = Regexp.escape("hello.world")
assert_type('"hello\\\\.world"', _regexp_escaped)
_regexp_quoted = Regexp.quote("[a-z]")
assert_type('"\\\\[a\\\\-z\\\\]"', _regexp_quoted)

# --- Regexp.new ---

_regexp_plain = Regexp.new("hello")
assert_type("/hello/", _regexp_plain)
_regexp_new_flags = Regexp.new("world", 1) # 1 == Regexp::IGNORECASE; constant literal required for fold
assert_type("/world/i", _regexp_new_flags)

# --- Regexp.compile (documented alias of Regexp.new; shares fold_new) ---

_regexp_compiled = Regexp.compile("hello")
assert_type("/hello/", _regexp_compiled)
_regexp_compile_flags = Regexp.compile("world", 1)
assert_type("/world/i", _regexp_compile_flags)

# --- Regexp.union ---

_regexp_union_splat = Regexp.union("a", "b")
assert_type("/a|b/", _regexp_union_splat)
_regexp_union_array = Regexp.union(%w[a b])
assert_type("/a|b/", _regexp_union_array)
_regexp_union_empty = Regexp.union
assert_type("/(?!)/", _regexp_union_empty)
_regexp_union_mixed = Regexp.union("a", /b/)
assert_type("/a|(?-mix:b)/", _regexp_union_mixed)

# --- Regexp.linear_time? ---

_linear_time_str = Regexp.linear_time?("a.*b")
assert_type("true", _linear_time_str)
_linear_time_regexp = Regexp.linear_time?(/a.*b/)
assert_type("true", _linear_time_regexp)

# --- CGI.escapeHTML / h / unescapeHTML ---

assert_type('"&lt;b&gt;"', CGI.escapeHTML("<b>"))
assert_type('"&lt;b&gt;"', CGI.h("<b>"))
assert_type('"<b>"', CGI.unescape_html("&lt;b&gt;"))

# --- CGI.escape / unescape (URL) ---

assert_type('"hello+world"', CGI.escape("hello world"))

# --- CGI.escapeURIComponent ---

_uri_comp = CGI.escape_uri_component("hello world")
assert_type('"hello%20world"', _uri_comp)

# --- URI.encode_www_form_component / decode ---

_encoded = URI.encode_www_form_component("hello world")
assert_type('"hello+world"', _encoded)
assert_type('"hello world"', URI.decode_www_form_component("hello+world"))

# --- URI.encode_www_form / decode_www_form (whole-form) ---

assert_type('"k=v&x=1"', URI.encode_www_form([%w[k v], %w[x 1]]))
assert_type('"k=v"', URI.encode_www_form({ "k" => "v" }))
# The inverse lifts to a Tuple of pairs, so a destructuring read reaches the
# concrete strings instead of the RBS tier's `Array[[String, String]]`.
assert_type('[["k", "v"], ["x", "1"]]', URI.decode_www_form("k=v&x=1"))
assert_type('["http://a.example"]', URI.extract("see http://a.example x"))

# --- Non-constant fallback to RBS ---

str = rand > 0.5 ? "hello" : "world"
assert_type("String", Regexp.escape(str))
assert_type("String", CGI.escapeHTML(str))
assert_type("String", URI.encode_www_form_component(str))
assert_type("Regexp", Regexp.compile(str))
assert_type("Regexp", Regexp.union(str, "b"))
assert_type("bool", Regexp.linear_time?(str))
assert_type("String", URI.encode_www_form([["k", str]]))
assert_type("Array[[String, String]]", URI.decode_www_form(str))
