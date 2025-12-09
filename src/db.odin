package blanche

import "../constants"
import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

DB :: struct {
	memtable:       ^Memtable,
	wal:            ^WAL,
	data_directory: string,
	sst_files:      [dynamic]string,
}

// CONSTANT: When do we freeze and flush? (4MB)
MEMTABLE_THRESHOLD :: 4 * constants.MB

// basically initialize the DB, and recover from WAL incase there was a failure
db_open :: proc(dir: string) -> ^DB {

	if !os.is_dir(dir) {
		os.make_directory(dir)
	}

	db := new(DB)
	db.data_directory = dir

	// Load the list of names of the .sst files into db.sstables 
	// So open a os.Handle with Read only into the directory
	// Loop through every file in the directory
	// If the file has a .sst extension, get its name and save it to the dynamic array
	d, err := os.open(dir, os.O_RDONLY)
	if err == os.ERROR_NONE {
		defer os.close(d)

		infos, _ := os.read_dir(d, -1)

		for info in infos {
			// Check if the file ends in .sst
			if !info.is_dir && strings.has_suffix(info.name, ".sst") {
				// Construct full path "data/123.sst"
				full_path := fmt.tprintf("%s/%s", dir, info.name)
				append(&db.sst_files, full_path)
			}
		}
		// SORT THEM! 
		// We want Newest files first. 
		// Since our names are timestamps (100.sst, 200.sst), 
		// we can sort strings in Descending order (Big numbers first).

		slice.sort(db.sst_files[:])
		slice.reverse(db.sst_files[:])
	}


	// initialize memtable
	db.memtable = memtable_init()

	//initialize WAL
	// Note: In Odin, string concatenation requires allocation. 
	// For simplicity here, we assume "data/wal.log" is fine.
	wal_path := fmt.tprintf("%s/wal.log", dir)
	db.wal, _ = wal_init(wal_path)

	// RECOVERY (The Critical Step)
	// Read the WAL and fill the MemTable back up
	wal_recover(db.wal, db.memtable) //TODO: this does not give an error if recovery fails. Might want to handle that

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
	// 2. Write to the memtable.
	// 3. Check if the memtable size is at the threshold, and if it is, then write to file.

	if !wal_append(db.wal, key, value) {
		fmt.println("Failed to append to WAL.")
	}

	memtable_put(db.memtable, key, value)

	if db.memtable.size >= MEMTABLE_THRESHOLD {
		//this is where we flush to sst
		sstable_flush(db)
	}

}

db_get :: proc(db: ^DB, key: []byte) -> ([]byte, bool) {

	// First we would like to check if the key is in the memtable
	val_memtable, memtable_found := memtable_get(db.memtable, key)
	if memtable_found {
		return val_memtable, memtable_found
	}

	// Use sstable_find to check the newest .sst file and then check subsequent .sst files after that
	// Loop through all the sorted sst_files in the db since they are sorted in reverse order,
	// we are looking at the newest entries first

	for sstable in db.sst_files {

		val_sstable, sstable_found := sstable_find(sstable, key)
		if sstable_found {
			return val_sstable, sstable_found
		}

	}


	return nil, false


}

