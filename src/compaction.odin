package blanche

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
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
	is_tombstone:  bool,
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
	klen_buf: [8]byte
	os.read(it.file, klen_buf[:])
	klen, _ := endian.get_u64(klen_buf[:], endian.Byte_Order.Little)
	it.curr_position += 8

	// Read the key
	it.key = make([]byte, klen)
	os.read(it.file, it.key)
	it.curr_position += i64(klen)

	// Read the value length
	vlen_buf: [8]byte
	os.read(it.file, vlen_buf[:])
	vlen, _ := endian.get_u64(vlen_buf[:], endian.Byte_Order.Little)
	it.curr_position += 8

	// Read the value
	if u64(vlen) == TOMBSTONE {
		it.value = nil
		it.is_tombstone = true
		os.seek(it.file, i64(vlen), os.SEEK_CUR)
		it.curr_position += i64(vlen)

	} else {
		it.value = make([]byte, vlen)
		it.is_tombstone = false
		os.read(it.file, it.value)
		it.curr_position += i64(vlen)

	}

	it.valid = true

}

// 3. Cleanup
sstable_iterator_close :: proc(it: ^SSTableIterator) {
	os.close(it.file)
	//if it.key != nil {delete(it.key)}
	//if it.value != nil {delete(it.value)}
	free(it)
}

get_overlapping_inputs :: proc(
	target_file: SSTableHandle,
	candidates: [dynamic]SSTableHandle,
) -> [dynamic]SSTableHandle {
	overlaps := make([dynamic]SSTableHandle)

	// Look through candidates (level 1 files) and check if there are overlaps
	for candidate in candidates {
		if compare_keys(target_file.meta.firstkey, candidate.meta.lastkey) <= 0 &&
		   compare_keys(target_file.meta.lastkey, candidate.meta.firstkey) >= 0 {
			append(&overlaps, candidate)
		}

	}

	return overlaps
}


compaction_worker :: proc(db: ^DB) {
	// Always runs in the background
	for {
		time.sleep(1 * time.Second)

		// Check the if len(db.sstable_files) > 5
		sync.mutex_lock(&db.mutex)
		if len(db.levels[0]) > 5 {
			snapshot_files := slice.clone_to_dynamic(db.levels[0][:])
			count := len(snapshot_files)
			sync.mutex_unlock(&db.mutex)
			fmt.println("Compacting...")
			compacted_handle := db_compact(snapshot_files, db.data_directory)
			sync.mutex_lock(&db.mutex)
			db.levels[0] = slice.clone_to_dynamic(db.levels[0][0:len(db.levels[0]) - count])
			append(&db.levels[0], compacted_handle)

		}
		sync.mutex_unlock(&db.mutex)

	}

}

db_compact :: proc(files: [dynamic]SSTableHandle, data_dir: string) -> SSTableHandle {

	//type of result to return 
	result: SSTableHandle


	// variable for the total size of all the .sst files
	total_size_file: i64


	fmt.println("==== STARTED COMPACTION ====")

	// Make iterators for all the files in the db
	iterators := make([dynamic]^SSTableIterator)
	defer delete(iterators)

	// loop through sstable_files and make iterators for each
	// since sstable_files is sorted, iterators[0] will always be the most recent file

	for ssthandle in files {
		fmt.printf("Attempting to open iterator for: %s\n", ssthandle.filename) // <--- DEBUG 1
		it := sstable_iterator_init(ssthandle.filename)
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
		return result
	}

	// Loop through the iterators to get the total_size_file
	for it in iterators {
		total_size_file += it.file_size
	}

	// initialize new bloom filter
	filter := bloomfilter_init(int(total_size_file / 8), 0.01)

	// We are going to make a file which is what we will write to, we will also open this in the data folder
	temp_filename := fmt.tprintf("%s/compacted.tmp", data_dir)
	builder := builder_init(temp_filename)
	if builder == nil {return result} 	// Failed to create file

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

			//update the total_size_file variable by adding the file_size of the iterators/files
			if it.valid && compare_keys(it.key, min_key) == 0 { 	// if they are valid and have the smallest key

				if !found_winner { 	// Check if we have found the winner, if not, feed it to the builder.
					// DEBUG 2: Print who won
					fmt.printf(
						" -> Winner Found! Value: '%s' (Writing to builder)\n",
						string(it.value),
					)
					if it.is_tombstone {
						sstable_iterator_next(it)
						found_winner = true
						continue
					}
					builder_add(builder, it.key, it.value) // iterators is sorted, so the first it which is a winner is the most recent
					found_winner = true
					add(filter, it.key)


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

	for ssthandle in files {
		old_filter_name := fmt.tprintf(
			"%s.filter",
			strings.trim_suffix(ssthandle.filename, ".sst"),
		)
		os.remove(ssthandle.filename)
		os.remove(old_filter_name)
	}

	//Rename the Temp File
	// We give it a new timestamp name so it looks like a normal SSTable
	new_timestamp := time.to_unix_nanoseconds(time.now())
	new_filename := fmt.tprintf("%s/%d.sst", data_dir, new_timestamp)
	filter_filename := fmt.tprintf("%s/%d.filter", data_dir, new_timestamp)


	os.rename(temp_filename, new_filename)
	save_filter_to_file(filter, filter_filename)
	result.filter = filter
	result.filename = new_filename

	// Clear the old files from out db
	//clear(&db.sst_files)

	// Append the new file
	//append(&db.sst_files, SSTableHandle{filename = new_filename, filter = filter})

	// Success Message
	fmt.printf("Compaction Complete. Merged into: %s\n", new_filename)

	return result


}
