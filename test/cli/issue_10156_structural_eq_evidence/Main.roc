# Regression fixture for https://github.com/roc-lang/roc/issues/10156. The value
# returned by the generic `Split.split_on` (at `a = U8`) is destructured and
# rebuilt, then compared with `==`. That comparison used to panic in ReleaseSafe
# ("structural equality intrinsic wrapper must lower through checked dispatch
# plans") and miscompile in ReleaseFast.
import Split

Main := [].{
    run = |bytes| {
        { head, tail } = match Split.split_on(bytes, ['\r', '\n']) {
            Ok({ before: b, after: a }) => Ok({ head: b, tail: a })
            Err(_) => Err(NoDelimiter)
        }?
        match Str.from_utf8(head) {
            Ok(text) => Ok({ text, tail })
            Err(cause) => Err(BadText(head, cause))
        }
    }
}

expect Main.run(Str.to_utf8("\r\nbody")) == Ok({ text: "", tail: Str.to_utf8("body") })

# A correct value must also compare unequal to a near miss.
expect Main.run(Str.to_utf8("\r\nbody")) != Ok({ text: "", tail: Str.to_utf8("BODY") })
