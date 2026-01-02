package blanche
import "core:mem"


MB :: mem.Megabyte
KiB :: mem.Kilobyte
MAX_LEVEL :: 12
BLOCK_SIZE :: 4 * KiB
BLOCK_CACHE_SIZE :: 4 * MB

SPARSE_FACTOR :: 100
TOMBSTONE :: max(u64)