sstable_flush :: proc(db: ^DB) {
	// --- DIAGNOSTIC START ---
	cwd := os.get_current_directory()
	fmt.printf("\n[DIAGNOSTIC] Current Working Directory: %s\n", cwd)

	// Check if 'data' exists and what it is
	info, err := os.stat(db.data_directory)
	if err != os.ERROR_NONE {
		fmt.printf(
			"[DIAGNOSTIC] CRITICAL: Could not stat '%s'. Error: %v\n",
			db.data_directory,
			err,
		)
	} else {
		fmt.printf("[DIAGNOSTIC] '%s' exists. Mode: %o (Octal)\n", db.data_directory, info.mode)
		if !os.S_ISDIR(u32(info.mode)) {
			fmt.printf(
				"[DIAGNOSTIC] FATAL: '%s' is NOT a directory! It is a file.\n",
				db.data_directory,
			)
		}
	}
	// --- DIAGNOSTIC END ---

	timestamp := time.to_unix_nanoseconds(time.now())
	filename := fmt.tprintf("%s/%d.sst", db.data_directory, timestamp)

	// Try adding O_TRUNC and changing permissions to 0o666 (Read/Write for Everyone)
	file, open_err := os.open(filename, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o664)

	if open_err != os.ERROR_NONE {
		fmt.printf("!!! ERROR CREATING FILE !!!\n")
		fmt.printf("Target: %s\n", filename)
		fmt.printf("Error: %v\n", open_err)
		return
	}
	defer os.close(file)

	// 1. Create a unique filename based on current time
	// format: data/12345678.sst
	//timestamp := time.to_unix_nanoseconds(time.now())
	//	filename := fmt.tprintf("%s/%d.sst", db.data_directory, timestamp)

	// 2. Open the new file
	//	file, err := os.open(filename, os.O_WRONLY | os.O_CREATE, 0o644)
	if err != os.ERROR_NONE {
		// --- ADD THIS DEBUG PRINT ---
		fmt.printf("!!! ERROR CREATING FILE !!!\n")
		fmt.printf("Target Filename: '%s'\n", filename)
		fmt.printf("OS Error Code: %v\n", err)
		return
	}

	append(&db.sst_files, filename)

	// sort
	slice.sort(db.sst_files[:])
	slice.reverse(db.sst_files[:])

	// 3. WRITE THE DATA (The heavy lifting)
	// We will implement this detailed binary encoding in a moment.
	keys_count := sstable_write_file(file, db.memtable)
	fmt.printf("Flushed SSTable: %s\n", filename)

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
		key_length_bytes: [4]byte
		endian.put_u32(key_length_bytes[:], endian.Byte_Order.Little, u32(len(current_node.key)))
		os.write(file, key_length_bytes[:])
		current_offset += 4

		// Write actual key
		os.write(file, current_node.key)
		current_offset += u64(len(current_node.key))


		// Write value length
		value_length_bytes: [4]byte
		endian.put_u32(
			value_length_bytes[:],
			endian.Byte_Order.Little,
			u32(len(current_node.value)),
		)
		os.write(file, value_length_bytes[:])
		current_offset += 4

		// Write actual value
		os.write(file, current_node.value)
		current_offset += u64(len(current_node.value))

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
		key_len: [4]byte
		endian.put_u32(key_len[:], endian.Byte_Order.Little, u32(len(entry.key)))
		os.write(file, key_len[:])

		// write key
		os.write(file, entry.key)

		// write offset
		// since it is an integer (u64 specifically), we need to convert it to bytes
		offset_bytes: [8]byte
		endian.put_u32(offset_bytes[:], endian.Byte_Order.Little, u32(entry.offset))
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

sstable_find :: proc(filename: string, key: []byte) -> ([]byte, bool) {

	// First we open the file
	file, err := os.open(filename, os.O_RDONLY)
	if err != os.ERROR_NONE {return nil, false}
	defer os.close(file)

	// Check if the file is corrupted
	file_size, _ := os.file_size(file)

	if file_size < 8 {
		fmt.printf("The file %s is corrupted and could not be read", filename)
		return nil, false
	}


	// --- STEP 1: READ FOOTER ---
	// Seek to the last 8 bytes
	os.seek(file, -8, os.SEEK_END)
	footer_buffer: [8]byte
	os.read(file, footer_buffer[:])
	index_offset, _ := endian.get_u64(footer_buffer[:], endian.Byte_Order.Little)

	// Seek to the index offset 
	os.seek(file, i64(index_offset), os.SEEK_SET)

	start_search_offset: i64 = 0
	current_position := i64(index_offset)

	// Now we want to read each key from the index section of the form [key length] [key_data] [offset]
	// Check for a suitable start position by comparing the key being searched with key data
	// if the key is smaller, we will set our start_search_offset value equal to the offset value contained in our index block
	// if we eventually find a larger key, we should stop and possibly set a value end_search_offset to that offset
	// the reason I think this is a good idea is that if the we get a start_search_offset of say 500th entry, but our block 1 
	// contains 5000 records, we don't want to search the entire store of 4500 other entries until we get back to index block
	// We want to get an end_search_offset that says we know  the key is less than the 1000th entry.
	// This way we only read 500 entries before saying we didn't find the key rather than 4500 entries.

	// Looping through index block up until the footer
	for current_position < (file_size - 8) {
		// Read the key length 
		klen_buf: [4]byte
		os.read(file, klen_buf[:])
		klen, _ := endian.get_u32(klen_buf[:], endian.Byte_Order.Little)
		current_position += 4

		// Read the key data
		key_buf := make([]byte, klen)
		os.read(file, key_buf[:])
		current_position += i64(klen)

		// Read Offset
		offset_buf: [8]byte
		os.read(file, offset_buf[:])
		offset, _ := endian.get_u32(offset_buf[:], endian.Byte_Order.Little)
		current_position += 8

		// Compare to find key
		cmp := compare_keys(key_buf, key)
		delete(key_buf) // clean key_buf from heap

		if cmp <= 0 {
			start_search_offset += i64(offset)
		} else {
			//end_search_offset += i64(offset)
			break
		}

	}

	// Ok, Jump to the start_search_offset or the O and read till the end_search_offset
	os.seek(file, start_search_offset, os.SEEK_SET)
	curr := start_search_offset

	// Interesting, but if the item being searched is larger than the largest index, end_search_offset will remain 0
	// if we try to loop while curr < end_search_offset, we will have a situation like while 500 < 0 which means the search will fail.
	// So we can do if statement that if end_search_offset < start_search_offset, then we search till the end of index block
	// else we search from start_search_offset to end_search_offset. I'm not exactly sure the performance benefits but
	// But does this even matter? if the end_search_offset is a value we only search the entire array block if the searched 
	// key is not in the database. If it is in the database we will find it in the index length window anyway.
	// So end_search_offset only improves the worst case scenario, which is that the key is not in the database
	// Example we have indexes "Apple", "Ball", "Box", "Cat", "Cube", "Date", ... "Monkey"... "Zebra" and we are looking for "Condo" but "Condo"
	// is not in block 1, we will start from "Cat" and search till the end of block 1. However, with end_search_offset we can tell the user it is not
	// in the database once we hit the position of "Cube", so we are faster at telling the user "not found".
	// There is no difference however, if "Condo" is in the database/file

	// Well just realized that end_search_offset is not needed because of the sorted nature of the database, if we are searching for a key and 
	// ever come across a key in the database larger than the key being searched for we can just stop the search because the key being searched for is 
	// not in the database. So forget the ramblings above.

	for curr < i64(index_offset) {
		// read the key length
		klen_byte: [4]byte
		_, err := os.read(file, klen_byte[:])
		if err != nil {break}
		klen, _ := endian.get_u32(klen_byte[:], endian.Byte_Order.Little)
		curr += 4

		// read the actual key
		found_key := make([]byte, klen)
		os.read(file, found_key[:])
		curr += i64(klen)

		// read the value length
		vlen_byte: [4]byte
		os.read(file, vlen_byte[:])
		vlen, _ := endian.get_u32(vlen_byte[:], endian.Byte_Order.Little)
		curr += 4

		// read the actual value 
		found_value := make([]byte, vlen)
		os.read(file, found_value[:])
		curr += i64(vlen)

		// Check if the found key is equal to the key being searched
		cmp := compare_keys(found_key, key)
		// clean up found_key allocated with make, we don't need it anymore
		delete(found_key)
		if cmp == 0 {
			// We found the key
			return found_value, true
		}
		if cmp > 0 {
			// We found a key greater than the key being searched, since the database is sorted we can end search
			// because that means the key is not in the database
			delete(found_value) // since the key is not in the database clean up found_value allocated with make
			return nil, false
		}

		delete(found_value) // clean up in the case that we are still searching (we haven't found the key yet)


	}


	return nil, false

}
