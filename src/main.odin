package blanche

import "core:fmt"

main :: proc() {
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
}
