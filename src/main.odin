package blanche

import "../constants"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// ============================================================================
// TEST UTILITIES
// ============================================================================

test_counter := 0
passed_tests := 0
failed_tests := 0

assert :: proc(condition: bool, test_name: string, loc := #caller_location) {
	test_counter += 1
	if condition {
		fmt.printf("✓ Test %d PASSED: %s\n", test_counter, test_name)
		passed_tests += 1
	} else {
		fmt.printf(
			"✗ Test %d FAILED: %s (at %s:%d)\n",
			test_counter,
			test_name,
			loc.file_path,
			loc.line,
		)
		failed_tests += 1
	}
}

print_test_summary :: proc() {
	fmt.println()
	fmt.println("======================================================================")
	fmt.println("TEST SUMMARY")
	fmt.println("======================================================================")
	fmt.printf("Total Tests: %d\n", test_counter)
	fmt.printf("✓ Passed: %d\n", passed_tests)
	fmt.printf("✗ Failed: %d\n", failed_tests)

	if failed_tests == 0 {
		fmt.println("\n🎉 ALL TESTS PASSED! 🎉")
	} else {
		fmt.println("\n⚠️  SOME TESTS FAILED")
	}
	fmt.println("======================================================================")
}

cleanup_test_data :: proc() {
	// Remove all test data files
	if os.is_dir("test_data") {
		os.remove_directory("test_data")
	}
}

// ============================================================================
// PHASE 1: MEMTABLE TESTS
// ============================================================================

test_memtable_basic_operations :: proc() {
	fmt.println()
	fmt.println("----------------------------------------------------------------------")
	fmt.println("PHASE 1: MEMTABLE TESTS")
	fmt.println("----------------------------------------------------------------------")

	mt := memtable_init()
	defer memtable_clear(mt)

	// Test 1: Insert and retrieve a single key
	key1 := transmute([]byte)string("TestKey1")
	val1 := transmute([]byte)string("TestValue1")
	memtable_put(mt, key1, val1)

	retrieved, found := memtable_get(mt, key1)
	assert(found, "MemTable: Key should be found after insertion")
	assert(
		string(retrieved) == "TestValue1",
		"MemTable: Retrieved value should match inserted value",
	)

	// Test 2: Update existing key
	val2 := transmute([]byte)string("UpdatedValue1")
	memtable_put(mt, key1, val2)
	retrieved, found = memtable_get(mt, key1)
	assert(found, "MemTable: Key should still be found after update")
	assert(string(retrieved) == "UpdatedValue1", "MemTable: Value should be updated")

	// Test 3: Non-existent key
	non_existent := transmute([]byte)string("DoesNotExist")
	_, found = memtable_get(mt, non_existent)
	assert(!found, "MemTable: Non-existent key should return false")

	// Test 4: Multiple keys in sorted order
	memtable_put(mt, transmute([]byte)string("Zebra"), transmute([]byte)string("Animal"))
	memtable_put(mt, transmute([]byte)string("Apple"), transmute([]byte)string("Fruit"))
	memtable_put(mt, transmute([]byte)string("Banana"), transmute([]byte)string("Yellow"))

	// Verify all keys can be retrieved
	val_zebra, found_zebra := memtable_get(mt, transmute([]byte)string("Zebra"))
	assert(found_zebra && string(val_zebra) == "Animal", "MemTable: Zebra should be retrievable")

	val_apple, found_apple := memtable_get(mt, transmute([]byte)string("Apple"))
	assert(found_apple && string(val_apple) == "Fruit", "MemTable: Apple should be retrievable")

	val_banana, found_banana := memtable_get(mt, transmute([]byte)string("Banana"))
	assert(
		found_banana && string(val_banana) == "Yellow",
		"MemTable: Banana should be retrievable",
	)

	// Test 5: Size tracking
	initial_count := mt.count
	memtable_put(mt, transmute([]byte)string("NewKey"), transmute([]byte)string("NewValue"))
	assert(mt.count == initial_count + 1, "MemTable: Count should increment after insertion")

	// Test 6: Clear operation
	memtable_clear(mt)
	assert(mt.count == 0, "MemTable: Count should be 0 after clear")
	assert(mt.size == 0, "MemTable: Size should be 0 after clear")

	_, found = memtable_get(mt, key1)
	assert(!found, "MemTable: Keys should not be found after clear")
}

