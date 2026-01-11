package blanche

import "core:bufio"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

main :: proc() {
	if len(os.args) > 1 && os.args[1] == "test" {
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
		test_block_cache()

		// Phase 9: State Management
		test_manifest()

		// Phase 10: Internal Utilities
		test_sstable_iterator()

		// Phase 11: End-to-End Scenarios
		test_integration()

		// Phase 12: Performance & Reliability
		test_stress()

		// Phase 13: Throughput Benchmark
		test_benchmark_throughput()

		duration := time.diff(start_time, time.now())

		print_test_summary()
		fmt.printf("\nTotal execution time: %v\n", duration)
		fmt.println("======================================================================")

		// Cleanup
		cleanup_test_data()
	} else {
		db := db_open("test_data")
		defer db_close(db)

		reader: bufio.Reader
		bufio.reader_init(&reader, os.stream_from_handle(os.stdin))
		fmt.println("==== BLANCHE Database has been launched ====")

		for {

			fmt.print(">> ")
			input, err := bufio.reader_read_string(&reader, '\n')
			input = strings.trim_space(input)
			input_list := strings.split(input, " ")
			defer delete(input_list)
			if len(input_list) == 0 {
				continue
			}
			if input_list[0] == "exit" {
				fmt.println("==== Exiting BLANCHE Database ====")
				break
			} else if input_list[0] == "SET" {
				if len(input_list) < 3 {
					fmt.println(
						"Insufficient arguments for the SET operation, you need 2 arguments.",
					)
					continue
				} else {
					key := transmute([]byte)input_list[1]
					value := transmute([]byte)input_list[2]
					db_put(db, key, value)
					fmt.printf(
						"The key '%s' and the value '%s' have been added to the database\n",
						key,
						value,
					)
				}

			} else if input_list[0] == "GET" {
				if len(input_list) < 2 {
					fmt.println(
						"Insufficient arguments for the GET operation, you need 1 argument.",
					)
					continue
				} else if len(input_list) > 2 {
					fmt.println(
						"You can only get a single key at a time. To get a range of keys use SCAN command",
					)

				} else {
					key := transmute([]byte)input_list[1]
					found_value, found := db_get(db, key)
					if found {
						fmt.printf(
							"The key '%s' was found in the database and its corresponding value is '%s'\n",
							key,
							found_value,
						)
					} else {
						fmt.printf(
							"The key '%s' does not exist in the database, you can add it with SET command.\n",
							key,
						)
					}

				}
			}

		}

	}

}
