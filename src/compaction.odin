package blanche

import "core:encoding/endian"
import "core:fmt"
import "core:os"

// Well basically what the compaction phase does is merge old sst files into a new "master" sst file
// We then delete all the other old files
// This way we save disk space
// To do this we will create an iterator struct that iterates through keys in the sst file

SSTableIterator :: struct {
	file:          os.Handle,
	file_size:     i64,
	curr_position: i64,
	end_position:  i64,
	valid:         bool,
	key:           []byte,
	value:         []byte,
}

sstable_iterator_init :: proc(filename: string) -> ^SSTableIterator {
	it := new(SSTableIterator)
	file, err := os.open(filename, os.O_RDONLY)

	it.file = file

	if err != os.ERROR_NONE {
		it.valid = false
		return it
	}

	it.curr_position = 0

	// get the file size
	it.file_size, _ = os.file_size(file)

	// go to the end of the file and then 8 bytes backwards to read the footer
	os.seek(file, -8, os.SEEK_END)

	// read the footer
	footer_buf: [8]byte
	os.read(file, footer_buf[:])
	footer, _ := endian.get_u64(footer_buf[:], endian.Byte_Order.Little)

	//set the end_position
	it.end_position = i64(footer)

	// Prime the pump: Read the first entry immediately
	os.seek(file, 0, os.SEEK_SET)

	//TODO: Write sstable_iterator_next function
	// sstable_iterator_next(it)

	return it

}

sstable_iterator_next :: proc(it: ^SSTableIterator) {

	// so what do we want here, we want to set the key and value
	// start from curr_position, and we need to read [key length] [key] [value length] [value]
	// DO NOT read the entire file, we then update the curr_position
	// the file is open from initializing the iterator

	// Clean the old key and old value
	if it.key != nil {delete(it.key)}
	if it.value != nil {delete(it.value)}

	// Check if we hit the end of the data block
	if it.curr_position >= it.end_position {
		it.valid = false
		return
	}

	// Read the key length
	klen_buf: [4]byte
	os.read(it.file, klen_buf[:])
	klen, _ := endian.get_u32(klen_buf[:], endian.Byte_Order.Little)
	it.curr_position += 4

	// Read the key
	it.key = make([]byte, klen)
	os.read(it.file, it.key)
	it.curr_position += i64(klen)

	// Read the value length
	vlen_buf: [4]byte
	os.read(it.file, vlen_buf[:])
	vlen, _ := endian.get_u32(vlen_buf[:], endian.Byte_Order.Little)
	it.curr_position += 4

	// Read the value
	it.value = make([]byte, vlen)
	os.read(it.file, it.value)
	it.curr_position += i64(vlen)

	it.valid = true

}

// 3. Cleanup
sstable_iterator_close :: proc(it: ^SSTableIterator) {
	os.close(it.file)
	if it.key != nil {delete(it.key)}
	if it.value != nil {delete(it.value)}
	free(it)
}

db_compact :: proc(db: ^DB) {
	fmt.println("==== STARTED COMPACTION ====")

	// Make iterators for all the files in the db
	iterators := make([dynamic]^SSTableIterator)
	defer delete(iterators)

	// loop through sstable_files and make iterators for each
	// since sstable_files is sorted, iterators[0] will always be the most recent file

	for filename in db.sst_files {
		it := sstable_iterator_init(filename)
		if it.valid {
			append(&iterators, it)
		}

	}

	// We are going to make a file which is what we will write to, we will also open this in the data folder
	temp_filename := fmt.tprintf("%s/compacted.tmp", db.data_directory)
	builder := builder_init(temp_filename)
	if builder == nil {return} 	// Failed to create file

	// Merge Logic 

	//find the minimum key
	for {
		min_key: []byte = nil
		for it in iterators {
			if it.valid {
				if min_key == nil || compare_keys(it.key, min_key) < 0 {
					min_key = it.key
				}
			}
		}

		if min_key == nil {break}

		// B. Pick the Winner & Advance Duplicates
	}


}
