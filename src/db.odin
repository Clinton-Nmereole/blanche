package blanche

import "core:container/lru"
import "core:encoding/endian"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"


SSTableHandle :: struct {
	filename: string,
	filter:   ^BLOOMFILTER,
	meta:     FileMetaData,
}

DB :: struct {
	memtable:       ^Memtable,
	wal:            ^WAL,
	data_directory: string,
	manifest:       ^Manifest,
	levels:         [dynamic][dynamic]SSTableHandle,
	mutex:          sync.Mutex,
	block_cache:    ^BlockCache,
}

DBIterator :: struct {
	mem_iter:  ^MemtableIterator,
	sst_iters: [dynamic]^SSTableIterator,
	// The "Public" fields for the user
	valid:     bool,
	key:       []byte,
	value:     []byte,
	end_key:   []byte,
}

db_iterator_init :: proc(db: ^DB, start_key, end_key: []byte) -> ^DBIterator {

	// create new db iterator struct
	db_iter := new(DBIterator)

	// initialize memtable iterator and set it to DBIterator's mem_iter field
	db_iter.mem_iter = memtable_iterator_init(db.memtable)

	// initialize an SSTableIterator for every single file in the db (loop through levels) 
	//or maybe we can only loop through files in a range if the range is passed.

	// So go through each level
	for level in db.levels {

		// for each file in the level we check if it is the correct range. We are not going to bother making
		// iterators for files that are not the correct range requested by the user.
		for file in level {
			if compare_keys(start_key, file.meta.firstkey) <= 0 &&
			   compare_keys(file.meta.lastkey, end_key) >= 0 {
				sstable_iter := sstable_iterator_init(file.filename)
				append(&db_iter.sst_iters, sstable_iter)
			} else {
				continue
			}
		}

	}

	// Set the stop value. We want it to persist, so a clone should be the best way
	db_iter.end_key = slice.clone(end_key)


	if db_iter.mem_iter != nil || len(db_iter.sst_iters) > 0 {
		db_iter.valid = true
	} else {
		db_iter.valid = false
	}
	db_iterator_next(db_iter) // prime the iterator to have the first key-value pair

	return db_iter
}

db_iterator_next :: proc(db_iter: ^DBIterator) {

	for {
		// So we are going to first free old memory from the previous call
		if db_iter.key != nil {
			delete(db_iter.key)
			db_iter.key = nil
		}
		if db_iter.value != nil {
			delete(db_iter.value)
			db_iter.value = nil
		}

		// next we are going to find the minimum key. To do this we will look at all iterators to find the min_key
		// since the memtable is sorted, we know that the minimum key from a memtable is the first key

		// Find min_key
		min_key: []byte
		//We can start by setting the min_key equal to the current value in the memtable (smallest key in memtable)
		// Then we can check if it is still the smallest key among the keys in files
		if db_iter.mem_iter.node != nil {
			min_key = db_iter.mem_iter.node.key
		} else {min_key = nil}
		for sstable_it in db_iter.sst_iters {
			if sstable_it.valid {
				if min_key == nil || compare_keys(min_key, sstable_it.key) > 0 {
					min_key = sstable_it.key
				}
			}
		}

		// if the min_key is nil after the previous step that means the current memtable key is nil. (We reached the end of the memtable)
		// it also means that we reached the end of all our sst files.
		if min_key == nil || compare_keys(min_key, db_iter.end_key) > 0 {
			db_iter.valid = false
			fmt.println("We have reached the end or have run out of valid iterators")
			return
		}

		// Pick winner
		found_winner: bool = false

		// If the min_key is the same as the key in the memtable then we set the value to that since it is the most recent.
		if db_iter.mem_iter.node != nil && compare_keys(min_key, db_iter.mem_iter.node.key) == 0 {
			found_winner = true
			if db_iter.mem_iter.node.value != nil {
				db_iter.key = slice.clone(db_iter.mem_iter.node.key)
				db_iter.value = slice.clone(db_iter.mem_iter.node.value)


			}
			// move iterator forward
			db_iter.mem_iter.node = db_iter.mem_iter.node.next[0] // looks long but basically go to the mem_iter, get the node, set it to the next key in level 0
		}
		// then we loop through files and search (even if the min_key was in memtable) we need to move all iterators with that key forward
		for it in db_iter.sst_iters {
			if it.valid && compare_keys(it.key, min_key) == 0 { 	// if the iterator is valid and is the same as the min_key
				if !found_winner {
					// first we handle the tombstone condition.
					if it.is_tombstone {
						// if the key is found but has been deleted we do not want to return it to the user we do nothing and push 
						// the iterator forward. WE DO NOT SET VALUE.
						found_winner = true
						sstable_iterator_next(it)
						continue
					} else { 	// we found the winner and it is not a tombstone
						found_winner = true // we set found winner to true
						db_iter.key = slice.clone(it.key)
						db_iter.value = slice.clone(it.value)


					}
					//we move that iterator forward
					sstable_iterator_next(it)

					//return

				} else {
					// we already have winner from memtable or previous sstable file, we still need to push all
					// sstable iterators with the same key forward
					sstable_iterator_next(it)
				}


			}
		}

		if db_iter.key != nil {
			return
		}

	}


}

