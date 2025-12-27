package blanche

import "core:container/lru"
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