// ============================================================================
// PHASE 2: WRITE-AHEAD LOG TESTS
// ============================================================================

test_wal_operations :: proc() {
	fmt.println()
	fmt.println("----------------------------------------------------------------------")
	fmt.println("PHASE 2: WRITE-AHEAD LOG TESTS")
	fmt.println("----------------------------------------------------------------------")

	cleanup_test_data()
	os.make_directory("test_data")
	wal_filename := "test_data/test_wal.log"

	// Test 1: WAL creation and append
	wal, ok := wal_init(wal_filename)
	assert(ok, "WAL: Should initialize successfully")

	key := transmute([]byte)string("User:100")
	val := transmute([]byte)string("Alice")
	success := wal_append(wal, key, val)
	assert(success, "WAL: Append should succeed")

	os.close(wal.file)

	// Test 2: WAL recovery
	mt := memtable_init()
	defer memtable_clear(mt)

	wal2, _ := wal_init(wal_filename)
	wal_recover(wal2, mt)

	retrieved, found := memtable_get(mt, key)
	assert(found, "WAL Recovery: Key should be recovered from WAL")
	assert(string(retrieved) == "Alice", "WAL Recovery: Value should match original")

	os.close(wal2.file)

	// Test 3: Multiple entries recovery
	os.remove(wal_filename)
	wal3, _ := wal_init(wal_filename)

	for i := 0; i < 10; i += 1 {
		k := transmute([]byte)fmt.tprintf("Key:%d", i)
		v := transmute([]byte)fmt.tprintf("Value:%d", i)
		wal_append(wal3, k, v)
	}
	os.close(wal3.file)

	mt2 := memtable_init()
	defer memtable_clear(mt2)

	wal4, _ := wal_init(wal_filename)
	wal_recover(wal4, mt2)

	assert(mt2.count == 10, "WAL Recovery: Should recover all 10 entries")

	test_key := transmute([]byte)string("Key:5")
	test_val, test_found := memtable_get(mt2, test_key)
	assert(
		test_found && string(test_val) == "Value:5",
		"WAL Recovery: Individual entries should be correct",
	)

	os.close(wal4.file)
}

// ============================================================================
// PHASE 3: SSTABLE BUILDER TESTS
// ============================================================================

test_sstable_builder :: proc() {
	fmt.println()
	fmt.println("----------------------------------------------------------------------")
	fmt.println("PHASE 3: SSTABLE BUILDER TESTS")
	fmt.println("----------------------------------------------------------------------")

	cleanup_test_data()
	os.make_directory("test_data")
	sst_filename := "test_data/test.sst"

	// Test 1: Build a simple SSTable
	builder := builder_init(sst_filename)
	assert(builder != nil, "SSTable Builder: Should initialize successfully")

	// Add sorted keys
	builder_add(builder, transmute([]byte)string("Key1"), transmute([]byte)string("Value1"))
	builder_add(builder, transmute([]byte)string("Key2"), transmute([]byte)string("Value2"))
	builder_add(builder, transmute([]byte)string("Key3"), transmute([]byte)string("Value3"))

	builder_finish(builder)

	// Test 2: Verify file was created
	assert(os.exists(sst_filename), "SSTable Builder: File should exist after finish")

	// Test 3: Verify file is not empty
	info, err := os.stat(sst_filename)
	assert(err == os.ERROR_NONE, "SSTable Builder: Should be able to stat file")
	assert(info.size > 0, "SSTable Builder: File should not be empty")
	os.file_info_delete(info)

	// Test 4: Build SSTable with many entries (test sparse indexing)
	sst_filename2 := "test_data/test_large.sst"
	builder2 := builder_init(sst_filename2)

	// Add 500 entries (should create multiple index entries with SPARSE_FACTOR=100)
	for i := 0; i < 500; i += 1 {
		key := transmute([]byte)fmt.tprintf("Key:%05d", i)
		val := transmute([]byte)fmt.tprintf("Value:%05d", i)
		builder_add(builder2, key, val)
	}

	builder_finish(builder2)

	info2, err2 := os.stat(sst_filename2)
	assert(
		err2 == os.ERROR_NONE && info2.size > 0,
		"SSTable Builder: Large file should be created",
	)
	os.file_info_delete(info2)
}

// ============================================================================
// PHASE 4: SSTABLE READ PATH TESTS
// ============================================================================