db_iterator_close :: proc(db_iter: ^DBIterator) {
	if db_iter.key != nil {delete(db_iter.key)}
	if db_iter.value != nil {delete(db_iter.value)}
	if db_iter.end_key != nil {delete(db_iter.end_key)}
	for iter in db_iter.sst_iters {
		sstable_iterator_close(iter)
	}
	delete(db_iter.sst_iters)
	free(db_iter.mem_iter)
	free(db_iter)

}

// CONSTANT: When do we freeze and flush? (4MB)
MEMTABLE_THRESHOLD :: 4 * MB

// basically initialize the DB, and recover from WAL incase there was a failure
db_open :: proc(dir: string) -> ^DB {

	if !os.is_dir(dir) {
		os.make_directory(dir)
	}

	db := new(DB)
	db.data_directory = dir

	// 1. Initialize the Levels
	// We create a slot for every possible level
	for i := 0; i < MAX_LEVEL; i += 1 {
		lvl := make([dynamic]SSTableHandle)
		append(&db.levels, lvl)
	}

	// 2. Load the Manifest
	manifest_path := fmt.tprintf("%s/manifest", dir)
	if os.exists(manifest_path) {
		// Load existing database state
		fmt.println("Loading existing Manifest...")
		db.manifest = manifest_load(manifest_path)

		// Reconstruct the levels in RAM
		for file_meta in db.manifest.files {
			// Construct the path to the filter
			// e.g., data/123.sst -> data/123.filter
			filter_path := strings.trim_suffix(file_meta.filename, ".sst")
			filter_path = fmt.tprintf("%s.filter", filter_path)

			file_filter: ^BLOOMFILTER
			if os.exists(filter_path) {
				file_filter = load_filter_from_file(filter_path)
			}

			// Create the Handle
			handle := SSTableHandle {
				filename = file_meta.filename,
				filter   = file_filter,
				meta     = file_meta,
			}

			// Place it in the correct level!
			append(&db.levels[file_meta.level], handle)
			slice.sort_by(
				db.levels[0][:],
				proc(a, b: SSTableHandle) -> bool {
					return a.filename > b.filename // Descending (Big number = Newer)
				},
			)
		}

	} else {
		// New Database: Create fresh manifest
		fmt.println("Creating new Manifest...")
		db.manifest = new(Manifest)
		db.manifest.filename = manifest_path
		// db.manifest.files is already a zero-value dynamic array (empty)
	}

	// 3. Initialize Memtable
	db.memtable = memtable_init()

	// 4. Initialize Block Cache
	db.block_cache = new(BlockCache)
	db.block_cache.max_memory_usage = BLOCK_CACHE_SIZE
	lru.init(&db.block_cache.internal_cache, 1024)

	// 5. Initialize WAL
	wal_path := fmt.tprintf("%s/wal.log", dir)
	db.wal, _ = wal_init(wal_path)

	// 6. Recovery
	wal_recover(db.wal, db.memtable)

	return db
}


