app [main!] {
    fx: platform "../platform/main.roc",
    a: "./pkga/main.roc",
}

import fx.Stdout
import a.Alpha

main! = || {
    Stdout.line!(Alpha.greet)
}