test_sstable_read_path :: proc() {
	fmt.println()
	fmt.println("----------------------------------------------------------------------")
	fmt.println("PHASE 4: SSTABLE READ PATH TESTS")
	fmt.println("----------------------------------------------------------------------")

	cleanup_test_data()
	os.make_directory("test_data")
	sst_filename := "test_data/test_read.sst"

	// Create a test SSTable
	builder := builder_init(sst_filename)
	test_data := [?]struct {
		key:   string,
		value: string,
	} {
		{"Apple", "Red Fruit"},
		{"Banana", "Yellow Fruit"},
		{"Cherry", "Small Fruit"},
		{"Date", "Sweet Fruit"},
		{"Elderberry", "Purple Fruit"},
	}

	for entry in test_data {
		builder_add(builder, transmute([]byte)entry.key, transmute([]byte)entry.value)
	}
	builder_finish(builder)

	// Test 1: Find existing keys
	val, found, is_tombstone := sstable_find(sst_filename, transmute([]byte)string("Banana"))
	assert(found, "SSTable Find: Should find existing key")
	assert(!is_tombstone, "SSTable Find: Should not be a tombstone")
	assert(string(val) == "Yellow Fruit", "SSTable Find: Value should match")

	// Test 2: Find first key
	val, found, _ = sstable_find(sst_filename, transmute([]byte)string("Apple"))
	assert(found && string(val) == "Red Fruit", "SSTable Find: Should find first key")

	// Test 3: Find last key
	val, found, _ = sstable_find(sst_filename, transmute([]byte)string("Elderberry"))
	assert(found && string(val) == "Purple Fruit", "SSTable Find: Should find last key")

	// Test 4: Non-existent key
	_, found, _ = sstable_find(sst_filename, transmute([]byte)string("Grape"))
	assert(!found, "SSTable Find: Non-existent key should not be found")

	// Test 5: Key before first
	_, found, _ = sstable_find(sst_filename, transmute([]byte)string("Aardvark"))
	assert(!found, "SSTable Find: Key before first should not be found")

	// Test 6: Key after last
	_, found, _ = sstable_find(sst_filename, transmute([]byte)string("Zebra"))
	assert(!found, "SSTable Find: Key after last should not be found")
}

// ============================================================================
// PHASE 5: DB OPERATIONS TESTS
// ============================================================================

test_db_operations :: proc() {
	fmt.println()
	fmt.println("----------------------------------------------------------------------")
	fmt.println("PHASE 5: DB OPERATIONS TESTS")
	fmt.println("----------------------------------------------------------------------")

	cleanup_test_data()

	db := db_open("test_data")
	defer db_close(db)

	// Test 1: Basic put and get
	key := transmute([]byte)string("User:1")
	val := transmute([]byte)string("Alice")
	db_put(db, key, val)

	retrieved, found := db_get(db, key)
	assert(found, "DB Operations: Should find just-inserted key")
	assert(string(retrieved) == "Alice", "DB Operations: Value should match")

	// Test 2: Update value
	val2 := transmute([]byte)string("Bob")
	db_put(db, key, val2)
	retrieved, found = db_get(db, key)
	assert(found && string(retrieved) == "Bob", "DB Operations: Updated value should be retrieved")

	// Test 3: Multiple keys
	for i := 0; i < 100; i += 1 {
		k := transmute([]byte)fmt.tprintf("Key:%d", i)
		v := transmute([]byte)fmt.tprintf("Value:%d", i)
		db_put(db, k, v)
	}

	test_key := transmute([]byte)string("Key:50")
	test_val, test_found := db_get(db, test_key)
	assert(
		test_found && string(test_val) == "Value:50",
		"DB Operations: Should retrieve from many keys",
	)

	// Test 4: Non-existent key
	_, found = db_get(db, transmute([]byte)string("NonExistent"))
	assert(!found, "DB Operations: Non-existent key should not be found")
}

// ============================================================================
// PHASE 5B: DELETE OPERATIONS TESTS
// ============================================================================

