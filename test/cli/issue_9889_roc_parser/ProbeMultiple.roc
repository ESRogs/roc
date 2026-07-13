import Parser
import String

main! = |_args| Ok({})

single_number : Parser(List(U8), U64)
single_number =
	Parser.const(|n| n)
		.keep(String.digits)
		.skip(String.string("\n"))

multiple_numbers : Parser(List(U8), List(U64))
multiple_numbers =
	Parser.const(|ns| ns)
		.keep(single_number.many())
		.skip(String.string("\n"))

expect String.parse_str(multiple_numbers, "1000\n2000\n3000\n\n") == Ok([1000, 2000, 3000])
