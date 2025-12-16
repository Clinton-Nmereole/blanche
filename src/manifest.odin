package blanche

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

FileMetaData :: struct {
	level:    int,
	filename: string,
	firstkey: []byte,
	lastkey:  []byte,
}

Manifest :: struct {
	filename: string,
	files:    [dynamic]FileMetaData,
}


// This saves a manifest to file
manifest_save :: proc(m: ^Manifest) {
	// 1. Write to a TEMP file first
	temp_filename := fmt.tprintf("%s.tmp", m.filename)

	// Open a file to save the manifest to
	manifest_file, err := os.open(temp_filename, os.O_RDWR | os.O_CREATE | os.O_TRUNC, 0o644)
	if err != os.ERROR_NONE {
		fmt.println("Failed to open/create temporary manifest file")
		return
	}
	defer os.close(manifest_file)


	for file in m.files {
		// open the file

		// Get the file level and write it to the manifest file
		level_buf: [8]byte
		endian.put_u64(level_buf[:], endian.Byte_Order.Little, u64(file.level))
		os.write(manifest_file, level_buf[:])

		// Get the length of the filename and write it 
		len_filename_buf: [8]byte
		endian.put_u64(len_filename_buf[:], endian.Byte_Order.Little, u64(len(file.filename)))
		os.write(manifest_file, len_filename_buf[:])

		// Get the file name and write it to the manifest
		os.write(manifest_file, transmute([]byte)file.filename)

		// Get the length of the first/smallest key and write it
		small_klen_buf: [8]byte
		endian.put_u64(small_klen_buf[:], endian.Byte_Order.Little, u64(len(file.firstkey)))
		os.write(manifest_file, small_klen_buf[:])

		// Get the actual smallest key and write it
		os.write(manifest_file, file.firstkey)


		// Get the length of the last/largest key and write it
		large_klen_buf: [8]byte
		endian.put_u64(large_klen_buf[:], endian.Byte_Order.Little, u64(len(file.lastkey)))
		os.write(manifest_file, large_klen_buf[:])


		// Write the actual largest key
		os.write(manifest_file, file.lastkey)


	}

	// Force to write to disk to ensure data is safe
	os.flush(manifest_file)

	//The Atomic Swap
	// If we get here, the temp file is 100% valid.
	// This rename overwrites the old manifest instantly.
	os.rename(temp_filename, m.filename)

}

// This reads from a file and returns a pointer to a Manifest struct
manifest_load :: proc(filename: string) -> ^Manifest {

	m := new(Manifest)
	m.filename = filename
	file_list := make([dynamic]FileMetaData)

	file, err := os.open(filename, os.O_RDONLY, 0o644)
	if err != os.ERROR_NONE {
		fmt.println("Could not read the file: ", filename)
		return nil
	}
	defer os.close(file)

	// infinite loop to read the entire file
	for {
		// get the level
		level_buf: [8]byte
		bytes_read, _ := os.read(file, level_buf[:])
		if bytes_read == 0 {break}
		if bytes_read < 8 {
			fmt.println("File is corrupted.")
			return nil
		}
		level, lvl_err := endian.get_u64(level_buf[:], endian.Byte_Order.Little)
		if !lvl_err {
			fmt.println("Could not read from file")
			return nil
		}

		// read the filename length
		filename_len_buf: [8]byte
		bytes_read, _ = os.read(file, filename_len_buf[:])
		if bytes_read == 0 {break}
		if bytes_read < 8 {
			fmt.println("File is corrupted.")
			return nil
		}

		filename_len, _ := endian.get_u64(filename_len_buf[:], endian.Byte_Order.Little)

		// read the filename
		filename := make([]byte, filename_len)
		bytes_read, _ = os.read(file, filename)
		if bytes_read < int(filename_len) {
			fmt.println("File is corrupted.")
			return nil
		}

		// read the length of the first key
		klen_buf: [8]byte
		os.read(file, klen_buf[:])
		klen, _ := endian.get_u64(klen_buf[:], endian.Byte_Order.Little)

		// read the first key
		small_key := make([]byte, klen)
		bytes_read, _ = os.read(file, small_key)
		if bytes_read < int(klen) {
			fmt.println("File is corrupted.")
			return nil

		}

		//read the length of the last key
		klen_buf2: [8]byte
		os.read(file, klen_buf2[:])
		klen2, _ := endian.get_u64(klen_buf2[:], endian.Byte_Order.Little)

		large_key := make([]byte, klen2)
		bytes_read, _ = os.read(file, large_key)
		if bytes_read < int(klen2) {
			fmt.println("File is corrupted.")
			return nil
		}

		append(
			&file_list,
			FileMetaData {
				level = int(level),
				filename = string(filename),
				firstkey = small_key,
				lastkey = large_key,
			},
		)


	}
	m.files = file_list
	return m


}
