IterEnumerateFind :: [].{}

# find_first: hit and miss
expect Iter.find_first(List.iter([1, 4, 9]), |n| n > 3) == Ok(4)
expect Iter.find_first(List.iter([1, 2]), |n| n > 3) == Err(NotFound)
expect Iter.find_first(List.iter([]), |n| n > 3) == Err(NotFound)

# find_first through a Skip-producing adapter (keep_if)
expect Iter.find_first(Iter.keep_if(List.iter([1, 2, 3, 4]), |n| n % 2 == 0), |n| n > 2) == Ok(4)

# find_first_index: basic
expect Iter.find_first_index(List.iter([1, 4, 9]), |n| n > 3) == Ok(1)
expect Iter.find_first_index(List.iter([1, 2]), |n| n > 3) == Err(NotFound)

# find_first_index counts yielded items: keep_if([10,11,12,13], odd) yields 11, 13
expect Iter.find_first_index(Iter.keep_if(List.iter([10, 11, 12, 13]), |n| n % 2 == 1), |n| n > 11) == Ok(1)

# enumerate: basic
expect Iter.fold(Iter.enumerate(List.iter(["a", "b"])), [], |acc, pair| acc.append(pair)) == [(0, "a"), (1, "b")]

# enumerate of an empty iterator
expect Iter.fold(Iter.enumerate(List.iter([])), 0, |acc, _pair| acc + 1) == 0

# enumerate positions follow filtering: keep_if yields 20, 40 -> positions 0, 1
expect Iter.fold(Iter.enumerate(Iter.keep_if(List.iter([10, 20, 30, 40]), |n| n % 20 == 0)), [], |acc, pair| acc.append(pair)) == [(0, 20), (1, 40)]

# enumerate composes with take_first
expect Iter.fold(Iter.take_first(Iter.enumerate(List.iter([7, 8, 9])), 2), [], |acc, pair| acc.append(pair)) == [(0, 7), (1, 8)]

# stack sanity: a miss over a 10k-item iterator
expect Iter.find_first(List.iter(List.repeat(0, 10000)), |n| n > 0) == Err(NotFound)