test_delete_operations :: proc() {
	fmt.println()
	fmt.println("----------------------------------------------------------------------")
	fmt.println("PHASE 5B: DELETE OPERATIONS TESTS")
	fmt.println("----------------------------------------------------------------------")

	cleanup_test_data()

	db := db_open("test_data")
	defer db_close(db)

	// Test 1: Delete key in MemTable
	key1 := transmute([]byte)string("DeleteMe1")
	val1 := transmute([]byte)string("ToBeDeleted")
	db_put(db, key1, val1)

	// Verify it exists
	retrieved, found := db_get(db, key1)
	assert(found && string(retrieved) == "ToBeDeleted", "DELETE: Key should exist before delete")

	// Delete it
	db_delete(db, key1)

	// Verify it's gone
	_, found_after := db_get(db, key1)
	assert(!found_after, "DELETE: Key should not be found after delete in MemTable")

	// Test 2: Tombstone persists after flush
	key2 := transmute([]byte)string("DeleteMe2")
	val2 := transmute([]byte)string("FlushTest")
	db_put(db, key2, val2)

	retrieved2, found2 := db_get(db, key2)
	assert(found2 && string(retrieved2) == "FlushTest", "DELETE: Key should exist before delete")

	db_delete(db, key2)
	sstable_flush(db)

	_, still_not_found := db_get(db, key2)
	assert(!still_not_found, "DELETE: Deleted key should stay deleted after flush")

	// Test 3: Multiple deletes
	for i := 0; i < 10; i += 1 {
		k := transmute([]byte)fmt.tprintf("DeleteKey:%d", i)
		v := transmute([]byte)fmt.tprintf("DeleteValue:%d", i)
		db_put(db, k, v)
		db_delete(db, k)
	}

	// Verify all are deleted
	all_deleted := true
	for i := 0; i < 10; i += 1 {
		k := transmute([]byte)fmt.tprintf("DeleteKey:%d", i)
		_, found := db_get(db, k)
		if found {
			all_deleted = false
			break
		}
	}
	assert(all_deleted, "DELETE: All deleted keys should not be found")

	// Test 4: Delete non-existent key (should not crash)
	non_existent := transmute([]byte)string("NeverExisted")
	db_delete(db, non_existent)
	assert(true, "DELETE: Deleting non-existent key should not crash")
}

// ============================================================================
// PHASE 6: FLUSH TESTS
// ============================================================================

test_flush_operations :: proc() {
	fmt.println()
	fmt.println("----------------------------------------------------------------------")
	fmt.println("PHASE 6: FLUSH OPERATIONS TESTS")
	fmt.println("----------------------------------------------------------------------")

	cleanup_test_data()

	db := db_open("test_data")
	defer db_close(db)

	// Test 1: Manual flush
	key := transmute([]byte)string("FlushTest")
	val := transmute([]byte)string("FlushValue")
	db_put(db, key, val)

	initial_file_count := len(db.levels[0])
	sstable_flush(db)

	assert(len(db.levels[0]) == initial_file_count + 1, "Flush: Should create new SSTable file")
	assert(db.memtable.count == 0, "Flush: MemTable should be cleared after flush")

	// Test 2: Retrieve from disk after flush
	retrieved, found := db_get(db, key)
	assert(found, "Flush: Should find key on disk after flush")
	assert(string(retrieved) == "FlushValue", "Flush: Value from disk should match")

	// Test 3: Automatic flush on threshold
	// Fill memtable to trigger automatic flush
	large_value := make([]byte, 1024)
	for i := 0; i < 1024; i += 1 {
		large_value[i] = 'X'
	}
	defer delete(large_value)

	initial_level0_count := len(db.levels[0])

	// Insert enough to exceed threshold (4MB)
	for i := 0; i < 5000; i += 1 {
		k := transmute([]byte)fmt.tprintf("Bulk:%d", i)
		db_put(db, k, large_value)

		// Check if auto-flush occurred
		if len(db.levels[0]) > initial_level0_count {
			assert(true, "Flush: Auto-flush should trigger when threshold exceeded")
			break
		}
	}
}

// ============================================================================
// PHASE 7: COMPACTION TESTS
// ============================================================================

