# Blanche LSM-Tree - Potential Optimizations & Features

> **Note:** This document only lists features and optimizations that are **NOT** currently implemented. All existing features (MemTable, WAL, SSTables, Compaction, Bloom Filters, Manifest, Multi-level Storage, DELETE/Tombstones) are excluded.

---
## 📊 High-Impact Improvements

### 1. Block Cache (LRU Cache for Hot Data)
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



### 2. Compression (Snappy/LZ4)
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

### 3. Better Error Handling
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

### 4. Statistics & Metrics
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

### 5. Configurable Parameters
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
- ✅ Multi-level storage (leveled compaction)
- ✅ DELETE operations with tombstones
- ✅ Crash recovery from WAL


---

## 📝 Recommendation Priority

**If you want to make it more feature-complete:**
1. **Block Cache** (biggest performance win)

**If you want to make it production-ready:**
1. **Better Error Handling**
2. **Compression** (if you can find Odin libs)


**For polish:**
1. **Statistics/Metrics**
2. **Configurable Parameters**

