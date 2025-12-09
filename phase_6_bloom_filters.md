# Phase 6: Bloom Filters - The "Pro" Polish

## Overview

**Goal:** Eliminate unnecessary disk I/O by adding a probabilistic data structure that can answer the question: "Is this key **definitely not** in this SSTable?"

**The Problem:** Currently, when you call `db_get("User:999")`, your database might open 10 different `.sst` files, read their footers, read their index blocks, and scan their data blocks—only to discover the key doesn't exist in ANY of them. That's a lot of wasted disk I/O.

**The Solution:** A **Bloom Filter** is a compact bit-array that can tell you:
- "This key is **definitely not** here" (100% accurate)
- "This key **might** be here" (could be a false positive)

By checking the Bloom Filter first (which lives in memory or is a tiny read), you can skip entire files instantly.

---

## Theory: What is a Bloom Filter?

### The Core Concept

A Bloom Filter is a bit array of size `m` bits (all initially set to `0`) combined with `k` different hash functions.

**When inserting a key:**
1. Hash the key with `k` different hash functions
2. Each hash gives you a position in the bit array
3. Set all `k` positions to `1`

**When checking if a key exists:**
1. Hash the key with the same `k` hash functions
2. Check if ALL `k` positions in the bit array are `1`
3. If ANY position is `0` → key is **definitely not** in the set
4. If ALL positions are `1` → key **might** be in the set (could be false positive)

### Mathematical Parameters

For optimal performance, you need to choose:
- `m` = size of bit array (in bits)
- `k` = number of hash functions
- `n` = expected number of keys in the SSTable

**Optimal formula:**
```
m = -(n * ln(p)) / (ln(2)^2)
k = (m / n) * ln(2)
```

Where `p` = desired false positive rate (typically 0.01 = 1%)

**Practical values for a 4MB SSTable:**
- Assume ~1KB per key-value pair → ~4000 keys
- For 1% false positive rate:
  - `m ≈ 38,344 bits ≈ 4.7 KB`
  - `k ≈ 7 hash functions`

---

## Implementation Plan

### Step 1: Create the Bloom Filter Data Structure

Create a new file: `src/bloom.odin`

**Struct Definition:**

```odin
package blanche

BloomFilter :: struct {
    bits:       []u8,        // The bit array (stored as bytes)
    num_bits:   u32,         // Total number of bits (m)
    num_hashes: u32,         // Number of hash functions (k)
}
```

**Why `[]u8` instead of `[]bit`?**
- Odin doesn't have a native bit array type
- We use bytes and manipulate individual bits with bitwise operations
- If `num_bits = 38,344`, we need `38,344 / 8 = 4,793` bytes

### Step 2: Implement Bloom Filter Operations

#### 2.1 Initialization

```odin
bloom_init :: proc(num_keys: u32, false_positive_rate: f32) -> ^BloomFilter
```

**Algorithm:**
1. Calculate optimal `m` and `k` using the formulas
2. Allocate byte array: `size_in_bytes = (m + 7) / 8` (ceiling division)
3. Initialize all bits to `0`
4. Return the filter

**Implementation hints:**
- Use `import "core:math"` for `math.ln()` and `math.pow()`
- Store `num_bits` and `num_hashes` for later use
- Round `k` to the nearest integer (but minimum of 1)

#### 2.2 Hash Functions

You need `k` different hash functions. Instead of implementing `k` separate functions, use a technique called **double hashing**:

```odin
bloom_hash :: proc(filter: ^BloomFilter, key: []byte, i: u32) -> u32
```

**Double Hashing Technique:**
```
hash1 = hash_function_1(key)
hash2 = hash_function_2(key)

for i in 0..<k {
    combined_hash = (hash1 + i * hash2) % m
    // This gives you k different positions
}
```

**Recommended hash functions:**
- `hash1`: Use **MurmurHash3** or **FNV-1a** (fast, good distribution)
- `hash2`: Use a different seed for the same hash function

**Implementation of FNV-1a (simple and effective):**
```odin
fnv1a_hash :: proc(data: []byte, seed: u32) -> u32 {
    hash: u32 = 2166136261 ~ seed  // FNV offset basis XOR seed
    for b in data {
        hash = hash ~ u32(b)
        hash *= 16777619  // FNV prime
    }
    return hash
}
```

#### 2.3 Adding Keys

