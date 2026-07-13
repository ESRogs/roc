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

expect {
	result : Try(List(List(U64)), [ParsingFailure(Str), ParsingIncomplete(Str)])
	result = String.parse_str(multiple_numbers.many(), "1000\n2000\n3000\n\n4000\n\n5000\n6000\n\n")
	result == Ok([[1000, 2000, 3000], [4000], [5000, 6000]])
}