db_close :: proc(db: ^DB) {
	// Force write to disk
	os.close(db.wal.file)

	//freeing memtable here too
	memtable_clear(db.memtable)
	free(db)
}

db_put :: proc(db: ^DB, key, value: []byte) {
	// Steps:
	// 1. First write to WAL and let the user know if it fails
	// Now we add to the bloom filter before the memtable
	// 2. Write to the memtable.
	// 3. Check if the memtable size is at the threshold, and if it is, then write to file.

	if !wal_append(db.wal, key, value) {
		fmt.println("Failed to append to WAL.")
	}

	//Add the key to the bloomfilter


	memtable_put(db.memtable, key, value)

	if db.memtable.size >= MEMTABLE_THRESHOLD {
		//this is where we flush to sst
		sstable_flush(db)
	}

}

db_get :: proc(db: ^DB, key: []byte) -> ([]byte, bool) {
	//this is the part where the bloom filter works best.
	// Check if the bloom filter does not contain the key

	// First we would like to check if the key is in the memtable
	val_memtable, memtable_found := memtable_get(db.memtable, key)
	if memtable_found {
		return val_memtable, memtable_found
	}

	// Use sstable_find to check the newest .sst file and then check subsequent .sst files after that
	// Loop through all the sorted sst_files in the db since they are sorted in reverse order,
	// we are looking at the newest entries first

	for sstable in db.levels[0] {

		// Use bloom filter to eliminate searching files we know don't contain the key
		// Skip bloom filter check if filter is nil (e.g., files from tests without filters)
		if sstable.filter != nil && !contains(sstable.filter, key) {
			continue
		}

		val, found, is_tombstone := sstable_find(db, sstable.filename, key)
		if found {
			if is_tombstone {
				return nil, false
			} else {
				return val, true
			}
		}

	}
	// Check Level 1 and up
	for i := 1; i < len(db.levels); i += 1 {
		for sstable in db.levels[i] {
			// OPTIMIZATION OPPORTUNITY! ⚡
			// We have sstable.meta.firstkey and sstable.meta.lastkey
			// if the key is not in the range firstkey = lastkey... skip that file and move to the next
			if !(compare_keys(key, sstable.meta.firstkey) >= 0 &&
				   compare_keys(key, sstable.meta.lastkey) <= 0) {
				continue

			} else { 	// the key is in the range
				// we check the bloom filter (skip if nil)
				if sstable.filter != nil && !contains(sstable.filter, key) {
					continue
				}

				// if bloom filter says maybe, then we search the file while being aware of tombstones
				val, found, is_tombstone := sstable_find(db, sstable.filename, key)
				if found {
					if is_tombstone {
						return nil, false
					} else {
						return val, true
					}
				}

			}
		}
	}


	return nil, false


}

// Delete a key by writing a tombstone
db_delete :: proc(db: ^DB, key: []byte) {
	// Use nil value to signal deletion (tombstone)
	memtable_put(db.memtable, key, nil)

	// Write to WAL with empty value (will be read back as nil on recovery)
	empty := []byte{}
	if !wal_append(db.wal, key, empty) {
		fmt.println("Failed to append delete to WAL.")
	}

	// Check if we need to flush
	if db.memtable.size >= MEMTABLE_THRESHOLD {
		sstable_flush(db)
	}
}


db_scan :: proc(db: ^DB, start_key, end_key: []byte) -> ^DBIterator {
	db_iter := db_iterator_init(db, start_key, end_key)
	return db_iter
}


