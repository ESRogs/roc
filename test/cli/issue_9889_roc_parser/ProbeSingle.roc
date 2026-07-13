import Parser
import String

main! = |_args| Ok({})

single_number : Parser(List(U8), U64)
single_number =
	Parser.const(|n| n)
		.keep(String.digits)
		.skip(String.string("\n"))

expect String.parse_str(single_number, "1000\n") == Ok(1000)
