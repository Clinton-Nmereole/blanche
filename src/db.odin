package blanche

import "core:bufio"
import "core:bytes"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:sort"
import "core:strconv"
import "core:strings"

MB :: mem.Megabyte
KiB :: mem.Kilobyte

MEM_TABLE_MAX_SIZE: int : 4 * MB
BLOCK_SIZE: int : 4 * KiB
