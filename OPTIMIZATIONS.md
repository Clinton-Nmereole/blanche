# Blanche LSM-Tree - Potential Optimizations & Features

> **Note:** This document only lists features and optimizations that are **NOT** currently implemented. All existing features (MemTable, WAL, SSTables, Compaction, Bloom Filters, Manifest, Multi-level Storage, DELETE/Tombstones) are excluded.

---

## 🎯 High-Impact Additions

### 1. Range Queries / Scan Operations
**Status:** ❌ Not Implemented  
**Impact:** **HIGH** - Unlocks major new use cases  
**Effort:** ~4-6 hours

**What it is:**
Query all keys within a range (e.g., "get all keys from 'user:100' to 'user:200'")

**Why it matters:**
- Essential for analytics workloads
- Batch processing operations
- Pagination in web applications
- Time-series data queries

**Implementation approach:**
```odin
// First, define a simple result struct (add to db.odin)
KVPair :: struct {
    key: []byte,
    value: []byte,
}

db_scan :: proc(db: ^DB, start_key, end_key: []byte) -> [dynamic]KVPair {
    // Use a map for O(n) deduplication instead of O(n²)
    seen := make(map[string][]byte)
    defer delete(seen)
    
    // 1. Scan MemTable first (newest data has priority)
    node := db.memtable.head.next[0]
    for node != nil {
        if compare_keys(node.key, start_key) >= 0 && 
           compare_keys(node.key, end_key) <= 0 {
            // Skip tombstones
            if node.value != nil {
                key_str := string(node.key)
                if key_str not_in seen {
                    val_copy := make([]byte, len(node.value))
                    copy(val_copy, node.value)
                    seen[key_str] = val_copy
                }
            }
        }
        node = node.next[0]
    }
    
    // 2. Scan SSTables (filter using manifest metadata)
    for level in db.levels {
        for sstable in level {
            // Skip files outside range using manifest metadata!
            if compare_keys(end_key, sstable.meta.firstkey) < 0 ||
               compare_keys(start_key, sstable.meta.lastkey) > 0 {
                continue
            }
            
            // Scan this file with iterator
            it := sstable_iterator_init(sstable.filename)
            for it.valid {
                if compare_keys(it.key, start_key) >= 0 && 
                   compare_keys(it.key, end_key) <= 0 {
                    // Skip tombstones and already-seen keys
                    if !it.is_tombstone {
                        key_str := string(it.key)
                        if key_str not_in seen {
                            val_copy := make([]byte, len(it.value))
                            copy(val_copy, it.value)
                            seen[key_str] = val_copy
                        }
                    }
                }
                sstable_iterator_next(&it)  // CRITICAL: advance iterator
            }
            sstable_iterator_close(&it)
        }
    }
    
    // 3. Convert map to result array
    results := make([dynamic]KVPair)
    for key_str, value in seen {
        key_copy := make([]byte, len(key_str))
        copy(key_copy, transmute([]byte)key_str)
        append(&results, KVPair{key=key_copy, value=value})
    }
    
    // Sort results by key
slice.sort_by(results[:], proc(a, b: KVPair) -> bool {
    return compare_keys(a.key, b.key) < 0
})
    
    return results
}
```

**Note:** 
- **O(n) deduplication** using a map instead of nested loops
- MemTable values take priority (scanned first, added to map first)
- Must call `sstable_iterator_next(&it)` or the loop will hang
- Returns keys in arbitrary order (not sorted) - add sorting if needed
- Your manifest's `firstkey`/`lastkey` metadata makes file filtering very efficient!

---

### 2. Block Cache (LRU Cache for Hot Data)
**Status:** ❌ Not Implemented  
**Impact:** **MEDIUM-HIGH** - 10-100x speedup for repeated reads  
**Effort:** ~3-4 hours

**What it is:**
Keep frequently accessed data blocks in RAM to avoid disk I/O

**Why it matters:**
- Repeated reads of popular keys (e.g., "hot" user profiles)
- Workloads with temporal locality (accessing recently-read data)
- Reduces disk I/O by caching sparse index blocks

**Implementation approach:**
```odin
BlockCache :: struct {
    cache: map[CacheKey][]byte,  // filename+offset -> data
    lru_list: [dynamic]CacheKey,
    max_size: int,
    current_size: int,
}

CacheKey :: struct {
    filename: string,
    offset: u64,
}

// In sstable_find, check cache before os.read()
```

**Trade-offs:**
- Memory usage increases
- Cache eviction logic adds complexity
- Worth it for read-heavy workloads

---

## 📊 Moderate-Impact Improvements

