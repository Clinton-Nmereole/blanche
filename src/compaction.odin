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
	valid:         bool,

	// Block State 
	block_buffer:  []byte, // Holds the current 4KB block of data
	block_cursor:  int, // Where are we inside this buffer?

	// rest
	curr_position: i64,
	end_position:  i64,
	key:           []byte,
	value:         []byte,
	is_tombstone:  bool,
}

load_next_block :: proc(it: ^SSTableIterator) -> bool {

	// Check if we are at the end of the file
	if it.curr_position >= it.end_position {
		it.valid = false
		return false
	}

	// Read block length
	block_len_buf: [8]byte
	os.read(it.file, block_len_buf[:])
	block_size, _ := endian.get_u64(block_len_buf[:], .Little)
	it.curr_position += 8


	//Allocate Buffer & Read Data
	if it.block_buffer != nil {
		delete(it.block_buffer)
	}
	it.block_buffer = make([]byte, block_size)
	os.read(it.file, it.block_buffer)
	it.curr_position += i64(block_size)

	// Read checksum
	checksum_buf: [4]byte
	os.read(it.file, checksum_buf[:])
	it.curr_position += 4
	//os.seek(it.file, 4, os.SEEK_CUR)

	//  Reset Cursor
	it.block_cursor = 0
	return true

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

	// Check if we are at the end of the current block
	if it.block_cursor == len(it.block_buffer) || it.block_buffer == nil {
		not_end := load_next_block(it)

		// if load_next_block() returns false then we have read the entire file
		if !not_end {
			return
		}

	}

	// Clean the old key and old value
	if it.key != nil {delete(it.key)}
	if it.value != nil {delete(it.value)}


	// Read the key length
	klen_buf := it.block_buffer[it.block_cursor:it.block_cursor + 8]
	//os.read(it.file, klen_buf[:])
	klen, _ := endian.get_u64(klen_buf, .Little)
	it.block_cursor += 8

	// Read the key
	it.key = make([]byte, klen)
	copy(it.key, it.block_buffer[it.block_cursor:it.block_cursor + int(klen)])
	//os.read(it.file, it.key)
	it.block_cursor += int(klen)

	// Read the value length
	vlen_buf := it.block_buffer[it.block_cursor:it.block_cursor + 8]
	//os.read(it.file, vlen_buf[:])
	vlen, _ := endian.get_u64(vlen_buf, .Little)
	it.block_cursor += 8

	// Read the value
	if u64(vlen) == TOMBSTONE {
		it.value = nil
		it.is_tombstone = true
		//os.seek(it.file, 0, os.SEEK_CUR)
		//it.curr_position += i64(vlen)

	} else {
		it.value = make([]byte, vlen)
		it.is_tombstone = false
		//os.read(it.file, it.value)
		copy(it.value, it.block_buffer[it.block_cursor:it.block_cursor + int(vlen)])
		it.block_cursor += int(vlen)

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

		// Check the if level 0 has files more than 15 and compact them
		// Set the max size for running compaction at level 1
		threshold_compact_size := 10 * MB
		need_compaction := false
		sync.mutex_lock(&db.mutex)
		if len(db.levels[0]) > 4 {
			need_compaction = true
		}
		sync.mutex_unlock(&db.mutex)

		if need_compaction {
			compact_level_0(db)
		}

		// loop through the levels
		for i := 1; i < len(db.levels) - 1; i += 1 {
			// for every level, check the total size
			level_size: i64 = 0
			sync.mutex_lock(&db.mutex)
			for file in db.levels[i] {
				level_size += file.meta.filesize
			}
			sync.mutex_unlock(&db.mutex)
			if int(level_size) >= threshold_compact_size {
				compact_level_n(db, i)
			}
			threshold_compact_size *= 10

		}

	}

}

compact_level_0 :: proc(db: ^DB) {
	// 1. Lock the database (Thread Safety is key!)
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)

	// 2. Do we even have work to do?
	if len(db.levels[0]) == 0 {
		return // Nothing to compact
	}

	// 3. Pick the victim (Level 0 file)
	// usually the first one in the list
	l0_file := db.levels[0][0]

	// 4. Find the overlapping files in Level 1
	// Use your new helper function: get_overlapping_inputs
	// ...
	overlaps := get_overlapping_inputs(l0_file, db.levels[1])

	// 5. Prepare the list for compaction
	// Remember: [Level 0 File] followed by [Level 1 Files]
	compaction_list := make([dynamic]SSTableHandle)
	append(&compaction_list, l0_file)
	// append the overlaps...
	for overlap in overlaps {
		append(&compaction_list, overlap)
	}
	fmt.printf("Compacting L0: %s with %d L1 files...\n", l0_file.filename, len(overlaps))

	// 6. Run the heavy lifting (The Compaction)
	// We unlock during the heavy I/O so readers aren't blocked!
	sync.mutex_unlock(&db.mutex)
	new_handle := db_compact(compaction_list, db.data_directory)
	sync.mutex_lock(&db.mutex)

	// 7. Update the Levels (The Atomic Swap)
	// A. Remove l0_file from Level 0
	// B. Remove overlaps from Level 1
	// C. Add new_handle to Level 1
	ordered_remove(&db.levels[0], 0)

	new_level_1 := make([dynamic]SSTableHandle)
	for item in db.levels[1] {
		is_overlapping := false
		for overlap in overlaps {
			if item.filename == overlap.filename {
				is_overlapping = true
				break
			}
		}
		if !is_overlapping {
			append(&new_level_1, item)
		}
	}

	// add the compacted file to new_level_1
	append(&new_level_1, new_handle)
	slice.sort_by(new_level_1[:], proc(a, b: SSTableHandle) -> bool {
		return string(a.meta.firstkey) < string(b.meta.firstkey)
	})
	db.levels[1] = new_level_1
	manifest_save(db)


}