sstable_flush :: proc(db: ^DB) {
	timestamp := time.to_unix_nanoseconds(time.now())
	filename := fmt.tprintf("%s/%d.sst", db.data_directory, timestamp)
	filtername := fmt.tprintf("%s/%d.filter", db.data_directory, timestamp)

	filter := bloomfilter_init(db.memtable.count, 0.01)


	file, open_err := os.open(filename, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o664)

	if open_err != os.ERROR_NONE {
		fmt.printf("!!! ERROR CREATING FILE !!!\n")
		fmt.printf("Target: %s\n", filename)
		fmt.printf("Error: %v\n", open_err)
		return
	}
	defer os.close(file)

	// get the firstkey
	firstkey := slice.clone(db.memtable.head.next[0].key)
	lastkey_node := db.memtable.head.next[0]
	for lastkey_node.next[0] != nil {
		lastkey_node = lastkey_node.next[0]
	}
	lastkey := slice.clone(lastkey_node.key)

	append(
		&db.levels[0],
		SSTableHandle {
			filename = filename,
			filter = filter,
			meta = FileMetaData {
				level = 0,
				filename = filename,
				firstkey = firstkey,
				lastkey = lastkey,
			},
		},
	)

	// sort
	slice.sort_by(db.levels[0][:], proc(a, b: SSTableHandle) -> bool {
		return a.filename > b.filename
	})

	// Write all the keys in the memtable into the filter first
	// We can use this loop to also get the lastkey
	current_node := db.memtable.head.next[0]
	for current_node != nil {
		add(filter, current_node.key)
		current_node = current_node.next[0]
	}


	// 3. WRITE THE DATA (The heavy lifting)
	// We will implement this detailed binary encoding in a moment.
	keys_count := sstable_write_file(file, db.memtable)
	fmt.printf("Flushed SSTable: %s\n", filename)

	// save the filter to file as well

	save_filter_to_file(filter, filtername)

	// 4. CLEANUP (The Reset)
	// A. Wipe the MemTable (Instant clear via Arena)
	memtable_clear(db.memtable)
	// B. Reset the WAL
	// Close old WAL, delete it, open fresh one.
	os.close(db.wal.file)
	os.remove(db.wal.filename)

	// Re-open fresh WAL
	new_wal, ok := wal_init(db.wal.filename)
	if !ok {
		fmt.println("!!! FATAL: Could not create new WAL after flush !!!")

	}
	db.wal = new_wal

}

// How often do we save a shortcut?
// 100 means we only index every 100th key.

// A temporary struct to hold index entries in RAM
IndexEntry :: struct {
	key:    []byte,
	offset: u64, // Where does this key start in the file?
}

// The 3 Blocks of an SSTable File

// Block 1: The Data Block (Sequential)
// What: This is your MemTable dump. You iterate through your Skip List (Level 0) and write every single Key and Value.

// Block 2: The Sparse Index Block (Random Access)
// The Problem: The Data Block is just a stream of bytes. If I want "User:500", I don't know where it starts.
// The Solution: We write a "Cheat Sheet" after the data.
// What it contains: We don't save every key. We save every Nth key (e.g., every 100th key).
// Entry 1: Key="User:100", Offset=0 (Start of file)
//Entry 2: Key="User:200", Offset=4050 (4kb into file)
// Entry 3: Key="User:300", Offset=8200 (8kb into file)

// The Meta/Footer Block (The Bootstrap)
// The Problem: When you open the file later, how does the program know where the Index Block starts? It's at the end, but at what byte?
// The Solution: The very last 8 bytes of the file are a fixed integer (u64).
// What it contains: [Offset of Index Block]

