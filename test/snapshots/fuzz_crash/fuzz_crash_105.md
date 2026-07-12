# META
~~~ini
description=parser crash: formatting not stable in formatter round-trip
type=file
~~~
# SOURCE
~~~roc

A:a	where[a.a:(X)->r,a.a:r]B:b	where[b.b:r]C:e->[]h={{()}}
~~~
# EXPECTED
panic: Formatting not stable
# PROBLEMS

Formatting panics in `moduleFmtsStable` when formatting this source.

A leading newline plus tab-separated where-constraints triggers an unstable pretty-printer output:

expected:
`A : a where [a.a : (X`
found:
`A : a`