compact_level_n :: proc(db: ^DB, level_idx: int) {
	// 1. Lock the database (Thread Safety is key!)
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)

	// 2. Do we even have work to do?
	if len(db.levels[level_idx]) == 0 {
		return // Nothing to compact
	}

	// 1. Target Level is level_idx + 1
	next_level_idx := level_idx + 1
	// 2. Pick a "victim" file from db.levels[level_idx]
	// (For now, just picking the first one [0] is a fine strategy)
	target_file := db.levels[level_idx][0]

	// 3. Find overlaps in db.levels[next_level_idx]
	overlaps := get_overlapping_inputs(target_file, db.levels[next_level_idx])

	// 4. Compact and Update...
	compaction_list := make([dynamic]SSTableHandle)
	append(&compaction_list, target_file)
	// append the overlaps...
	for overlap in overlaps {
		append(&compaction_list, overlap)
	}
	fmt.printf("Compacting L0: %s with %d L1 files...\n", target_file.filename, len(overlaps))

	// 5. Run the heavy lifting (The Compaction)
	// We unlock during the heavy I/O so readers aren't blocked!
	sync.mutex_unlock(&db.mutex)
	new_handle := db_compact(compaction_list, db.data_directory)
	sync.mutex_lock(&db.mutex)

	// 6. Update the Levels (The Atomic Swap)
	// A. Remove l0_file from Level n
	// B. Remove overlaps from Level n + 1
	// C. Add new_handle to Level n + 1
	ordered_remove(&db.levels[level_idx], 0)

	new_level_n_plus := make([dynamic]SSTableHandle)

	for item in db.levels[next_level_idx] {
		is_overlapping := false
		for overlap in overlaps {
			if item.filename == overlap.filename {
				is_overlapping = true
				break
			}
		}
		if !is_overlapping {
			append(&new_level_n_plus, item)
		}
	}

	// add the compacted file to new_level_n + 1
	append(&new_level_n_plus, new_handle)
	slice.sort_by(new_level_n_plus[:], proc(a, b: SSTableHandle) -> bool {
		return string(a.meta.firstkey) < string(b.meta.firstkey)
	})
	db.levels[next_level_idx] = new_level_n_plus
	manifest_save(db)


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
		it := sstable_iterator_init(ssthandle.filename)
		if it.valid {
			append(&iterators, it)
		}

	}

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
	first_key: []byte = nil
	last_key: []byte = nil


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

		// B. Pick the Winner & Advance Duplicates

		found_winner := false
		for it in iterators { 	//loop through all the iterators

			//update the total_size_file variable by adding the file_size of the iterators/files
			if it.valid && compare_keys(it.key, min_key) == 0 { 	// if they are valid and have the smallest key

				if !found_winner { 	// Check if we have found the winner, if not, feed it to the builder.
					/*
					if it.is_tombstone {
						sstable_iterator_next(it)
						found_winner = true
						continue
					}
                    */
					builder_add(builder, it.key, it.value) // iterators is sorted, so the first it which is a winner is the most recent

					// Always update the last_key (copy it)
					if last_key != nil {delete(last_key)}
					last_key = slice.clone(it.key)

					if first_key == nil {first_key = slice.clone(it.key)}

					found_winner = true
					add(filter, it.key)


				} else {
					// Duplicate found - skip it
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


	info_file, info_err := os.stat(new_filename)

	if info_err == os.ERROR_NONE {

		result.meta.filesize = info_file.size
		os.file_info_delete(info_file)

	}


	// Clear the old files from out db
	//clear(&db.sst_files)

	// Append the new file
	//append(&db.sst_files, SSTableHandle{filename = new_filename, filter = filter})

	// Success Message
	fmt.printf("Compaction Complete. Merged into: %s\n", new_filename)
	result.meta.firstkey = first_key
	result.meta.lastkey = last_key

	return result


}
