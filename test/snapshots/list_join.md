# META
~~~ini
description=List.join
type=repl
~~~
# SOURCE
~~~roc
» List.join([[1, 2], [3], [], [4, 5]])
» List.join([["a", "b"], ["c"]])
» List.join([[], [], []])
~~~
# OUTPUT
[1.0, 2.0, 3.0, 4.0, 5.0]
---
["a", "b", "c"]
---
[]
# PROBLEMS
NIL
