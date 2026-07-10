# META
~~~ini
description=fuzz regression: canonicalize type annotation arg resolves to non-rigid
skip=true
type=file
~~~
# SOURCE
~~~roc
C(_,b):()D:C(a,b)E:{b:r}F:e r={(){}}
~~~