### 3. Leveled Compaction Strategy
**Status:** ❌ Not Implemented (you have *tiered* compaction)  
**Impact:** **MEDIUM** - Better write amplification  
**Effort:** ~8-12 hours (significant refactor)

**What it is:**
Different compaction strategy used by LevelDB/RocksDB

**Current implementation:** Tiered compaction (merge all files in a level)  
**Leveled compaction:** Each level has non-overlapping files, merge specific files

**Why it matters:**
- Reduces write amplificationfor write-heavy workloads
- More predictable space usage
- Better worst-case performance

**Complexity:** Requires tracking file ranges, overlap detection, more sophisticated compaction triggers.

---

### 4. Compression (Snappy/LZ4)
**Status:** ❌ Not Implemented  
**Impact:** **MEDIUM** - 2-5x space savings  
**Effort:** ~2-3 hours (if using library)

**What it is:**
Compress SSTable data blocks before writing to disk

**Why it matters:**
- Reduces disk usage significantly
- Can improve I/O performance (less data to read)
- Standard in production LSM databases

**Implementation approach:**
```odin
// Using a compression library (would need to find Odin bindings or FFI)
compressed_data := compress(data_block)
os.write(file, compressed_data)

// On read:
compressed := os.read(...)
data := decompress(compressed)
```

**Blocker:** Need to find Odin compression library or write FFI bindings.

---

## 🔧 Quality-of-Life Improvements

### 5. Better Error Handling
**Status:** ⚠️ Partially Implemented (many functions ignore errors)  
**Impact:** **LOW-MEDIUM** - Production readiness  
**Effort:** ~2-3 hours

**What's missing:**
- Many `os.write()` calls don't check return values
- No structured error types
- Silent failures in some paths

**Improvements:**
```odin
Result :: union {
    Success: bool,
    Error: ErrorCode,
}

ErrorCode :: enum {
    IO_Error,
    Corruption,
    NotFound,
    InvalidArgument,
}

db_put :: proc(db: ^DB, key, value: []byte) -> Result {
    // Return errors instead of printing + continuing
}
```

---

### 6. Statistics & Metrics
**Status:** ❌ Not Implemented  
**Impact:** **LOW** - Observability  
**Effort:** ~1-2 hours

**What it is:**
Track operational metrics (reads/sec, cache hit rate, compaction count, etc.)

**Why it matters:**
- Performance debugging
- Capacity planning
- Understanding workload characteristics

**Implementation:**
```odin
DBStats :: struct {
    reads: u64,
    writes: u64,
    deletes: u64,
    cache_hits: u64,
    cache_misses: u64,
    compactions: u64,
    memtable_flushes: u64,
}

db_get_stats :: proc(db: ^DB) -> DBStats {
    return db.stats
}
```

---

### 7. Configurable Parameters
**Status:** ⚠️ Partially done (hardcoded constants)  
**Impact:** **LOW** - Flexibility  
**Effort:** ~1 hour

**What's missing:**
Hardcoded values like `MEMTABLE_THRESHOLD`, `SPARSE_FACTOR`, bloom filter false positive rate

**Improvement:**
```odin
DBOptions :: struct {
    memtable_size: int,        // Default: 4MB
    sparse_index_interval: int, // Default: 100
    bloom_filter_fpr: f64,     // Default: 0.01
    compaction_trigger: int,   // Files before compaction
}

db_open_with_options :: proc(path: string, opts: DBOptions) -> ^DB
```

---

## ❌ Features You Already Have (Do NOT Implement)

These are already in your codebase:
- ✅ MemTable with Skip List
- ✅ Write-Ahead Log (WAL)
- ✅ SSTable format with sparse indexing
- ✅ Read path (MemTable → SSTables)
- ✅ Compaction (K-way merge)
- ✅ Bloom Filters
- ✅ Manifest persistence
- ✅ Multi-level storage (tiered compaction)
- ✅ DELETE operations with tombstones
- ✅ Crash recovery from WAL

---

## 📝 Recommendation Priority

**If you want to make it more feature-complete:**
1. **Range Queries** (biggest missing feature)
2. **Block Cache** (biggest performance win)

**If you want to make it production-ready:**
1. **Better Error Handling**
2. **Compression** (if you can find Odin libs)

**If you want an academic deep-dive:**
1. **Leveled Compaction** (complex but educational)

**For polish:**
1. **Statistics/Metrics**
2. **Configurable Parameters**

Your implementation is already **extremely solid** for an educational/reference LSM-Tree. Range queries would be the most valuable addition to make it feel like a "complete" database.
