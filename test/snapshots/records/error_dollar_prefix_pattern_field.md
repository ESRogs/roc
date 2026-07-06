# META
~~~ini
description=Dollar-prefixed pattern record field names are rejected
type=expr
~~~
# SOURCE
~~~roc
match person {
    { $name } => $name
}
~~~
# EXPECTED
EXPECTED PATTERN FIELD - error_dollar_prefix_pattern_field.md:2:7:2:12
# PROBLEMS

┌────────────────────────┐
│ EXPECTED PATTERN FIELD ├─ I was parsing a record pattern, and I expected ───┐
└┬───────────────────────┘  a lowercase field name.                           │
 │                                                                            │
 │  { $name } => $name                                                        │
 │    ‾‾‾‾‾                                                                   │
 └────────────────────────────────── error_dollar_prefix_pattern_field.md:2:7 ┘

    Record pattern fields start with lowercase names. You can bind the field
    directly or write `name: pattern`.

    For example:
        { name, age: years }

    I found `$name` here.
    Dollar-prefixed names are mutable variables in Roc. Record fields are
    labels, so they cannot start with `$`.

# TOKENS
~~~zig
KwMatch,LowerIdent,OpenCurly,
OpenCurly,LowerIdent,CloseCurly,OpFatArrow,LowerIdent,
CloseCurly,
EndOfFile,
~~~
# PARSE
~~~clojure
(e-match
	(e-ident (raw "person"))
	(branches
		(branch
			(p-malformed (tag "expected_lower_ident_pat_field_name"))
			(e-ident (raw "$name")))))
~~~
# FORMATTED
~~~roc
match person {
	 => $name
}
~~~
# CANONICALIZE
~~~clojure
(e-match
	(match
		(cond
			(e-runtime-error (tag "ident_not_in_scope")))
		(branches
			(branch
				(patterns
					(pattern (degenerate false)
						(p-runtime-error (tag "pattern_not_canonicalized"))))
				(value
					(e-runtime-error (tag "ident_not_in_scope")))))))
~~~
# TYPES
~~~clojure
(expr (type "Error"))
~~~