```odin
bloom_add :: proc(filter: ^BloomFilter, key: []byte)
```

**Algorithm:**
1. For `i` in `0..<filter.num_hashes`:
   - Calculate `bit_pos = bloom_hash(filter, key, i) % filter.num_bits`
   - Calculate `byte_index = bit_pos / 8`
   - Calculate `bit_offset = bit_pos % 8`
   - Set the bit: `filter.bits[byte_index] |= (1 << bit_offset)`

#### 2.4 Checking Keys

```odin
bloom_contains :: proc(filter: ^BloomFilter, key: []byte) -> bool
```

**Algorithm:**
1. For `i` in `0..<filter.num_hashes`:
   - Calculate `bit_pos = bloom_hash(filter, key, i) % filter.num_bits`
   - Calculate `byte_index = bit_pos / 8`
   - Calculate `bit_offset = bit_pos % 8`
   - Check if bit is set: `if (filter.bits[byte_index] & (1 << bit_offset)) == 0`
     - If ANY bit is `0`, return `false` (definitely not present)
2. If ALL bits are `1`, return `true` (might be present)

---

### Step 3: Update SSTable File Format

Your current SSTable format:
```
[Data Block] [Index Block] [Footer (8 bytes)]
```

**New format:**
```
[Data Block] [Index Block] [Bloom Filter Block] [Footer (16 bytes)]
```

**New Footer structure:**
```
[Index Offset (8 bytes)] [Bloom Filter Offset (8 bytes)]
```

### Step 4: Modify SSTable Writing (`sstable_write_file`)

**Location:** `db.odin`, function `sstable_write_file`

**Changes needed:**

1. **Create a Bloom Filter during write:**
   ```odin
   // At the start of sstable_write_file
   bloom := bloom_init(estimated_keys, 0.01)  // 1% false positive rate
   defer bloom_destroy(bloom)
   ```

2. **Add each key to the Bloom Filter:**
   ```odin
   // Inside your loop that writes keys
   for current_node != nil {
       bloom_add(bloom, current_node.key)
       // ... rest of your write logic
   }
   ```

3. **Write the Bloom Filter Block (after Index Block):**
   ```odin
   bloom_offset := current_offset
   
   // Write Bloom Filter metadata
   num_bits_bytes: [4]byte
   endian.put_u32(num_bits_bytes[:], endian.Byte_Order.Little, bloom.num_bits)
   os.write(file, num_bits_bytes[:])
   
   num_hashes_bytes: [4]byte
   endian.put_u32(num_hashes_bytes[:], endian.Byte_Order.Little, bloom.num_hashes)
   os.write(file, num_hashes_bytes[:])
   
   // Write the bit array
   os.write(file, bloom.bits)
   ```

4. **Update Footer (now 16 bytes):**
   ```odin
   footer: [16]byte
   endian.put_u64(footer[0:8], endian.Byte_Order.Little, index_start_offset)
   endian.put_u64(footer[8:16], endian.Byte_Order.Little, bloom_offset)
   os.write(file, footer[:])
   ```

---

### Step 5: Modify SSTable Reading (`sstable_find`)

**Location:** `db.odin`, function `sstable_find`

**Changes needed:**

1. **Read the new Footer (16 bytes instead of 8):**
   ```odin
   os.seek(file, -16, os.SEEK_END)  // Changed from -8
   footer_buffer: [16]byte
   os.read(file, footer_buffer[:])
   
   index_offset, _ := endian.get_u64(footer_buffer[0:8], endian.Byte_Order.Little)
   bloom_offset, _ := endian.get_u64(footer_buffer[8:16], endian.Byte_Order.Little)
   ```

2. **Read and reconstruct the Bloom Filter:**
   ```odin
   // Seek to Bloom Filter offset
   os.seek(file, i64(bloom_offset), os.SEEK_SET)
   
   // Read metadata
   num_bits_buf: [4]byte
   os.read(file, num_bits_buf[:])
   num_bits, _ := endian.get_u32(num_bits_buf[:], endian.Byte_Order.Little)
   
   num_hashes_buf: [4]byte
   os.read(file, num_hashes_buf[:])
   num_hashes, _ := endian.get_u32(num_hashes_buf[:], endian.Byte_Order.Little)
   
   // Read bit array
   size_in_bytes := (num_bits + 7) / 8
   bits := make([]u8, size_in_bytes)
   defer delete(bits)
   os.read(file, bits)
   
   // Reconstruct Bloom Filter
   bloom := BloomFilter{
       bits = bits,
       num_bits = num_bits,
       num_hashes = num_hashes,
   }
   ```

