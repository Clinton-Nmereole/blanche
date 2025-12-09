package blanche

import "core:fmt"
import "core:hash"
import "core:math"
import "core:math/rand"
import "core:strings"

BLOOMFILTER :: struct {
	bitarray: [dynamic]byte,
	m:        int, // This is the optimal size of the bloom filter
	k:        int, // this is the number of hashes we perform on an input
}

// construct bloom filter
bloomfilter_init :: proc(n: int, p: f64) -> ^BLOOMFILTER {

	filter := new(BLOOMFILTER)
	filter.m = int(-(f64(n) * math.ln(p)) / math.pow((math.ln(f64(2))), 2))
	filter.k = int((f64(filter.m) / f64(n)) * math.ln(f64(2)))
	filter.bitarray = make([dynamic]byte, (filter.m + 7) / 8)

	return filter

}

add :: proc(filter: ^BLOOMFILTER, data: []byte) {
	h1 := hash.murmur64a(data)
	h2 := hash.fnv64a(data)
	// first we loop for the number of hashes in the filter

	for i := 0; i < filter.k; i += 1 {
		combined_hash := (h1 + (u64(i) * h2)) % u64(filter.m)
		byte_index := combined_hash / 8
		bit_index := combined_hash % 8
		mask := byte(1) << bit_index
		filter.bitarray[byte_index] |= mask
	}

}

contains :: proc(filter: ^BLOOMFILTER, data: []byte) -> bool {

	h1 := hash.murmur64a(data)
	h2 := hash.fnv64a(data)

	for i := 0; i < filter.k; i += 1 {

		combined_hash := (h1 + (u64(i) * h2)) % u64(filter.m)
		byte_index := combined_hash / 8
		bit_index := combined_hash % 8

		if filter.bitarray[byte_index] == 0 { 	// All the bits in that byte has not been changed, so we know already the search is not in the database
			return false
		}
		mask := byte(1) << bit_index // this is our mask
		// we can check if it has the same 1 value at the bit index by performing a logical AND
		is_set := filter.bitarray[byte_index] & mask

		if is_set != mask {
			return false
		}


	}

	return true

}
