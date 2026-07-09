StrSplitAtUtf8Byte :: [].{}

# splitting mid-string yields both halves as slices
expect "hello world".split_at_utf8_byte(5) == Ok({ before: "hello", after: " world" })

# offset 0 splits off an empty prefix
expect "abc".split_at_utf8_byte(0) == Ok({ before: "", after: "abc" })

# offset == length splits off an empty suffix
expect "abc".split_at_utf8_byte(3) == Ok({ before: "abc", after: "" })

# the empty string splits only at 0
expect "".split_at_utf8_byte(0) == Ok({ before: "", after: "" })
expect "".split_at_utf8_byte(1) == Err(OutOfBounds)

# a multi-byte character's start is a valid boundary
expect "café".split_at_utf8_byte(3) == Ok({ before: "caf", after: "é" })

# inside a 2-byte character is not a boundary
expect "café".split_at_utf8_byte(4) == Err(NotACharacterBoundary)

# past the end is out of bounds (café is 5 bytes)
expect "café".split_at_utf8_byte(9) == Err(OutOfBounds)

# every interior byte of a 4-byte character is rejected
expect "🦅".split_at_utf8_byte(1) == Err(NotACharacterBoundary)
expect "🦅".split_at_utf8_byte(2) == Err(NotACharacterBoundary)
expect "🦅".split_at_utf8_byte(3) == Err(NotACharacterBoundary)
expect "🦅".split_at_utf8_byte(4) == Ok({ before: "🦅", after: "" })

# a boundary found via count_utf8_bytes round-trips
expect {
	s = "wing span"
	offset = Str.count_utf8_bytes("wing")

	s.split_at_utf8_byte(offset) == Ok({ before: "wing", after: " span" })
}

# splitting a long (heap) string works the same as a small one
expect {
	s = Str.repeat("x", 100).concat("é")

	match s.split_at_utf8_byte(100) {
		Ok(parts) => Str.count_utf8_bytes(parts.before) == 100 and parts.after == "é"
		Err(_) => False
	}
}
