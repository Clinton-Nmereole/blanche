package blanche

import "../constants"
import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:os"

// This file is for the Write Ahead Log.
// This is to prevent data loss in the event of a failure.
// Every key-value pair entered into the "store" is first
// written to an append file on the secondary storage (Harddisk/SSD)
// when there is a power outage or any other kind of failure
// we go to that append file and read from the file to get all the key-value
// pairs before the failure.


WAL :: struct {
	file:     os.Handle,
	filename: string,
}

// This initializes our Write Ahead Log data structure.
wal_init :: proc(filename: string) -> (^WAL, bool) {
	wal := new(WAL)
	wal.filename = filename

	// open a file with read,write, create and append permissions.
	handle, err := os.open(filename, os.O_RDWR | os.O_CREATE | os.O_APPEND, 0o644)

	if err != os.ERROR_NONE {
		fmt.printf("Error opening WAL: %v\n", err)
		return nil, false
	}
	wal.file = handle
	return wal, true


}

// Append to the file/disk
// So, we can't just write to the file as plain text
// it is possible that the key-value pair might contain
// text that will break the file parser such as colon or new line.
// The solution we are going with is storing data as 4 distinct chuncks of data.
// The first chunck contains 4 bytes and stores the length of the key example: [03 00 00 00]
// tells us that the key is of length 3
// The second chunck contains 4 bytes and store the length of the value, example: [04 00 00 00]
// tell us that the value is of length 4
// The next chunck of bytes will represent the actual value of the key, example: [43 61 74] -> Cat
// The next chunck of bytes (4 bytes due to length of value) hold the actual value, example: [4D 65 6F 77] -> Meow
wal_append :: proc(wal: ^WAL, key, value: []byte) -> bool {
	//We need to create a buffer to store the length of key and value called header

	header: [8]byte // We make a byte array of length 8, the first 4 hold the length of the key and the rest the length of the value

	//encode length of key and value which are integers as bytes to store in the header
	endian.put_u32(header[0:4], endian.Byte_Order.Little, u32(len(key)))
	endian.put_u32(header[4:], endian.Byte_Order.Little, u32(len(value)))

	// Write the header to the file
	_, err1 := os.write(wal.file, header[:])
	if err1 != os.ERROR_NONE {
		fmt.printf("Error appending header to WAL: %v\n", err1)
		return false
	}

	// Write the actual key and value to file
	_, err2 := os.write(wal.file, key)
	if err2 != os.ERROR_NONE {
		fmt.printf("Error appending ke-value to WAL: %v\n", err2)
		return false
	}

	_, err3 := os.write(wal.file, value)
	if err3 != os.ERROR_NONE {
		fmt.printf("Error appending ke-value to WAL: %v\n", err3)
		return false
	}

	os.flush(wal.file)

	return true

}

// Recover from WAL
wal_recover :: proc(wal: ^WAL, mt: ^Memtable) {
	// Read from the start of the file
	// We need to set the starting position at 0
	os.seek(wal.file, 0, os.SEEK_SET)

	// Loop until the end of the file
	for {
		header: [8]byte
		bytes_read, err := os.read(wal.file, header[:])

		//if no bytes are read, exit the loop
		if bytes_read == 0 {break}

		//if we read partial bytes, then the header is corrupted and recovery is not possible
		if bytes_read < 8 {
			fmt.println("The WAL is corrupted, recovery is not possible")
			break // stop loop
		}

		// If the none of the above if statements are true, we know it is okay to read the key-value.
		// First we need to decode the length of the key and value from little endian bytes back to integers.
		key_length, _ := endian.get_u32(header[0:4], endian.Byte_Order.Little)
		value_length, _ := endian.get_u32(header[4:], endian.Byte_Order.Little)

		// Read the key 
		// We allocate a temporary buffer
		key_buffer := make([]byte, key_length)
		defer delete(key_buffer)
		os.read(wal.file, key_buffer)

		// Read the value
		// Same as with key, we allocate a temporary buffer for the read
		value_buffer := make([]byte, value_length)
		defer delete(value_buffer)
		os.read(wal.file, value_buffer)

		//Replay into MemTable
		// This simulates the user typing this data in again.
		memtable_put(mt, key_buffer, value_buffer)

	}

	//Move cursor back to the end of the file so that we append to the end of the file and not write in the middle possibly
	os.seek(wal.file, 0, os.SEEK_END)

}