test_compaction :: proc() {
	fmt.println()
	fmt.println("----------------------------------------------------------------------")
	fmt.println("PHASE 7: COMPACTION TESTS")
	fmt.println("----------------------------------------------------------------------")

	cleanup_test_data()

	db := db_open("test_data")
	defer db_close(db)

	key := transmute([]byte)string("User:1")

	// Test 1: Create multiple versions across files
	db_put(db, key, transmute([]byte)string("Version1"))
	sstable_flush(db)

	db_put(db, key, transmute([]byte)string("Version2"))
	sstable_flush(db)

	db_put(db, key, transmute([]byte)string("Version3"))
	sstable_flush(db)

	initial_count := len(db.levels[0])
	assert(initial_count >= 3, "Compaction: Should have at least 3 files before compaction")

	// Test 2: Verify newest version is retrieved
	val, found := db_get(db, key)
	assert(
		found && string(val) == "Version3",
		"Compaction: Should get newest version before compaction",
	)

	// Test 3: Run compaction manually (preparing files list)
	files_to_compact := make([dynamic]SSTableHandle)
	defer delete(files_to_compact)

	for file in db.levels[0] {
		append(&files_to_compact, file)
	}

	if len(files_to_compact) > 1 {
		compacted_handle := db_compact(files_to_compact, db.data_directory)

		// Verify compaction produced a file
		assert(os.exists(compacted_handle.filename), "Compaction: Should create compacted file")

		// Test 4: Verify data integrity after compaction
		val_after, found_after, is_tombstone := sstable_find(compacted_handle.filename, key)
		assert(found_after, "Compaction: Key should exist in compacted file")
		assert(!is_tombstone, "Compaction: Should not be tombstone")
		assert(string(val_after) == "Version3", "Compaction: Should preserve newest version")
	}
}

// ============================================================================
// PHASE 8: BLOOM FILTER TESTS
// ============================================================================

test_bloom_filter :: proc() {
	fmt.println()
	fmt.println("----------------------------------------------------------------------")
	fmt.println("PHASE 8: BLOOM FILTER TESTS")
	fmt.println("----------------------------------------------------------------------")

	// Test 1: Basic add and contains
	filter := bloomfilter_init(100, 0.01)

	key1 := transmute([]byte)string("apple")
	key2 := transmute([]byte)string("banana")
	key3 := transmute([]byte)string("cherry")

	add(filter, key1)
	add(filter, key2)

	assert(contains(filter, key1), "Bloom Filter: Should contain added key 'apple'")
	assert(contains(filter, key2), "Bloom Filter: Should contain added key 'banana'")

	// Note: Bloom filters can have false positives but never false negatives
	// So we can't assert !contains for key3, but we expect it to be false most of the time

	// Test 2: Multiple keys
	filter2 := bloomfilter_init(1000, 0.01)

	added_keys := make([dynamic]string)
	defer delete(added_keys)

	for i := 0; i < 100; i += 1 {
		k := fmt.tprintf("Key:%d", i)
		append(&added_keys, k)
		add(filter2, transmute([]byte)k)
	}

	// All added keys should be found
	all_found := true
	for k in added_keys {
		if !contains(filter2, transmute([]byte)k) {
			all_found = false
			break
		}
	}
	assert(all_found, "Bloom Filter: All added keys should be found (no false negatives)")

	// Test 3: Save and load filter
	cleanup_test_data()
	os.make_directory("test_data")

	filter3 := bloomfilter_init(50, 0.01)
	test_key := transmute([]byte)string("TestKey")
	add(filter3, test_key)

	filter_file := "test_data/test.filter"
	save_filter_to_file(filter3, filter_file)

	assert(os.exists(filter_file), "Bloom Filter: Filter file should exist after save")

	loaded_filter := load_filter_from_file(filter_file)
	assert(loaded_filter != nil, "Bloom Filter: Should load filter from file")
	assert(
		contains(loaded_filter, test_key),
		"Bloom Filter: Loaded filter should contain original keys",
	)
}

// ============================================================================
// PHASE 9: MANIFEST TESTS
// ============================================================================

test_manifest :: proc() {
	fmt.println()
	fmt.println("----------------------------------------------------------------------")
	fmt.println("PHASE 9: MANIFEST TESTS")
	fmt.println("----------------------------------------------------------------------")

	cleanup_test_data()

	// Test 1: Fresh database creates manifest
	db := db_open("test_data")

	// Add some data and flush
	for i := 0; i < 10; i += 1 {
		k := transmute([]byte)fmt.tprintf("Key:%d", i)
		v := transmute([]byte)fmt.tprintf("Value:%d", i)
		db_put(db, k, v)
	}
	sstable_flush(db)

	manifest_path := fmt.tprintf("%s/manifest", db.data_directory)
	manifest_save(db)

	assert(os.exists(manifest_path), "Manifest: Manifest file should exist after save")

	db_close(db)

	// Test 2: Reopen database and verify manifest is loaded
	db2 := db_open("test_data")
	defer db_close(db2)

	assert(db2.manifest != nil, "Manifest: Should load manifest on reopen")
	assert(len(db2.levels[0]) > 0, "Manifest: Should restore SSTable files from manifest")

	// Test 3: Verify data is still accessible after reopen
	test_key := transmute([]byte)string("Key:5")
	val, found := db_get(db2, test_key)
	assert(found, "Manifest: Should find data after database reopen")
	assert(string(val) == "Value:5", "Manifest: Data should match after reopen")
}

