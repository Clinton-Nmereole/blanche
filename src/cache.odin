package blanche

import "core:container/lru"
import "core:encoding/endian"
import "core:fmt"
import "core:os"

CacheKey :: struct {
	filename: string,
	offset:   u64,
}

BlockCache :: struct {
	internal_cache:       lru.Cache(CacheKey, []byte),
	current_memory_usage: int,
	max_memory_usage:     int,
}

//Helper function

read_u64 :: proc(data: []byte, offset: int) -> u64 {
	// 1. Grab the specific 8 bytes we want
	// We expect the data slice to be large enough!
	bytes_to_read := data[offset:offset + 8]

	// 2. Convert them to a number using Little Endian order
	result, _ := endian.get_u64(bytes_to_read, .Little)
	return result
}

read_block :: proc(filename: string, offset: int) -> (block: []byte, success: bool) {
	file, err := os.open(filename)

	if err != os.ERROR_NONE {
		fmt.printf("Failed to open file: %s for caching. \n", filename)
		return nil, false
	}

	os.seek(file, i64(offset), os.SEEK_SET)

	buffer := make([]byte, 4096)

	os.read(file, buffer)

	return buffer, true
}

search_block :: proc(block: []byte, key: []byte) -> (value: []byte, found: bool) {
	cursor := 0
	for cursor + 8 < len(block) {
		key_len := read_u64(block, cursor)
		cursor += 8

		if key_len == 0 {
			return nil, false // End of data, key not found
		}

		// 2. Check Key Match
		// (We compare the bytes at the current cursor)
		if string(block[cursor:cursor + int(key_len)]) == string(key) {
			cursor += int(key_len)
			val_len := read_u64(block, cursor)
			cursor += 8
			if val_len == TOMBSTONE {
				return nil, true
			}
			return block[cursor:cursor + int(val_len)], true // Found it!
		}
		// 3. No Match - Hop over this record
		cursor += int(key_len) // Skip Key
		val_len := read_u64(block, cursor) // Read Value Length
		cursor += 8
		cursor += int(val_len) // Skip Value

	}
	return nil, false
}
