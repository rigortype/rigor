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

# --- Non-constant fallback to RBS ---

str = rand > 0.5 ? "hello" : "world"
assert_type("String", Regexp.escape(str))
assert_type("String", CGI.escapeHTML(str))
assert_type("String", URI.encode_www_form_component(str))
