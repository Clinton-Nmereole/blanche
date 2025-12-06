package blanche

import "../constants"
import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

DB :: struct {
	memtable:       ^Memtable,
	wal:            ^WAL,
	data_directory: string,
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
	db.wal, _ = wal_init(db.wal.filename)

}

// How often do we save a shortcut? 
// 100 means we only index every 100th key.
SPARSE_FACTOR :: 100

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
