package blanche

import "../constants"
import "core:bufio"
import "core:bytes"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:mem"
import "core:sort"
import "core:strconv"
import "core:strings"


//Define the Node struct which represents a Key-Value Pair
Node :: struct {
	key:   []byte,
	value: []byte,
	// This is a fixed-size array of pointers to the next nodes.
	// next[0] is the bottom link (points to the immediate next node).
	// next[MAX_LEVEL-1] is the highest potential link.
	next:  [constants.MAX_LEVEL]^Node,
	level: int,
}

//Define Memtable itself
Memtable :: struct {
	head:      ^Node, // Marks the start
	arena:     mem.Arena, // The block of memory that we allocate from
	allocator: mem.Allocator, // The interface for the arena
	size:      int, // Approximate size in bytes (To know when to flush Arena)
	count:     int, // How many keys are in the memtable
}

//Initialize Memtable

memtable_init :: proc() -> ^Memtable {
	// Allocate 4Mb of RAM for this table 
	arena_buffer := make([]byte, 6 * constants.MB)
	mt := new(Memtable)
	mem.arena_init(&mt.arena, arena_buffer)
	mt.allocator = mem.arena_allocator(&mt.arena)

	// Create the Dummy Head Node
	// It must be the tallest possible node (MAX_LEVEL) so it can reach everything.
	mt.head = new(Node, mt.allocator)
	mt.head.level = constants.MAX_LEVEL

	return mt
}

// The Helper to Roll the Dice
// When you insert a new key, you flip a coin to decide how tall it is.
random_level :: proc() -> int {
	lvl := 1
	// While we are below the max AND the coin flip is heads (0.5 probability)
	// rand.float32() returns 0.0 to 1.0.
	for lvl < constants.MAX_LEVEL && rand.float32() < 0.5 {
		lvl += 1
	}
	return lvl
}

// Helper: Returns -1 if a < b, 0 if equal, 1 if a > b
compare_keys :: proc(a, b: []byte) -> int {
	return strings.compare(string(a), string(b))
}

// Insert into the memtable
memtable_put :: proc(mt: ^Memtable, key, value: []byte) {
	// update tracks the path that we took
	update: [constants.MAX_LEVEL]^Node
	current := mt.head

	// 1. SEARCH: Start top, go down (The "Drop Down" Logic) 
	for i := constants.MAX_LEVEL - 1; i >= 0; i -= 1 {
		// While the neighbor is smaller than our new key, move forward
		for current.next[i] != nil && compare_keys(current.next[i].key, key) < 0 {
			current = current.next[i]
		}
		// We stopped. That means current.next[i] is either nil OR bigger than us.
		// So 'current' is the node right before us.
		update[i] = current
	}

	// Move to the exact spot on the bottom level
	// This is to help check for duplicates
	current = current.next[0]

	// 2. CHECK DUPLICATE: If key exists, just update value
	if current != nil && compare_keys(current.key, key) == 0 {
		// We cannot just say current.value = value.
		// We must allocate NEW space in the arena for the new value bytes.
		// Note: The old value bytes are now "wasted" space in the arena. 
		// This is normal for LSM trees; we reclaim it when we flush to disk.
		new_value_slice := make([]byte, len(value), mt.allocator)
		copy(new_value_slice, value)
		current.value = new_value_slice
		return
	}

	// 3. CREATE NODE
	lvl := random_level()

	// Instead of pointing to the incoming 'key' pointer,
	// we ask the Arena for fresh bytes and copy the data there.

	new_node := new(Node, mt.allocator)

	//Make copy of key
	new_key := make([]byte, len(key), mt.allocator)
	copy(new_key, key)
	new_node.key = new_key

	// Make copy of value
	new_value := make([]byte, len(value), mt.allocator)
	copy(new_value, value)
	new_node.value = new_value

	new_node.level = lvl

	// 4. STITCH POINTERS
	// If I am Level 3, I need to insert myself into the Local, Express, and Super Express tracks.

	for i := 0; i < lvl; i += 1 {
		new_node.next[i] = update[i].next[i]
		update[i].next[i] = new_node

	}

	// 5. Try and update the size of the memtable
	mt.size += len(key) + len(value) + size_of(Node)
	mt.count += 1


}

// Read from the memtable
memtable_get :: proc(mt: ^Memtable, key: []byte) -> ([]byte, bool) {
	current := mt.head

	// Same search as used in memtable_put(), but there is no need for update because we are not writing any Nodes.
	for i := constants.MAX_LEVEL - 1; i >= 0; i -= 1 {
		// While the neighbor is smaller than our new key, move forward
		for current.next[i] != nil && compare_keys(current.next[i].key, key) < 0 {
			current = current.next[i]
		}
	}

	// The search gets the item right before the item we are looking for
	current = current.next[0]
	if current != nil && compare_keys(current.key, key) == 0 {
		return current.value, true
	}

	return nil, false
}

// --- DEBUG: PRINT ALL ---
// Iterates the "Local Track" (Level 0) to prove it is sorted.
memtable_print :: proc(mt: ^Memtable) {
	fmt.println("--- MEMTABLE DUMP ---")
	node := mt.head.next[0] // Skip the dummy head
	for node != nil {
		fmt.printf(
			"Key: %s | Val: %s | Height: %d\n",
			string(node.key),
			string(node.value),
			node.level,
		)
		node = node.next[0]
	}
	fmt.printf("Memtable Size: %d bytes of %d bytes \n", mt.size, 4 * constants.MB)
	fmt.println("---------------------")
}

// Clear memtable from RAM
memtable_clear :: proc(mt: ^Memtable) {
	mem.arena_free_all(&mt.arena)

	// We wiped the Head node too! We must recreate it.
	mt.head = new(Node, mt.allocator)
	mt.head.level = constants.MAX_LEVEL

	// Reset size counter
	mt.size = 0
	mt.count = 0

}