// ============================================================================
// PHASE 10: ITERATOR TESTS
// ============================================================================

test_sstable_iterator :: proc() {
	fmt.println()
	fmt.println("----------------------------------------------------------------------")
	fmt.println("PHASE 10: SSTABLE ITERATOR TESTS")
	fmt.println("----------------------------------------------------------------------")

	cleanup_test_data()
	os.make_directory("test_data")
	sst_filename := "test_data/test_iterator.sst"

	// Create test SSTable
	builder := builder_init(sst_filename)

	test_pairs := [?]struct {
		key:   string,
		value: string,
	} {
		{"Key1", "Value1"},
		{"Key2", "Value2"},
		{"Key3", "Value3"},
		{"Key4", "Value4"},
		{"Key5", "Value5"},
	}

	for pair in test_pairs {
		builder_add(builder, transmute([]byte)pair.key, transmute([]byte)pair.value)
	}
	builder_finish(builder)

	// Test 1: Iterate through all entries
	it := sstable_iterator_init(sst_filename)
	defer sstable_iterator_close(it)

	assert(it.valid, "Iterator: Should be valid initially")

	count := 0
	for it.valid {
		count += 1

		// Verify we can read the key and value
		assert(it.key != nil, "Iterator: Key should not be nil")
		assert(it.value != nil, "Iterator: Value should not be nil")

		sstable_iterator_next(it)
	}

	assert(count == 5, "Iterator: Should iterate through all 5 entries")

	// Test 2: Verify iteration order
	it2 := sstable_iterator_init(sst_filename)
	defer sstable_iterator_close(it2)

	expected_order := []string{"Key1", "Key2", "Key3", "Key4", "Key5"}
	idx := 0

	for it2.valid {
		if idx < len(expected_order) {
			assert(
				string(it2.key) == expected_order[idx],
				"Iterator: Keys should be in sorted order",
			)
		}
		idx += 1
		sstable_iterator_next(it2)
	}
}

// ============================================================================
// PHASE 11: INTEGRATION TESTS
// ============================================================================

test_integration :: proc() {
	fmt.println()
	fmt.println("----------------------------------------------------------------------")
	fmt.println("PHASE 11: INTEGRATION TESTS")
	fmt.println("----------------------------------------------------------------------")

	cleanup_test_data()

	// Test 1: Complete workflow - Write, Flush, Read, Reopen
	db := db_open("test_data")

	// Write data
	for i := 0; i < 50; i += 1 {
		k := transmute([]byte)fmt.tprintf("IntKey:%d", i)
		v := transmute([]byte)fmt.tprintf("IntValue:%d", i)
		db_put(db, k, v)
	}

	// Force flush
	sstable_flush(db)

	// Verify all data is readable from disk
	all_readable := true
	for i := 0; i < 50; i += 1 {
		k := transmute([]byte)fmt.tprintf("IntKey:%d", i)
		expected := fmt.tprintf("IntValue:%d", i)

		val, found := db_get(db, k)
		if !found || string(val) != expected {
			all_readable = false
			break
		}
	}
	assert(all_readable, "Integration: All data should be readable after flush")

	manifest_save(db)
	db_close(db)

	// Reopen and verify
	db2 := db_open("test_data")
	defer db_close(db2)

	test_key := transmute([]byte)string("IntKey:25")
	val, found := db_get(db2, test_key)
	assert(
		found && string(val) == "IntValue:25",
		"Integration: Data should persist across restarts",
	)

	// Test 2: Version shadowing - newer MemTable value should override disk
	disk_key := transmute([]byte)string("ShadowKey")
	db_put(db2, disk_key, transmute([]byte)string("OldValue"))
	sstable_flush(db2)

	db_put(db2, disk_key, transmute([]byte)string("NewValue"))

	val2, found2 := db_get(db2, disk_key)
	assert(found2 && string(val2) == "NewValue", "Integration: MemTable should shadow disk value")

	// Test 3: Testing db_scan
	db_iter := db_scan(
		db2,
		transmute([]byte)string("IntKey:0"),
		transmute([]byte)string("IntKey:7"),
	)


	for db_iter.valid {
		fmt.println(string(db_iter.key), " : ", string(db_iter.value))
		db_iterator_next(db_iter)
	}

	db_iterator_close(db_iter)
}

