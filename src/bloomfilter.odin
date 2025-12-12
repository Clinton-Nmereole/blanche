package blanche

import "core:encoding/endian"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:os"
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

save_filter_to_file :: proc(filter: ^BLOOMFILTER, filename: string) {

	file, err := os.open(filename, os.O_RDWR | os.O_TRUNC | os.O_CREATE, 0o644)
	if err != os.ERROR_NONE {
		fmt.println("FAILED to save filter to file")
	}

	// Create header to save values of m and k
	header: [16]byte
	endian.put_u64(header[0:8], endian.Byte_Order.Little, u64(filter.m))
	endian.put_u64(header[8:], endian.Byte_Order.Little, u64(filter.k))

	// Write header to file
	_, err1 := os.write(file, header[:])
	if err1 != os.ERROR_NONE {
		fmt.println("FAILED to save filter to file")
	}

	// Write the entire array to the file
	os.write(file, filter.bitarray[:])

	// Flush to ensure write and then close file
	os.flush(file)
	os.close(file)

}

load_filter_from_file :: proc(filename: string) -> ^BLOOMFILTER {
	// make new filter
	filter := new(BLOOMFILTER)


	// Read Header from file
	file, err := os.open(filename, os.O_RDONLY, 0o644)
	defer os.close(file)
	if err != os.ERROR_NONE {
		fmt.println("FAILED to read file: ", filename)
	}

	// Check if the file is corrupted
	file_size, _ := os.file_size(file)

	if file_size < 8 {
		fmt.printf("The file %s is corrupted and could not be read", filename)
	}


	header: [16]byte
	os.read(file, header[0:8])
	load_m, err1 := endian.get_u64(header[0:8], endian.Byte_Order.Little)
	if !err1 {
		fmt.println("FAILED to read file: ", filename)
	}
	os.read(file, header[8:])
	load_k, err2 := endian.get_u64(header[8:], endian.Byte_Order.Little)
	if !err2 {
		fmt.println("FAILED to read file: ", filename)
	}

	filter.m = int(load_m)
	filter.k = int(load_k)

	//make bit array in filter
	filter.bitarray = make([dynamic]byte, (filter.m + 7) / 8)

	os.read(file, filter.bitarray[:])
	return filter

}
