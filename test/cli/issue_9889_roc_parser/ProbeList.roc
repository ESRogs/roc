main! = |_args| Ok({})

largest : List(List(U64)) -> U64
largest = |numbers|
	numbers
		.map(List.sum)
		.sort_with(|a, b| if a < b GT else if b > a LT else EQ)
		.first()
		?? 0

expect largest([[1000, 2000, 3000], [4000], [5000, 6000]]) == 11_000