3. **Check Bloom Filter before searching:**
   ```odin
   // EARLY EXIT: Check Bloom Filter first
   if !bloom_contains(&bloom, key) {
       // Key is DEFINITELY not in this file
       return nil, false
   }
   
   // Key MIGHT be in this file, proceed with normal search
   // ... rest of your existing search logic
   ```

---

### Step 6: Update Compaction (`db_compact`)

**Location:** `compaction.odin`

**Changes needed:**

The builder needs to:
1. Create a Bloom Filter when starting compaction
2. Add each key to it as you merge
3. Write the Bloom Filter to the new SSTable

**In `builder_init`:**
```odin
SSTableBuilder :: struct {
    file:           os.Handle,
    current_offset: u64,
    index_list:     [dynamic]IndexEntry,
    item_count:     i64,
    bloom:          ^BloomFilter,  // ADD THIS
}

builder_init :: proc(filename: string) -> ^SSTableBuilder {
    // ... existing code ...
    b.bloom = bloom_init(10000, 0.01)  // Estimate for compacted file
    return b
}
```

**In `builder_add`:**
```odin
builder_add :: proc(b: ^SSTableBuilder, key, value: []byte) {
    bloom_add(b.bloom, key)  // ADD THIS
    // ... rest of existing logic
}
```

**In `builder_finish`:**
```odin
builder_finish :: proc(b: ^SSTableBuilder) {
    // Write Index Block
    index_start := b.current_offset
    // ... existing index writing code ...
    
    // Write Bloom Filter Block (NEW)
    bloom_start := b.current_offset
    
    // Write Bloom metadata
    num_bits_bytes: [4]byte
    endian.put_u32(num_bits_bytes[:], endian.Byte_Order.Little, b.bloom.num_bits)
    os.write(b.file, num_bits_bytes[:])
    
    num_hashes_bytes: [4]byte
    endian.put_u32(num_hashes_bytes[:], endian.Byte_Order.Little, b.bloom.num_hashes)
    os.write(b.file, num_hashes_bytes[:])
    
    // Write bit array
    size_in_bytes := (b.bloom.num_bits + 7) / 8
    os.write(b.file, b.bloom.bits[:size_in_bytes])
    
    // Write Footer (16 bytes)
    footer_buf: [16]byte
    endian.put_u64(footer_buf[0:8], endian.Byte_Order.Little, index_start)
    endian.put_u64(footer_buf[8:16], endian.Byte_Order.Little, bloom_start)
    os.write(b.file, footer_buf[:])
    
    // Cleanup
    bloom_destroy(b.bloom)
    // ... rest of existing cleanup
}
```

---

## Testing Strategy

### Test 1: Bloom Filter Accuracy

**Goal:** Verify false positive rate is close to expected (1%)

```odin
bloom := bloom_init(1000, 0.01)

// Add 1000 keys
for i := 0; i < 1000; i++ {
    key := fmt.tprintf("Key:%d", i)
    bloom_add(bloom, transmute([]byte)key)
}

// Test: All added keys should return true
for i := 0; i < 1000; i++ {
    key := fmt.tprintf("Key:%d", i)
    if !bloom_contains(bloom, transmute([]byte)key) {
        fmt.println("FAILURE: False negative!")
    }
}

// Test: Check false positive rate with 10,000 non-existent keys
false_positives := 0
for i := 10000; i < 20000; i++ {
    key := fmt.tprintf("Key:%d", i)
    if bloom_contains(bloom, transmute([]byte)key) {
        false_positives++
    }
}

rate := f32(false_positives) / 10000.0
fmt.printf("False positive rate: %.2f%% (Expected: ~1%%)\n", rate * 100)
```

### Test 2: SSTable Integration

**Goal:** Verify Bloom Filter is written and read correctly