// Returns the number of keys written
sstable_write_file :: proc(file: os.Handle, mt: ^Memtable) -> int {

	counter := 0 // This the value we are returning (number of keys)

	current_offset: u64 = 0 // This tracks how many bytes we have written

	// we need a dynamic array to hold our index entries (the IndexEntry struct)
	index_list := make([dynamic]IndexEntry)
	defer delete(index_list) // Clean up RAM after function run

	// <-----BLOCK 1----->
	//we want to write from the lowest level memtable (which is a skip list) until there are no more nodes left to write from
	current_node := mt.head.next[0]

	for current_node != nil {
		if counter % 100 == 0 { 	// add to the index list every hundred key-value pairs
			// Make a copy of key, because key might get freed or disappear
			key_copy := make([]byte, len(current_node.key))
			copy(key_copy, current_node.key)
			append(&index_list, IndexEntry{key = key_copy, offset = current_offset})


		}

		// Ok, now we actually write to sst file in the format [key length] [key] [value length] [value]
		// Write key length
		key_length_bytes: [8]byte
		endian.put_u64(key_length_bytes[:], endian.Byte_Order.Little, u64(len(current_node.key)))
		os.write(file, key_length_bytes[:])
		current_offset += 8

		// Write actual key
		os.write(file, current_node.key)
		current_offset += u64(len(current_node.key))


		// Write value length (use TOMBSTONE for nil values)
		value_length_bytes: [8]byte
		if current_node.value == nil {
			// Write TOMBSTONE marker for deleted keys
			endian.put_u64(value_length_bytes[:], endian.Byte_Order.Little, TOMBSTONE)
			os.write(file, value_length_bytes[:])
			current_offset += 8
			// Don't write any value data for tombstones
		} else {
			endian.put_u64(
				value_length_bytes[:],
				endian.Byte_Order.Little,
				u64(len(current_node.value)),
			)
			os.write(file, value_length_bytes[:])
			current_offset += 8

			// Write actual value
			os.write(file, current_node.value)
			current_offset += u64(len(current_node.value))
		}

		current_node = current_node.next[0]
		counter += 1


	}

	// <-----BLOCK 2----->

	// Now that we have finished writing from memtable to the file, we need to
	// We need to write from the index list.
	// We simply write it in the form [key_length] [key] [offset]

	// Save the spot where the Index starts. We need this for the footer.
	index_start_offset := current_offset

	for entry in index_list {

		// write key length
		key_len: [8]byte
		endian.put_u64(key_len[:], endian.Byte_Order.Little, u64(len(entry.key)))
		os.write(file, key_len[:])

		// write key
		os.write(file, entry.key)

		// write offset
		// since it is an integer (u64 specifically), we need to convert it to bytes
		offset_bytes: [8]byte
		endian.put_u64(offset_bytes[:], endian.Byte_Order.Little, u64(entry.offset))
		os.write(file, offset_bytes[:])
		delete(entry.key) //remember that we are making deep copies of key when we initially put it in index_list, this frees that memory.

	}

	// --- BLOCK 3: WRITE THE FOOTER ---
	// The very last thing in the file is the pointer to the Index Block.
	footer: [8]byte
	endian.put_u64(footer[:], endian.Byte_Order.Little, index_start_offset)
	os.write(file, footer[:])

	// Force disk write
	os.flush(file) // Use flush here to be safe since this is a permanent file


	return counter
}

// We need a function that takes a filename and a key, and returns the value (or not found)

