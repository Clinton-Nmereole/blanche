package blanche

import "core:encoding/endian"
import "core:fmt"
import "core:os"


SSTableBuilder :: struct {
	file:           os.Handle, // the output file
	current_offset: u64,
	index_list:     [dynamic]IndexEntry,
	item_count:     i64,
}

builder_init :: proc(filename: string) -> ^SSTableBuilder {
	b := new(SSTableBuilder)

	// Open with Truncate.
	// "Why Truncate?" If the file exists (maybe from a failed previous run),
	// we want to wipe it and start fresh, not append to garbage.
	f, err := os.open(filename, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)

	if err != os.ERROR_NONE {
		fmt.printf("Error creating builder file: %s\n", filename)
		return nil
	}

	b.file = f
	b.current_offset = 0
	b.index_list = make([dynamic]IndexEntry)
	b.item_count = 0

	return b

}

builder_add :: proc(b: ^SSTableBuilder, key, value: []byte) {

	if b.item_count % SPARSE_FACTOR == 0 {
		key_copy := make([]byte, len(key))
		copy(key_copy, key)
		append(&b.index_list, IndexEntry{key = key_copy, offset = b.current_offset})
	}

	// Write Data block

	//first we write the key length
	klen_byte: [8]byte
	endian.put_u64(klen_byte[:], endian.Byte_Order.Little, u64(len(key)))
	os.write(b.file, klen_byte[:])
	b.current_offset += 8

	// write the actual key
	os.write(b.file, key)
	b.current_offset += u64(len(key))

	// write the value length
	vlen_byte: [8]byte
	endian.put_u64(vlen_byte[:], endian.Byte_Order.Little, u64(len(value)))
	os.write(b.file, vlen_byte[:])
	b.current_offset += 8

	// write the actual value
	os.write(b.file, value)
	b.current_offset += u64(len(value))

	b.item_count += 1


}

builder_finish :: proc(b: ^SSTableBuilder) {
	// Write Index Block

	index_start := b.current_offset

	for entry in b.index_list {
		// write key length
		key_len: [8]byte
		endian.put_u64(key_len[:], endian.Byte_Order.Little, u64(len(entry.key)))
		os.write(b.file, key_len[:])

		// write key
		os.write(b.file, entry.key)

		// write offset
		// since it is an integer (u64 specifically), we need to convert it to bytes
		offset_bytes: [8]byte
		endian.put_u64(offset_bytes[:], endian.Byte_Order.Little, u64(entry.offset))
		os.write(b.file, offset_bytes[:])
		delete(entry.key) //remember that we are making deep copies of key when we initially put it in index_list, this frees that memory.
	}
	delete(b.index_list)

	// Write the footer
	footer_buf: [8]byte
	endian.put_u64(footer_buf[:], endian.Byte_Order.Little, u64(index_start))
	os.write(b.file, footer_buf[:])


	// Flush and close file
	os.flush(b.file)
	os.close(b.file)

	free(b)

}
