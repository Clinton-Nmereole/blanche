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
}

//Initialize Memtable

memtable_init :: proc() -> ^Memtable {
	// Allocate 4Mb of RAM for this table 
	arena_buffer := make([]byte, constants.MB)
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

//TODO:Implement memtable insertion (put)