sstable_find :: proc(
	db: ^DB,
	filename: string,
	key: []byte,
) -> (
	value: []byte,
	is_found: bool,
	is_tombstone: bool,
) {
	// DEBUG TRACE 🕵️‍♂️
	fmt.printf("Checking file: %s for key: %s\n", filename, string(key))

	// First we open the file
	file, err := os.open(filename, os.O_RDONLY)
	if err != os.ERROR_NONE {return nil, false, false}
	defer os.close(file)

	// Check if the file is corrupted
	file_size, _ := os.file_size(file)

	if file_size < 8 {
		fmt.printf("The file %s is corrupted and could not be read", filename)
		return nil, false, false
	}


	// --- STEP 1: READ FOOTER ---
	// Seek to the last 8 bytes
	os.seek(file, -8, os.SEEK_END)
	footer_buffer: [8]byte
	os.read(file, footer_buffer[:])
	index_offset, _ := endian.get_u64(footer_buffer[:], endian.Byte_Order.Little)
	fmt.printf("  Index starts at: %d\n", index_offset)

	// Seek to the index offset
	os.seek(file, i64(index_offset), os.SEEK_SET)

	start_search_offset: i64 = 0
	current_position := i64(index_offset)

	// Looping through index block up until the footer
	for current_position < (file_size - 8) {
		// Read the key length
		klen_buf: [8]byte
		os.read(file, klen_buf[:])
		klen, _ := endian.get_u64(klen_buf[:], endian.Byte_Order.Little)
		current_position += 8

		// Read the key data
		key_buf := make([]byte, klen)
		os.read(file, key_buf[:])
		current_position += i64(klen)

		// Read Offset
		offset_buf: [8]byte
		os.read(file, offset_buf[:])
		offset, _ := endian.get_u64(offset_buf[:], endian.Byte_Order.Little)
		current_position += 8

		// Debug the Index
		fmt.printf("    Index Entry: %s -> Offset %d\n", string(key_buf), offset)

		// Compare to find key
		cmp := compare_keys(key_buf, key)
		delete(key_buf) // clean key_buf from heap

		if cmp <= 0 {
			start_search_offset = i64(offset)
		} else {
			//end_search_offset += i64(offset)
			break
		}

	}

	//Initialize cache key
	cache_key := CacheKey {
		filename = filename,
		offset   = u64(start_search_offset),
	}

	//Check the Block Cache
	cached_block, found_in_cache := lru.get(&db.block_cache.internal_cache, cache_key)

	if found_in_cache {
		fmt.println("  Cache Hit! ⚡")
		val, found := search_block(cached_block, key)
		if found {
			if val == nil {
				// Found, but it's a tombstone (deleted)
				return nil, true, true
			}
			// Found valid value
			return val, true, false
		} else {
			// Block is here, but key is not in it.
			// Since the Index said "If it's anywhere, it's in THIS block",
			// we know it's not in this file.
			return nil, false, false
		}


	}
	fmt.println("  Cache Miss. Reading Disk... 🐢")

	// Ok, Jump to the start_search_offset or the O and read till the end_search_offset
	os.seek(file, start_search_offset, os.SEEK_SET)


	// Read the length of the block (first 8 bytes)
	block_len_buf: [8]byte
	os.read(file, block_len_buf[:])
	block_len, _ := endian.get_u64(block_len_buf[:], .Little)


	//TODO: This memory is never freed, you NEED to fix this to avoid memory leaks later.

	// Read the block data
	buffer := make([]byte, block_len) // hmm... is this memory ever freed?
	bytes_read, _ := os.read(file, buffer)
	fmt.printf("  Read %d bytes from disk.\n", bytes_read)

	// Read the last 4 bytes to get the checksum
	checksum_buf: [4]byte
	os.read(file, checksum_buf[:])
	checksum, _ := endian.get_u32(checksum_buf[:], .Little)

	// Calculate the checksum and compare it to read checksum
	calc_checksum := hash.crc32(buffer)

	if checksum != calc_checksum {
		fmt.println("There is a corruption in the file, the checksum does not match")
		return nil, false, false
	}

	// UPDATE CACHE 💾
	// Save this block so we don't have to read it next time
	lru.set(&db.block_cache.internal_cache, cache_key, buffer)

	// Search the fresh buffer
	val, found := search_block(buffer, key)

	if found {
		fmt.println("  FOUND in Disk Block! ✅")
		if val == nil {
			return nil, true, true
		}
		return val, true, false
	}
	fmt.println("  NOT FOUND in Disk Block. ❌")

	return nil, false, false

}
