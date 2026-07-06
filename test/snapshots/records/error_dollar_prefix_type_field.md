# META
~~~ini
description=Dollar-prefixed type record field names are rejected
type=statement
~~~
# SOURCE
~~~roc
Person : { $name : Str }
~~~
# EXPECTED
EXPECTED TYPE FIELD - error_dollar_prefix_type_field.md:1:12:1:17
# PROBLEMS

┌─────────────────────┐
│ EXPECTED TYPE FIELD ├─ I was parsing a record type, and I expected a ───────┐
└┬────────────────────┘  field name.                                          │
 │                                                                            │
 │  Person : { $name : Str }                                                  │
 │             ‾‾‾‾‾                                                          │
 └──────────────────────────────────── error_dollar_prefix_type_field.md:1:12 ┘

    Record type fields start with lowercase names, `_`, or named underscores,
    followed by `:` and the field type.

    For example:
        { name : Str, age : U64 }

    I found `$name` here.
    Dollar-prefixed names are mutable variables in Roc. Record fields are
    labels, so they cannot start with `$`.

# TOKENS
~~~zig
UpperIdent,OpColon,OpenCurly,LowerIdent,OpColon,UpperIdent,CloseCurly,
EndOfFile,
~~~
# PARSE
~~~clojure
(s-type-decl
	(header (name "Person")
		(args))
	(ty-malformed (tag "expected_type_field_name")))
~~~
# FORMATTED
~~~roc
Person : 
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(s-alias-decl
		(ty-header (name "Person"))
		(ty-malformed)))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs)
	(type_decls
		(alias (type "Person")
			(ty-header (name "Person"))))
	(expressions))
~~~
