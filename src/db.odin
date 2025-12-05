package blanche

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

DB :: struct {
	memtable:       ^Memtable,
	wal:            ^WAL,
	data_directory: string,
}

// CONSTANT: When do we freeze and flush? (4MB)
MEMTABLE_THRESHOLD :: 4 * 1024 * 1024

db_open :: proc(dir: string) -> ^DB {

}
