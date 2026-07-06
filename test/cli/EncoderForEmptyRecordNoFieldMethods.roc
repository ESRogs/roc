EncoderForEmptyRecordNoFieldMethods :: [].{}

Format := [Default].{
	begin_record : U64 -> Try(U64, [])
	begin_record = |state| Ok(state + 1)

	end_record : U64 -> Try(U64, [])
	end_record = |state| Ok(state + 2)
}

encode : value -> Try(U64, [])
	where [
		value.encoder_for : Format -> (value, U64 -> Try(U64, [])),
	]
encode = |value| {
	Shape : value
	encode_value = Shape.encoder_for(Format.Default)
	encode_value(value, 0)
}

expect encode({}) == Ok(3)
