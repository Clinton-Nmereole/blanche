package blanche

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

benchmark_negative_lookups :: proc(db: ^DB) {
	start_time := time.now()
	for i := 0; i < 10000; i += 1 {
		found, is_in := db_get(db, transmute([]byte)string("No One"))

		if is_in {
			fmt.println("This was the value of the searched key: ", found)
		}
	}
	duration := time.diff(start_time, time.now())
	fmt.printf("Duration: %v\n", duration)

}

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

	/*
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
    */


	/*
	// ===== Test for DB search =====//
	// --- 1. SETUP ---
	// Start fresh so we know exactly what is on disk
	fmt.println("--- SETUP: Cleaning Data Folder ---")
	os.remove("data/wal.log")
	// Note: Ideally delete all .sst files manually if you want a purely clean test, 
	// but this logic works even if old files exist (they just get ignored or sorted to back).

	db := db_open("data")
	defer db_close(db)

	// --- 2. BURY THE TREASURE ---
	fmt.println("\n--- STEP 1: Burying the Treasure ---")
	treasure_key := transmute([]byte)string("Gold_Bar")
	treasure_val := transmute([]byte)string("Value_1000_Dollars")

	db_put(db, treasure_key, treasure_val)
	fmt.println("Inserted 'Gold_Bar' into MemTable.")

	// --- 3. FORCE FLUSH (Pour Concrete) ---
	fmt.println("\n--- STEP 2: Flooding MemTable to force Flush ---")
	fmt.printf("Target Threshold: %d bytes\n", MEMTABLE_THRESHOLD)

	// We create a 1KB junk payload
	junk_val := make([]byte, 1024, context.allocator)
	defer delete(junk_val)
	for i := 0; i < 1024; i += 1 {junk_val[i] = 'X'}

	flush_happened := false

	// Loop until we detect the size drop
	for i := 0; i < 10000; i += 1 {
		size_before := db.memtable.size

		// Key doesn't matter, just filling space
		key := transmute([]byte)fmt.tprintf("Junk:%d", i)
		db_put(db, key, junk_val)

		if db.memtable.size < size_before {
			fmt.println("!!! FLUSH DETECTED !!!")
			fmt.println("The 'Gold_Bar' has been moved from RAM to Disk.")
			flush_happened = true
			break
		}
	}

	if !flush_happened {
		fmt.println(
			"TEST FAILED: Could not force a flush. Lower your threshold or increase loop count.",
		)
		return
	}

	// --- 4. THE EXCAVATION (The Actual Test) ---
	fmt.println("\n--- STEP 3: The Excavation (db_get) ---")

	// Sanity Check: Is it really gone from RAM?
	// We manually check MemTable first just to prove a point
	_, in_ram := memtable_get(db.memtable, treasure_key)
	if !in_ram {
		fmt.println("Confirmed: 'Gold_Bar' is NOT in MemTable.")
	} else {
		fmt.println("WARNING: 'Gold_Bar' is still in MemTable? Test result might be fake.")
	}

	// NOW CALL THE REAL GET
	fmt.println("Calling db_get('Gold_Bar')...")
	val, found := db_get(db, treasure_key)

	if found {
		result_str := string(val)
		if result_str == "Value_1000_Dollars" {
			fmt.println("\nSUCCESS! You found the treasure on Disk!")
			fmt.println("Flow Verified: db_get -> sstable_find -> Footer -> Index -> Data Block")
		} else {
			fmt.printf("\nFAILURE: Found key, but wrong value! Got: '%s'\n", result_str)
		}
	} else {
		fmt.println("\nFAILURE: db_get returned 'Not Found'.")
		fmt.println("Check: Did sstable_find return false? Did the Index Scan fail?")
	}

	// --- 5. VERSIONING TEST (Bonus) ---
	// Test if MemTable shadows Disk
	fmt.println("\n--- STEP 4: Shadowing Test ---")
	fmt.println("Inserting NEW version of 'Gold_Bar' into RAM...")
	new_val := transmute([]byte)string("Value_0_Dollars_Fake")
	db_put(db, treasure_key, new_val)

	val2, found2 := db_get(db, treasure_key)
	if string(val2) == "Value_0_Dollars_Fake" {
		fmt.println("SUCCESS: MemTable correctly overrode the Disk version.")
	} else {
		fmt.println(
			"FAILURE: db_get returned the old Disk version instead of the new RAM version.",
		)
	}
    */


	/*
	// ==== Compaction Test ====
	// --- 1. SETUP ---

	fmt.println("--- PHASE 5 TEST: Compaction ---")

	// Clean start
	os.remove("data/wal.log")
	// Note: For a true clean test, manually delete the 'data' folder or all .sst files before running
	// rm -rf data/*.sst 

	db := db_open("data")
	defer db_close(db)

	key := transmute([]byte)string("User:1")

	// --- 2. CREATE FRAGMENTATION (The Mess) ---
	// We want 3 separate files on disk. 
	// Instead of waiting for the 4MB limit, we manually call flush() 
	// to force tiny files.

	fmt.println("\nStep 1: Creating 3 separate SSTable files...")

	// Version 1 (Oldest)
	fmt.println(" -> Writing Version 1 (Alice)... Flushing.")
	db_put(db, key, transmute([]byte)string("Alice_v1"))
	sstable_flush(db) // Force create File #1

	// Version 2 (Middle)
	fmt.println(" -> Writing Version 2 (Bob)... Flushing.")
	db_put(db, key, transmute([]byte)string("Bob_v2"))
	sstable_flush(db) // Force create File #2

	// Version 3 (Newest)
	fmt.println(" -> Writing Version 3 (Charlie)... Flushing.")
	db_put(db, key, transmute([]byte)string("Charlie_v3"))
	sstable_flush(db) // Force create File #3

	// --- 3. VERIFY MESSY STATE ---
	file_count := len(db.sst_files)
	fmt.printf("\nStep 2: verifying Pre-Compaction State. File Count: %d\n", file_count)

	if file_count < 3 {
		fmt.println("FAILURE: Expected at least 3 SSTable files. Did sstable_flush work?")
		return
	}

	// Verify we can read the newest version (Charlie) even with multiple files
	val, found := db_get(db, key)
	if !found || string(val) != "Charlie_v3" {
		fmt.printf(
			"FAILURE: Read before compaction failed. Expected 'Charlie_v3', got '%s'\n",
			string(val),
		)
		return
	}
	fmt.println(" -> Read Check Passed: Got 'Charlie_v3' (Reading from Newest SST)")

	// --- 4. RUN COMPACTION (The Cleanup) ---
	fmt.println("\nStep 3: Running db_compact()...")
	db_compact(db)

	// --- 5. VERIFY CLEAN STATE ---
	new_file_count := len(db.sst_files)
	fmt.printf("\nStep 4: Verifying Post-Compaction State. File Count: %d\n", new_file_count)

	// CHECK A: File Count
	if new_file_count != 1 {
		fmt.printf(
			"FAILURE: Compaction didn't reduce file count! Still have %d files.\n",
			new_file_count,
		)
		return
	} else {
		fmt.println(" -> SUCCESS: Collapsed into exactly 1 file.")
	}

	// CHECK B: Data Integrity
	// Does "User:1" still equal "Charlie_v3"? 
	// If compaction logic was wrong, it might have kept "Alice" (Oldest) or lost the key entirely.
	val_post, found_post := db_get(db, key)

	if !found_post {
		fmt.println("FAILURE: The key disappeared after compaction!")
		return
	}

	if string(val_post) == "Charlie_v3" {
		fmt.println(" -> SUCCESS: Data Integrity preserved. 'Charlie_v3' survived.")
	} else {
		fmt.printf(
			"FAILURE: Wrong version survived! Expected 'Charlie_v3', got '%s'\n",
			string(val_post),
		)
	}

	fmt.println("\n--- TEST COMPLETE: COMPACTION WORKS ---")
    */
    */

	/*
	// ==== BLOOM FILTER TEST ====
	// Initialize a bloom filter
	filter := bloomfilter_init(10, 0.1)
	found := contains(filter, transmute([]u8)string("test_key"))
	fmt.println("The value returned from contains is: ", found)
	add(filter, transmute([]byte)string("apple"))
	found = contains(filter, transmute([]byte)string("apple"))
	fmt.println(
		"The value returned from contains after inserting 'apple' in the filter and searching for it is: ",
		found,
	)
	// We added "apple" earlier...
	result := contains(filter, transmute([]u8)(string("banana")))

	fmt.println(
		"The value returned from contains after inserting 'banana' in the filter and searching for it is: ",
		result,
	)
    */

	// ===== Benchmarking Bloom Filter =====//
	// --- 1. SETUP ---
	// Start fresh so we know exactly what is on disk
	fmt.println("--- SETUP: Cleaning Data Folder ---")
	os.remove("data/wal.log")
	// Note: Ideally delete all .sst files manually if you want a purely clean test, 
	// but this logic works even if old files exist (they just get ignored or sorted to back).

	db := db_open("data")
	defer db_close(db)

	// --- 2. BURY THE TREASURE ---
	fmt.println("\n--- STEP 1: Burying the Treasure ---")
	treasure_key := transmute([]byte)string("Gold_Bar")
	treasure_val := transmute([]byte)string("Value_1000_Dollars")

	db_put(db, treasure_key, treasure_val)
	fmt.println("Inserted 'Gold_Bar' into MemTable.")

	// --- 3. FORCE FLUSH (Pour Concrete) ---
	fmt.println("\n--- STEP 2: Flooding MemTable to force Flush ---")
	fmt.printf("Target Threshold: %d bytes\n", MEMTABLE_THRESHOLD)

	// We create a 1KB junk payload
	junk_val := make([]byte, 1024, context.allocator)
	defer delete(junk_val)
	for i := 0; i < 1024; i += 1 {junk_val[i] = 'X'}

	flush_happened := false

	// Loop until we detect the size drop
	for i := 0; i < 10000; i += 1 {
		size_before := db.memtable.size

		// Key doesn't matter, just filling space
		key := transmute([]byte)fmt.tprintf("Junk:%d", i)
		db_put(db, key, junk_val)

		if db.memtable.size < size_before {
			fmt.println("!!! FLUSH DETECTED !!!")
			fmt.println("The 'Gold_Bar' has been moved from RAM to Disk.")
			flush_happened = true
			break
		}
	}


	benchmark_negative_lookups(db)

	// --- 4. DIG UP THE TREASURE ---
	fmt.println("\n--- STEP 3: Retrieve the Gold ---")
	val, found := db_get(db, treasure_key)

	if found {
		fmt.printf(
			"Success! 🏴‍☠️ Found key '%s' with value: '%s'\n",
			string(treasure_key),
			string(val),
		)
	} else {
		fmt.printf(
			"FAILURE ☠️. The Bloom Filter let us through, but the key '%s' was not found on disk.\n",
			string(treasure_key),
		)
	}


}
