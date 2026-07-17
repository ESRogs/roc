# META
~~~ini
description=Nominal-value destructuring (Type.(pat)) on the LHS of a = definition
type=snippet
~~~
# SOURCE
~~~roc
Distance := { x : U64 }

double : Distance -> U64
double = |d| {
		Distance.({x}) = d
    x * 2
}

Distance.{x} = Distance.{ x : 10 }
~~~
# EXPECTED
NIL
# PROBLEMS

┌────────────────────────────────────┐
│ TYPE APPLICATION NEEDS PARENTHESES ├─ I was parsing a type annotation, ─────┐
└┬───────────────────────────────────┘  and I found a type argument without   │
 │                                      parentheses.                          │
 │                                                                            │
 │  Distance.{x} = Distance.{ x : 10 }                                        │
 │          ‾                                                                 │
 └──────────────────────────────────── nominal_destructure_record_decl.md:9:9 ┘

    Roc type applications use parentheses around their arguments. Write
    `List(U8)`, not `List U8`.

    For example:
        List(U8)

    I found `.` here.

# TOKENS
~~~zig
UpperIdent,OpColonEqual,OpenCurly,LowerIdent,OpColon,UpperIdent,CloseCurly,
LowerIdent,OpColon,UpperIdent,OpArrow,UpperIdent,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,OpenCurly,
UpperIdent,Dot,NoSpaceOpenRound,OpenCurly,LowerIdent,CloseCurly,CloseRound,OpAssign,LowerIdent,
LowerIdent,OpStar,Int,
CloseCurly,
UpperIdent,Dot,OpenCurly,LowerIdent,CloseCurly,OpAssign,UpperIdent,Dot,OpenCurly,LowerIdent,OpColon,Int,CloseCurly,
EndOfFile,
~~~
# PARSE
~~~clojure
(file
	(type-mod)
	(statements
		(s-type-decl
			(header (name "Distance")
				(args))
			(ty-record
				(anno-record-field (name "x")
					(ty (name "U64")))))
		(s-type-anno (name "double")
			(ty-fn
				(ty (name "Distance"))
				(ty (name "U64"))))
		(s-decl
			(p-ident (raw "double"))
			(e-lambda
				(args
					(p-ident (raw "d")))
				(e-block
					(statements
						(s-decl
							(p-tag (raw "Distance")
								(p-record
									(field (name "x") (rest false))))
							(e-ident (raw "d")))
						(e-binop (op "*")
							(e-ident (raw "x"))
							(e-int (raw "2")))))))
		(s-malformed (tag "expected_colon_after_type_annotation"))
		(s-decl
			(p-record
				(field (name "x") (rest false)))
			(e-nominal-record
				(mapper (e-tag (raw "Distance")))
				(backing (e-record
						(field (field "x")
							(e-int (raw "10")))))))))
~~~
# FORMATTED
~~~roc
Distance := { x : U64 }

double : Distance -> U64
double = |d| {
	Distance.({ x }) = d
	x * 2
}
{ x } = Distance.{ x: 10 }
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "double"))
		(e-lambda
			(args
				(p-assign (ident "d")))
			(e-block
				(s-let
					(p-nominal
						(p-record-destructure
							(destructs
								(record-destruct (label "x") (ident "x")
									(required
										(p-assign (ident "x")))))))
					(e-lookup-local
						(p-assign (ident "d"))))
				(e-dispatch-call (method "times") (constraint-fn-var 224)
					(receiver
						(e-lookup-local
							(p-assign (ident "x"))))
					(args
						(e-num (value "2"))))))
		(annotation
			(ty-fn (effectful false)
				(ty-lookup (name "Distance") (local))
				(ty-lookup (name "U64") (builtin)))))
	(d-let
		(p-record-destructure
			(destructs
				(record-destruct (label "x") (ident "x")
					(required
						(p-assign (ident "x"))))))
		(e-nominal (nominal "Distance")
			(e-record
				(fields
					(field (name "x")
						(e-num (value "10")))))))
	(s-nominal-decl
		(ty-header (name "Distance"))
		(ty-record
			(field (field "x")
				(ty-lookup (name "U64") (builtin))))))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "Distance -> U64")))
	(type_decls
		(nominal (type "Distance")
			(ty-header (name "Distance"))))
	(expressions
		(expr (type "Distance -> U64"))
		(expr (type "Distance"))))
~~~
