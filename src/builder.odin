package blanche

import "core:encoding/endian"
import "core:fmt"
import "core:hash"
import "core:os"


SSTableBuilder :: struct {
	file:           os.Handle, // the output file
	current_offset: u64,
	index_list:     [dynamic]IndexEntry,
	item_count:     i64,
	block_buffer:   [dynamic]byte,
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
	b.block_buffer = make([dynamic]byte)

	return b

}

block_write :: proc(block: []byte, file: os.Handle) {

	// Write the length of the block to the file
	block_len_buf: [8]byte
	endian.put_u64(block_len_buf[:], .Little, u64(len(block)))
	os.write(file, block_len_buf[:])

	//Calculate the checksum
	checksum := hash.crc32(block)

	// Write entire block to the file
	os.write(file, block)

	// Make checksum bytes and write it to the file
	checksum_byte: [4]byte
	endian.put_u32(checksum_byte[:], .Little, checksum)
	os.write(file, checksum_byte[:])


}

builder_add :: proc(b: ^SSTableBuilder, key, value: []byte) {

	if len(b.block_buffer) == 0 {
		key_copy := make([]byte, len(key))
		copy(key_copy, key)
		append(&b.index_list, IndexEntry{key = key_copy, offset = b.current_offset})
	}

	// Write Data block

	//first we write the key length
	klen_byte: [8]byte
	endian.put_u64(klen_byte[:], endian.Byte_Order.Little, u64(len(key)))
	append(&b.block_buffer, ..klen_byte[:])

	// write the actual key
	append(&b.block_buffer, ..key)

	// write the value length
	vlen_byte: [8]byte
	if value == nil {
		endian.put_u64(vlen_byte[:], endian.Byte_Order.Little, TOMBSTONE)
		append(&b.block_buffer, ..vlen_byte[:])

	} else {
		endian.put_u64(vlen_byte[:], endian.Byte_Order.Little, u64(len(value)))
		append(&b.block_buffer, ..vlen_byte[:])

		// write the actual value
		append(&b.block_buffer, ..value)
	}


	if len(b.block_buffer) >= 4096 {
		block_size_on_disk := u64(len(b.block_buffer)) + 12 // 8 bytes len + 4 bytes checksum

		// write block to disk when 4KiB is reached
		block_write(b.block_buffer[:], b.file)

		// push offet
		b.current_offset += block_size_on_disk

		// clear block buffer for new block
		clear(&b.block_buffer)

	}

	b.item_count += 1


}

builder_finish :: proc(b: ^SSTableBuilder) {

	// Must write to file if the length of the block_buffer is not 0
	if len(b.block_buffer) > 0 {
		block_size_on_disk := u64(len(b.block_buffer)) + 12
		block_write(b.block_buffer[:], b.file)
		b.current_offset += block_size_on_disk
	}


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
