package blanche

import "core:fmt"
import "core:os"

main :: proc() {
	/*
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

}
