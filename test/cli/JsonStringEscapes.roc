JsonStringEscapes :: [].{}

# --- encoder exact-output goldens ---

# the five named control escapes are emitted in short form
expect Json.to_str("\u(8)\u(9)\u(A)\u(C)\u(D)") == "\"\\b\\t\\n\\f\\r\""

# other control characters are emitted as lowercase \u00xx
expect Json.to_str("\u(0)\u(1)\u(1F)") == "\"\\u0000\\u0001\\u001f\""

# quotes and backslashes are escaped; solidus is not
expect Json.to_str("a\"b\\c/d") == "\"a\\\"b\\\\c/d\""

# non-ASCII text and DEL pass through as raw UTF-8
expect Json.to_str("café 中 \u(1F600)\u(7F)") == "\"café 中 \u(1F600)\u(7F)\""

# escaping applies inside containers: records (alphabetical field order),
# lists, tuples, and tag payloads
expect Json.to_str({ b: "q\"", a: "n\n" }) == "{\"a\":\"n\\n\",\"b\":\"q\\\"\"}"

expect Json.to_str(["a\tb", "c\\d"]) == "[\"a\\tb\",\"c\\\\d\"]"

expect Json.to_str(("x\n", "\"y\"")) == "[\"x\\n\",\"\\\"y\\\"\"]"

expect {
	value : [Wrap(Str)]
	value = Wrap("q\"")

	Json.to_str(value) == "{\"Wrap\":\"q\\\"\"}"
}
