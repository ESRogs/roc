# META
~~~ini
description=Dollar-prefixed record field names are rejected
type=expr
~~~
# SOURCE
~~~roc
{ $field : "value" }
~~~
# EXPECTED
EXPECTED RECORD FIELD - dollar_prefix_field_name.md:1:3:1:9
# PROBLEMS

┌───────────────────────┐
│ EXPECTED RECORD FIELD ├─ I was parsing a record expression, and I ──────────┐
└┬──────────────────────┘  expected a lowercase field name.                   │
 │                                                                            │
 │  { $field : "value" }                                                      │
 │    ‾‾‾‾‾‾                                                                  │
 └─────────────────────────────────────────── dollar_prefix_field_name.md:1:3 ┘

    Record fields start with lowercase names. After the name, either write `:
    value` or omit the value to use field punning.

    For example:
        { name: "Ada", age }

    I found `$field` here.
    Dollar-prefixed names are mutable variables in Roc. Record fields are
    labels, so they cannot start with `$`.

# TOKENS
~~~zig
OpenCurly,LowerIdent,OpColon,StringStart,StringPart,StringEnd,CloseCurly,
EndOfFile,
~~~
# PARSE
~~~clojure
(e-malformed (reason "expected_expr_record_field_name"))
~~~
# FORMATTED
~~~roc

~~~
# CANONICALIZE
~~~clojure
(can-ir (empty true))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs)
	(expressions))
~~~
