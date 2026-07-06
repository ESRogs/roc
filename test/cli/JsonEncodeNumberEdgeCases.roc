JsonEncodeNumberEdgeCases :: [].{}

f32_parses_as : Str, F32 -> Bool
f32_parses_as = |json, expected| {
	result : Try(F32, Json)
	result = Json.parse(json)
	F32.is_float_eq(result.ok_or(0.0), expected)
}

f64_parses_as : Str, F64 -> Bool
f64_parses_as = |json, expected| {
	result : Try(F64, Json)
	result = Json.parse(json)
	F64.is_float_eq(result.ok_or(0.0), expected)
}

expect {
	result : Try(Dec, Json)
	result = Json.parse("1.25e2")
	result == Ok(125)
}

expect {
	result : Try(Dec, Json)
	result = Json.parse("0.01e21")
	result == Ok(10000000000000000000)
}

expect {
	value : Dec
	value = 12.5

	encoded = Json.to_str(value)

	parsed : Try(Dec, Json)
	parsed = Json.parse(encoded)
	parsed == Ok(value)
}

expect {
	result : Try(Dec, Json)
	result = Json.parse("1e999999")
	result == Err(Json.invalid_json)
}

expect f32_parses_as("1.5", 1.5)

expect {
	result : Try(F32, Json)
	result = Json.parse("1e999999")
	result == Err(Json.invalid_json)
}

expect f64_parses_as("-2.25", -2.25)

expect {
	too_large : Try(F64, Json)
	too_large = Json.parse("1e999999")

	not_json : Try(F64, Json)
	not_json = Json.parse("NaN")

	too_large == Err(Json.invalid_json) and not_json == Err(Json.invalid_json)
}
