package blanche

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:time"

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

	sstable_iterator_next(it)

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
	//if it.key != nil {delete(it.key)}
	//if it.value != nil {delete(it.value)}
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
		fmt.printf("Attempting to open iterator for: %s\n", filename) // <--- DEBUG 1
		it := sstable_iterator_init(filename)
		if it.valid {
			fmt.println(" -> Success: Iterator Valid.") // <--- DEBUG 2
			append(&iterators, it)
		} else {
			fmt.println(" -> FAILURE: Iterator Invalid!") // <--- DEBUG 3
		}

	}
	fmt.printf("Total Active Iterators: %d\n", len(iterators)) // <--- DEBUG 4

	if len(iterators) == 0 {
		fmt.println("EXITING: No valid iterators found.")
		return
	}

	// We are going to make a file which is what we will write to, we will also open this in the data folder
	temp_filename := fmt.tprintf("%s/compacted.tmp", db.data_directory)
	builder := builder_init(temp_filename)
	if builder == nil {return} 	// Failed to create file

	// Merge Logic 

	//find the minimum key
	for {
		best_key_ref: []byte = nil
		for it in iterators {
			if it.valid {
				if best_key_ref == nil || compare_keys(it.key, best_key_ref) < 0 {
					best_key_ref = it.key
				}
			}
		}

		if best_key_ref == nil {break}

		min_key := make([]byte, len(best_key_ref))
		copy(min_key, best_key_ref)
		defer delete(min_key) // Clean up at the end of this loop iteration
		// DEBUG 1: Print who the current "Min Key" is
		fmt.printf("Loop: Min Key is '%s'\n", string(min_key))

		// B. Pick the Winner & Advance Duplicates

		found_winner := false

		for it in iterators { 	//loop through all the iterators 
			if it.valid && compare_keys(it.key, min_key) == 0 { 	// if they are valid and have the smallest key

				if !found_winner { 	// Check if we have found the winner, if not, feed it to the builder.
					// DEBUG 2: Print who won
					fmt.printf(
						" -> Winner Found! Value: '%s' (Writing to builder)\n",
						string(it.value),
					)
					builder_add(builder, it.key, it.value) // iterators is sorted, so the first it which is a winner is the most recent
					found_winner = true


				} else {
					// DEBUG 3: Print who got skipped
					fmt.printf(" -> Duplicate Skipped! Value: '%s'\n", string(it.value))
				}

				sstable_iterator_next(it) // Move to the next item on all iterators that have the winner value


			}
		}
	}

	// Finish builder
	// Write Index and Footer and then close the file
	builder_finish(builder)

	// Now since we have a new compacted file, we get rid of all the other files
	for it in iterators {
		sstable_iterator_close(it)
	}

	for filename in db.sst_files {
		os.remove(filename)
	}

	//Rename the Temp File
	// We give it a new timestamp name so it looks like a normal SSTable
	new_timestamp := time.to_unix_nanoseconds(time.now())
	new_filename := fmt.tprintf("%s/%d.sst", db.data_directory, new_timestamp)

	os.rename(temp_filename, new_filename)

	// Clear the old files from out db
	clear(&db.sst_files)

	// Append the new file
	append(&db.sst_files, new_filename)

	// Success Message
	fmt.printf("Compaction Complete. Merged into: %s\n", new_filename)


}
