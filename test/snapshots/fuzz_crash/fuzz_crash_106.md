# META
~~~ini
description=parser crash: formatter output no longer parses after reformat
type=file
source_escapes=true
~~~
# SOURCE
~~~roc
a=0O0\r.0
~~~
# EXPECTED
panic: Parsing of formatter output failed
# PROBLEMS

Formatting output from this input parses to a different token sequence than the parser input,
and second parser pass in `moduleFmtsStable` panics.