```odin
// Write phase
db := db_open("data")
for i := 0; i < 5000; i++ {
    key := fmt.tprintf("User:%d", i)
    db_put(db, transmute([]byte)key, transmute([]byte)"value")
}
sstable_flush(db)

// Read phase
// Test positive case (key exists)
val, found := db_get(db, transmute([]byte)"User:2500")
if !found {
    fmt.println("FAILURE: Existing key not found")
}

// Test negative case (key doesn't exist)
// This should be FAST because Bloom Filter rejects it immediately
val2, found2 := db_get(db, transmute([]byte)"User:99999")
if found2 {
    fmt.println("FAILURE: Non-existent key returned true")
}
```

### Test 3: Performance Benchmark

**Goal:** Measure speedup from Bloom Filters

```odin
// Create 10 SSTable files
for file_num := 0; file_num < 10; file_num++ {
    for i := 0; i < 1000; i++ {
        key := fmt.tprintf("File%d:Key%d", file_num, i)
        db_put(db, transmute([]byte)key, transmute([]byte)"data")
    }
    sstable_flush(db)
}

// Benchmark: Search for non-existent key (worst case)
start_time := time.now()
for i := 0; i < 1000; i++ {
    db_get(db, transmute([]byte)"NonExistent:Key")
}
elapsed := time.since(start_time)

fmt.printf("1000 negative lookups took: %v\n", elapsed)
fmt.println("Expected: Bloom Filters should make this 10-100x faster")
```

---

## Edge Cases to Handle

### 1. Backward Compatibility
**Problem:** Old SSTable files have 8-byte footers, new ones have 16 bytes.

**Solution:** Add version detection:
```odin
// Try reading 16-byte footer first
file_size, _ := os.file_size(file)
os.seek(file, -16, os.SEEK_END)
footer_buffer: [16]byte
os.read(file, footer_buffer[:])

// Check if bloom_offset is reasonable
bloom_offset := endian.get_u64(footer_buffer[8:16], endian.Byte_Order.Little)
if bloom_offset > u64(file_size) {
    // This is an old file, only has 8-byte footer
    // Fall back to old logic (no Bloom Filter check)
}
```

### 2. Empty SSTables
**Problem:** What if an SSTable has 0 keys? (Shouldn't happen, but defensive coding)

**Solution:**
```odin
if num_keys == 0 {
    // Don't create a Bloom Filter, or create a minimal one
    bloom := bloom_init(1, 0.01)
}
```

### 3. Memory Management
**Problem:** Bloom Filters allocate memory that needs cleanup.

**Solution:**
```odin
bloom_destroy :: proc(bloom: ^BloomFilter) {
    delete(bloom.bits)
    free(bloom)
}

// Always use defer
bloom := bloom_init(1000, 0.01)
defer bloom_destroy(bloom)
```

---

## Performance Impact

**Expected improvements:**
- **Negative lookups:** 10-100x faster (most dramatic)
- **Positive lookups:** Minimal overhead (tiny bit array check)
- **Write performance:** ~5% slower (building Bloom Filter during flush)
- **Disk space:** +0.1-0.5% per SSTable (Bloom Filter is tiny)

**Example:**
- Without Bloom Filter: Searching for non-existent key in 10 files = 10 disk reads
- With Bloom Filter: 0 disk reads (all files rejected by filter)

---

## Summary Checklist

- [ ] Create `bloom.odin` with `BloomFilter` struct
- [ ] Implement `bloom_init()` with optimal sizing
- [ ] Implement hash functions (FNV-1a + double hashing)
- [ ] Implement `bloom_add()` with bit manipulation
- [ ] Implement `bloom_contains()` with early exit
- [ ] Update SSTable footer to 16 bytes
- [ ] Modify `sstable_write_file()` to write Bloom Filter block
- [ ] Modify `sstable_find()` to read and check Bloom Filter
- [ ] Update `builder_*` functions in compaction
- [ ] Add `bloom_destroy()` for cleanup
- [ ] Write Test 1 (accuracy verification)
- [ ] Write Test 2 (SSTable integration)
- [ ] Write Test 3 (performance benchmark)
- [ ] Handle backward compatibility with old files
- [ ] Add memory management safeguards

---

## Next Phase Ideas (Beyond Phase 6)

Once Bloom Filters are working, consider:
- **Phase 7:** Delete operations with tombstones
- **Phase 8:** Range queries (scan from Key A to Key Z)
- **Phase 9:** Multi-level compaction (Level 0, Level 1, etc.)
- **Phase 10:** Block cache (cache frequently accessed data blocks in RAM)
