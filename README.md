# Blanche

A high-performance Log-Structured Merge (LSM) Tree key-value store implementation in Odin, inspired by production systems like LevelDB and RocksDB.

## What is This?

Blanche is a persistent key-value database that solves a fundamental computer science problem: **how do you build fast, reliable storage that survives crashes?**

The answer lies in the LSM-Tree architecture, which achieves a "Goldilocks balance":
- **Speed** → writes go to RAM first (MemTable)
- **Safety** → changes are logged to disk immediately (Write-Ahead Log)
- **Efficiency** → data is batch-written in large sequential blocks (SSTables)

This design is the foundation of modern databases used by Google (LevelDB), Facebook (RocksDB), and Apache Cassandra.

## Academic Foundation

This implementation follows the architecture described in:

**[The Log-Structured Merge-Tree (LSM-Tree)](https://www.cs.umb.edu/~poneil/lsmtree.pdf)**  
*Patrick O'Neil, Edward Cheng, Dieter Gawlick, Elizabeth O'Neil*  
Published in: Acta Informatica

## Implementation Status

### ✅ Phase 1: MemTable (In-Memory Sorted Buffer)
- **Data Structure:** Skip List with probabilistic balancing
- **Memory Management:** Arena-based allocation for O(1) bulk deallocation
- **Performance:** O(log n) inserts and lookups with sorted iteration
- **Why Skip List?** Simpler than Red-Black trees while maintaining logarithmic performance

### ✅ Phase 2: Write-Ahead Log (Crash Recovery)
- **Format:** Length-prefixed binary protocol for unambiguous parsing
- **Guarantee:** Data hits disk before returning success to the user
- **Recovery:** Automatic replay on restart to rebuild in-memory state

### ✅ Phase 3: SSTable Flushing (Persistent Storage)
- **File Format:** Binary layout with three blocks:
  - **Data Block:** Sorted key-value pairs
  - **Index Block:** Sparse index (every 100th key) for fast lookups
  - **Footer:** Metadata pointer for efficient file navigation
- **Trigger:** Automatic flush when MemTable exceeds 4MB threshold
- **Optimization:** Sequential I/O for maximum disk throughput

### ✅ Phase 4: Read Path (Multi-Level Search)
- **Strategy:** Check newest data first (MemTable → newest SSTable → oldest SSTable)
- **Index Optimization:** Use sparse index to jump directly to relevant data block
- **Bloom Filter Integration:** Skip files that definitely don't contain the key
- **Result:** Sub-millisecond lookups even with data on disk

### ✅ Phase 5: Compaction (Garbage Collection)
- **Algorithm:** K-way merge sort across multiple SSTable files
- **Deduplication:** Keeps only the newest version of each key
- **Space Reclamation:** Removes obsolete data and tombstones
- **Iterator-Based:** Streaming merge for memory efficiency
- **Multi-Level:** Automatic tiered compaction across 7 levels
- **Background Worker:** Continuous compaction triggered by size thresholds

### ✅ Phase 6: Bloom Filters
- **Implementation:** Murmur64a + FNV64a hash functions
- **Integration:** Checked in `db_get` for negative lookup optimization
- **Persistence:** Filters saved alongside SSTables (`.filter` files)
- **Impact:** 10-100x faster queries for non-existent keys
- **False Positive Rate:** ~1% (configurable)

### ✅ Phase 7: Manifest (Database Metadata)
- **Purpose:** Track all SSTable files and their metadata
- **Contents:** Stores `firstkey`, `lastkey`, `filesize`, `level` for each file
- **Persistence:** Saved as binary for easy computer processing and avoiding parsing (downside is it is not human readable)
- **Loading:** Automatic database state restoration on restart
- **Benefits:** Enables efficient range query planning and file management

### ✅ Phase 8: DELETE Operations
- **Implementation:** Tombstone markers (nil values in MemTable, TOMBSTONE constant on disk)
- **Propagation:** Tombstones flow through WAL, MemTable, SSTables
- **Compaction Integration:** Tombstones removed during merge when safe
- **API:** `db_delete(db, key)` marks keys as deleted

### ✅ Phase 9: Range finding
- **Implementation:** Database iterators which give the ability to traverse keys being searched without loading entire data into Memory
- **Purpose:** This is implemented in db_scan when the user wants keys in a specific range. 
- **Benefits:** User wants a range of keys and db_scan gives the user and iterator that returns an iterator. This way we can give the user large amounts of data (example 20GB) without crashing due to out of memory error.

### ✅ Phase 10: Block Caching
- **Implementation:** Implemented CacheKey and Block cache which load 4MB of "hot" data into memory
- **Purpose:** Keep frequently accessed data blocks in RAM to avoid disk I/O
- **Integration:** Check and update cache in `sstable_find` which is subsequently used in `db_get`. It also has the ability to recognize TOMBSTONE values.
- **Impact:**  10-100x speedup for repeated reads



## Technical Highlights

### Why This Matters

**The Core Problem:** Traditional databases face a speed-safety tradeoff:
- Pure RAM storage → blazing fast but data loss on crash
- Direct disk writes → safe but too slow for production use

**The LSM Solution:** This architecture is why your phone can sync thousands of messages instantly, why Google Chrome can cache web data efficiently, and why Facebook can handle billions of writes per second.

### Key Design Decisions

1. **Skip List over B-Tree/RB-Tree**
   - Probabilistic balancing (coin flips) vs. complex rotations
   - Cache-friendly sequential memory layout via arena allocation
   - Naturally sorted for efficient SSTable generation

2. **Immutable SSTables**
   - Write-once files enable aggressive OS page caching
   - Safe concurrent reads without locks
   - Simplifies compaction logic (merge and delete old files)

3. **Sparse Indexing**
   - Store only every Nth key's position
   - Reduces index size by 99%+ while maintaining fast lookups
   - Trade slightly more sequential reads for massive space savings

4. **Binary Protocol**
   - Unambiguous length-prefixed format (no delimiter escaping)
   - Little-endian encoding for modern processor efficiency
   - Zero parsing overhead during recovery

## Project Structure

```
blanche/
├── src/
│   ├── main.odin          # Comprehensive test suite (12 phases, 85+ tests)
│   ├── memtable.odin      # Skip list implementation with arena allocation
│   ├── wal.odin           # Write-Ahead Log with binary encoding & recovery
│   ├── db.odin            # Main database API, flush logic, SSTable I/O
│   ├── compaction.odin    # K-way merge iterator, multi-level compaction
│   ├── builder.odin       # SSTable file builder with sparse indexing
│   ├── bloomfilter.odin   # Probabilistic membership testing
│   ├── manifest.odin      # Database metadata persistence (JSON format)
│   ├── data/              # Database files (.sst, .filter, .log, manifest.json)
│   ├── test_data/         # Test database files
│   └── blanche            # Compiled test executable
│   └── constants.odin     # Shared constants (levels, thresholds, etc.)
├── phase_6_bloom_filters.md  # Historical implementation notes
├── OPTIMIZATIONS.md       # Future enhancement roadmap
└── README.md
```

## Why Odin?

This project leverages Odin's systems programming strengths:

- **Manual Memory Control:** Arena allocators for bulk deallocation (instant MemTable clear)
- **Zero-Cost Abstractions:** Direct binary I/O without runtime overhead
- **Explicit Resource Management:** Clear ownership semantics for file handles
- **C-Level Performance:** Necessary for database-level performance requirements

## Testing

Comprehensive test suite in `main.odin` covering **12 phases with 90+ tests**:

1. **MemTable Tests** - Sorted insertion, updates, deletion, clearing
2. **WAL Tests** - Crash recovery simulation with multi-entry replay
3. **SSTable Builder** - File format validation, sparse indexing
4. **SSTable Read Path** - Multi-file search, edge cases, tombstones
5. **DB Operations** - CRUD operations (Create, Read, Update, Delete)
6. **DELETE Operations** - Tombstone propagation through all layers
7. **Flush Operations** - Automatic/manual flushing, threshold triggers
8. **Compaction** - Multi-file merge, deduplication, version preservation/
    - **Block Caching** - Block caching, faster reads for "hot" keys
9. **Bloom Filters** - False positive rate, save/load persistence
10. **Manifest** - State persistence, database restart scenarios
11. **Iterator** - Sequential SSTable scans, ordering validation
12. **Integration & Stress** - End-to-end workflows, high-volume operations

Run tests: `cd src; odin build . -out:blanche; ./blanche`

## Performance Characteristics

**Write Path:**
- MemTable insert: O(log n) average
- WAL append: O(1) sequential write
- Flush: O(n) single pass

**Read Path:**
- MemTable lookup: O(log n)
- SSTable search: O(log k) index scan + O(1) range scan
  - k = number of sparse index entries

**Compaction:**
- Time: O(n log m) where m = number of files
- Space: O(n) output buffer

## What Makes This Production-Quality Architecture?

1. **Crash Safety:** WAL guarantees no data loss even on power failure
2. **Write Amplification Control:** Background compaction worker with configurable thresholds
3. **Read Optimization:** Sparse index + Bloom filters minimize disk I/O
4. **Memory Efficiency:** Arena allocation prevents fragmentation
5. **Concurrency-Friendly:** Immutable SSTables allow lock-free reads (future: multi-threaded reads)
6. **Complete CRUD:** Full Create, Read, Update, Delete operations
7. **Automatic Management:** Background compaction, manifest persistence, crash recovery

## Current Capabilities

**Supported Operations:**
- `db_put(db, key, value)` - Write or update a key-value pair
- `db_get(db, key)` - Retrieve value for a key (returns nil if not found)
- `db_delete(db, key)` - Mark a key as deleted using tombstones
- `db_open(path)` - Open or create database at specified path
- `db_close(db)` - Gracefully shutdown with manifest save
- `sstable_flush(db)` - Manually trigger MemTable flush to disk

**Automatic Features:**
- Crash recovery via WAL replay
- Auto-flush when MemTable exceeds 4MB
- Background compaction across 7 levels
- Bloom filter generation and persistence
- Manifest updates on structural changes

## Future Enhancements

See `OPTIMIZATIONS.md` for detailed implementation guides. Key missing features:

1. **Compression** - Snappy/LZ4 for 2-5x space savings
2. **Better Error Handling** - Proper error types and propagation
3. **Statistics/Metrics** - Observability (reads/writes per second, cache hit rates)
4. **Configurable Parameters** - Tunable thresholds via options struct

## Learning Resources

- Original LSM-Tree Paper: [O'Neil et al., 1996](https://www.cs.umb.edu/~poneil/lsmtree.pdf)
- LevelDB Implementation: [Google's C++ codebase](https://github.com/google/leveldb)
- "Designing Data-Intensive Applications" by Martin Kleppmann (Chapter 3)

---

**Built with:** Odin Programming Language  
**License:** MIT  
**Status:** Educational implementation with production-quality architecture
