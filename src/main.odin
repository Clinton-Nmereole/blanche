package blanche

import "core:fmt"
import "core:os"

main :: proc() {
	/* ======== Test for Memtable ========
	fmt.println("Initializing Blanche Phase 1...")

	// 1. Create the MemTable
	mt := memtable_init()

	// 2. Insert keys OUT OF ORDER
	// Note: We cast strings to []byte using distinct keys
	fmt.println("Inserting: Zebra, Apple, Monkey, Banana...")

	memtable_put(mt, transmute([]byte)string("Zebra"), transmute([]byte)string("Striped Horse"))
	memtable_put(mt, transmute([]byte)string("Apple"), transmute([]byte)string("Red Fruit"))
	memtable_put(mt, transmute([]byte)string("Monkey"), transmute([]byte)string("Ooh ooh ah ah"))
	memtable_put(mt, transmute([]byte)string("Banana"), transmute([]byte)string("Yellow Fruit"))

	// 3. Test GET (Read)
	fmt.println("\n--- Testing GET ---")
	val, found := memtable_get(mt, transmute([]byte)string("Monkey"))
	if found {
		fmt.printf("Found Monkey! Value: %s\n", string(val))
	} else {
		fmt.println("Monkey NOT found. (Bug?)")
	}

	// 4. Test ORDER (Iteration)
	// If this prints Apple -> Banana -> Monkey -> Zebra, you WIN.
	fmt.println("\n--- Testing SORT ORDER ---")
	memtable_print(mt)
    */


	/* ======= Test for WAL ========
	wal_filename := "../data/wal.log"

	// --- SCENARIO 1: The "Before" ---
	fmt.println("--- Session 1: Writing Data ---")

	// Clean up old test file
	os.remove(wal_filename)

	mt := memtable_init()
	wal, _ := wal_init(wal_filename)

	key := transmute([]byte)string("User:100")
	val := transmute([]byte)string("Alice Wonderland")

	// 1. Write to WAL
	fmt.println("Writing 'Alice' to WAL...")
	if wal_append(wal, key, val) {
		fmt.println(" -> Write Success")
	} else {
		fmt.println(" -> Write FAILED")
	}

	// 2. Write to MemTable (In real DB, you do this after WAL success)
	memtable_put(mt, key, val)

	// "Crash" -> We close everything and lose the 'mt' variable.
	// In a real crash, RAM is wiped instantly.

	fmt.println("--- SIMULATING CRASH/RESTART ---")

	// --- SCENARIO 2: The "After" ---

	// Create a BRAND NEW MemTable (Empty)
	new_mt := memtable_init()

	// Open the SAME WAL file
	new_wal, _ := wal_init(wal_filename)

	// RECOVER!
	fmt.println("Recovering from WAL...")
	wal_recover(new_wal, new_mt)

	// CHECK
	fmt.println("Checking new MemTable for 'User:100'...")
	found_val, found := memtable_get(new_mt, key)

	if found {
		fmt.printf("SUCCESS! Found recovered value: %s\n", string(found_val))
	} else {
		fmt.println("FAILURE! Data was lost.")
	}
    */

	// --- SETUP ---
	// ====== Test for DB =========
	// Manually clear old data to ensure a clean test
	// (In a real app, you wouldn't delete your database on startup!)
	fmt.println("--- CLEANING OLD DATA ---")
	os.remove("data/wal.log")
	// Note: We leave old .sst files for now, or you can manually delete 'data' folder

	fmt.println("--- PHASE 3 STRESS TEST ---")
	db := db_open("data")
	defer db_close(db)

	// --- CONFIGURATION ---
	// We want to fill 4MB quickly. 
	// Let's use 1KB values. It should take ~4096 records to trigger.
	val_size := 1024
	large_value := make([]byte, val_size, context.allocator)
	for i := 0; i < val_size; i += 1 {
		large_value[i] = 'A' // Fill with letter 'A'
	}
	defer delete(large_value)

	fmt.println("Step 1: Pumping data into MemTable...")
	fmt.printf("Threshold is: %d bytes\n", MEMTABLE_THRESHOLD)

	flush_occured := false

	// --- INSERT LOOP ---
	// We loop 5000 times, which is 5MB total (more than the 4MB limit)
	for i := 0; i < 5000; i += 1 {
		// Create unique key: "User:0", "User:1", ...
		key_str := fmt.tprintf("User:%d", i)
		key := transmute([]byte)key_str

		// Capture size BEFORE insert
		size_before := db.memtable.size

		// PUT (This might trigger the flush)
		db_put(db, key, large_value)

		// Capture size AFTER insert
		size_after := db.memtable.size

		// --- THE CHECK ---
		// If size went DOWN, it means we flushed and cleared RAM.
		if size_after < size_before {
			fmt.println("\n------------------------------------------------")
			fmt.println("!!! FLUSH EVENT DETECTED !!!")
			fmt.printf("At Record Index: %d\n", i)
			fmt.printf("Size Before: %d -> Size After: %d\n", size_before, size_after)
			fmt.println("------------------------------------------------")
			flush_occured = true
			break // Test passed, stop the loop
		}

		// Progress bar every 500 records
		if i % 500 == 0 {
			fmt.printf("Inserted %d records... (Current RAM Usage: %d bytes)\n", i, size_after)
		}
	}

	// --- FINAL REPORT ---
	if flush_occured {
		fmt.println("\nSUCCESS: Phase 3 is working.")
		fmt.println("1. RAM was cleared.")
		fmt.println("2. Check your 'data/' folder. You should see a new .sst file.")
		fmt.println("   (e.g., '173... .sst')")
	} else {
		fmt.println("\nFAILURE: Loop finished but no flush detected.")
		fmt.println("Did we reach the 4MB threshold?")
		fmt.printf("Final Size: %d\n", db.memtable.size)
	}

}
