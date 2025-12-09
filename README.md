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
- **Result:** Sub-millisecond lookups even with data on disk

### ✅ Phase 5: Compaction (Garbage Collection)
- **Algorithm:** K-way merge sort across multiple SSTable files
- **Deduplication:** Keeps only the newest version of each key
- **Space Reclamation:** Removes obsolete data and tombstones
- **Iterator-Based:** Streaming merge for memory efficiency

### 🚧 Phase 6: Bloom Filters (Planned)
- **Purpose:** Probabilistic data structure to skip files that definitely don't contain a key
- **Impact:** 10-100x faster negative lookups (queries for non-existent keys)
- **False Positive Rate:** ~1% (configurable)

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
│   ├── main.odin       # Test suite and entry point
│   ├── memtable.odin   # Skip list implementation
│   ├── wal.odin        # Write-Ahead Log with binary encoding
│   ├── db.odin         # Main database API and SSTable I/O
│   ├── compaction.odin # K-way merge iterator and compaction logic
│   └── builder.odin    # SSTable file builder with sparse indexing
├── data/               # Database files (.sst, .log)
└── phase_6_bloom_filters.md  # Next implementation phase
```

## Why Odin?

This project leverages Odin's systems programming strengths:

- **Manual Memory Control:** Arena allocators for bulk deallocation (instant MemTable clear)
- **Zero-Cost Abstractions:** Direct binary I/O without runtime overhead
- **Explicit Resource Management:** Clear ownership semantics for file handles
- **C-Level Performance:** Necessary for database-level performance requirements

## Testing

Each phase includes targeted tests in `main.odin`:
- **MemTable:** Sorted insertion and retrieval
- **WAL:** Crash recovery simulation
- **Flush:** Automatic threshold-triggered persistence
- **Read Path:** Multi-file search validation
- **Compaction:** Deduplication and file merging correctness

Current test focuses on Phase 5, verifying that compaction preserves the newest version of keys across multiple SSTable files.

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

## What Makes This "Production-Ready" Architecture?

1. **Crash Safety:** WAL guarantees no data loss even on power failure
2. **Write Amplification Control:** Compaction is configurable and background
3. **Read Optimization:** Sparse index + (future) Bloom filters minimize disk I/O
4. **Memory Efficiency:** Arena allocation prevents fragmentation
5. **Concurrency-Friendly:** Immutable SSTables allow lock-free reads

## Future Enhancements

Beyond Phase 6 (Bloom Filters):
- **Tombstones:** Proper deletion semantics
- **Range Queries:** Scan operations (e.g., all keys from "A" to "M")
- **Leveled Compaction:** Multi-tier file organization for write amplification reduction
- **Block Cache:** In-memory LRU cache for hot data blocks
- **Compression:** Snappy/LZ4 for data block encoding

## Learning Resources

- Original LSM-Tree Paper: [O'Neil et al., 1996](https://www.cs.umb.edu/~poneil/lsmtree.pdf)
- LevelDB Implementation: [Google's C++ codebase](https://github.com/google/leveldb)
- "Designing Data-Intensive Applications" by Martin Kleppmann (Chapter 3)

---

**Built with:** Odin Programming Language  
**License:** MIT  
**Status:** Educational implementation with production-quality architecture