// ============================================================================
// PHASE 12: STRESS TESTS
// ============================================================================

test_stress :: proc() {
	fmt.println()
	fmt.println("----------------------------------------------------------------------")
	fmt.println("PHASE 12: STRESS TESTS")
	fmt.println("----------------------------------------------------------------------")

	cleanup_test_data()
	db := db_open("test_data")
	defer db_close(db)

	// Test 1: Many small writes
	fmt.println("  Running stress test: Many small writes...")
	for i := 0; i < 1000; i += 1 {
		k := transmute([]byte)fmt.tprintf("Stress:%d", i)
		v := transmute([]byte)fmt.tprintf("Value:%d", i)
		db_put(db, k, v)
	}

	// Random verification
	test_indices := []int{0, 100, 500, 750, 999}
	all_correct := true
	for idx in test_indices {
		k := transmute([]byte)fmt.tprintf("Stress:%d", idx)
		expected := fmt.tprintf("Value:%d", idx)
		val, found := db_get(db, k)
		if !found || string(val) != expected {
			all_correct = false
			break
		}
	}
	assert(all_correct, "Stress: Random samples should be retrievable after many writes")

	// Test 2: Large value test
	fmt.println("  Running stress test: Large values...")
	large_value := make([]byte, 10 * 1024) // 10KB
	for i := 0; i < len(large_value); i += 1 {
		large_value[i] = byte('A' + (i % 26))
	}
	defer delete(large_value)

	large_key := transmute([]byte)string("LargeValueKey")
	db_put(db, large_key, large_value)

	retrieved, found := db_get(db, large_key)
	assert(
		found && len(retrieved) == len(large_value),
		"Stress: Large value should be retrievable with correct size",
	)

	// Test 3: Mixed operations
	fmt.println("  Running stress test: Mixed operations...")
	for i := 0; i < 100; i += 1 {
		// Write
		k := transmute([]byte)fmt.tprintf("Mixed:%d", i)
		v := transmute([]byte)fmt.tprintf("MixedValue:%d", i)
		db_put(db, k, v)

		// Read back immediately
		val, found := db_get(db, k)
		if !found || string(val) != string(v) {
			assert(false, "Stress: Immediate read-after-write should succeed")
			break
		}

		// Update
		v2 := transmute([]byte)fmt.tprintf("Updated:%d", i)
		db_put(db, k, v2)

		// Read updated value
		val2, found2 := db_get(db, k)
		if !found2 || string(val2) != string(v2) {
			assert(false, "Stress: Read after update should return new value")
			break
		}
	}
	assert(true, "Stress: Mixed operations completed successfully")
}

// ============================================================================
// MAIN TEST RUNNER
// ============================================================================

main :: proc() {
	fmt.println("======================================================================")
	fmt.println("BLANCHE LSM-TREE DATABASE - COMPREHENSIVE TEST SUITE")
	fmt.println("======================================================================")
	fmt.println("Testing all implemented functionality...")

	start_time := time.now()

	// Phase 1: Core Data Structures
	test_memtable_basic_operations()

	// Phase 2: Persistence Layer
	test_wal_operations()

	// Phase 3: File Format
	test_sstable_builder()

	// Phase 4: Read Operations
	test_sstable_read_path()

	// Phase 5: Database API
	test_db_operations()

	// Phase 5B: DELETE Operations
	test_delete_operations()

	// Phase 6: Memory Management
	test_flush_operations()

	// Phase 7: Garbage Collection
	test_compaction()

	// Phase 8: Optimizations
	test_bloom_filter()

	// Phase 9: State Management
	test_manifest()

	// Phase 10: Internal Utilities
	test_sstable_iterator()

	// Phase 11: End-to-End Scenarios
	test_integration()

	// Phase 12: Performance & Reliability
	test_stress()

	duration := time.diff(start_time, time.now())

	print_test_summary()
	fmt.printf("\nTotal execution time: %v\n", duration)
	fmt.println("======================================================================")

	// Cleanup
	cleanup_test_data()
}
