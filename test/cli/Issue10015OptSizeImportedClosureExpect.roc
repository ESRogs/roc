# repro for https://github.com/roc-lang/roc/issues/10015
app [main!] {
    pf: platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/0.9/8GdFEvQYS3TeAZxKvTzCLVdQiomweGtXcdZkXNDEeABq.tar.zst",
    random: "https://github.com/kili-ilo/roc-random/releases/download/0.6.0/4mHqd7aiQ1hYkoso9C8JRfnx3GuwcwoDqv8EdqAsLbfN.tar.zst",
}

import random.Random

main! = |_args| {
    Ok({})
}

expect
    (|fn| fn(Random.seed(0)))(|state| True)
