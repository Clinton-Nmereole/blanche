# Blanche

## Project General Idea
Build a key-value store like LevelDB or Rocks DB.
To implement this, instead of using a B-Tree, the goal is to use Log-Structured Merge (LSM) Trees as described in the paper [The Log-Structured Merge-Tree (LSM-Tree)
Patrick O'Neil1, Edward Cheng2
Dieter Gawlick3, Elizabeth O'Neil1
To be published: Acta Informatica](https://www.cs.umb.edu/~poneil/lsmtree.pdf)

## What I am building as Explained by AI
You are building a Key-Value Store, which is the simplest kind of database.

Think of it as a giant, persistent Hash Map that lives on your hard drive.

    Input: You give it a Key ("User:101") and a Value ("{'name': 'Alice'}").

    Output: You give it the Key ("User:101"), and it gives you back the Value.

Popular databases like RocksDB (used by Facebook) and LevelDB (used by Google Chrome) work exactly like the system you are about to build.
The Core Problem: Speed vs. Safety

If you just kept everything in RAM (a normal Hash Map), it would be blazing fast. But if the power goes out, you lose everything.

If you wrote every single change directly to the hard drive immediately, it would be safe. But it would be incredibly slow because hard drives hate random, tiny writes.

The Solution: The architecture you are building, called an LSM Tree (Log-Structured Merge-tree), is the "Goldilocks" solution. It cheats by writing to memory first (for speed) and then batch-writing to disk later (for efficiency).

## Implementation plan
The "Office Desk" Analogy

To understand why every step in your plan exists, imagine you are a clerk working at a very busy filing office.
Phase 1: The MemTable (Your Desk)

    The Problem: People are handing you documents constantly. You can't run to the filing cabinet (the Hard Drive) for every single paper; you'd never get anything done.

    The Solution: You have a stack of papers right on your desk. When a new paper comes in, you just sort it into the stack on your desk.

    In Code: This is your MemTable. It allows "Writes" to be instant because they just go into RAM.

    Why Skip List? It keeps the stack on your desk sorted so you can search it quickly, but it's easier to write than a complex tree.

Phase 2: The WAL (The Carbon Copy)

    The Problem: What if the fire alarm rings (Power Failure) while you have 50 unsorted papers on your desk? They are gone forever.

    The Solution: Before you put a paper on your desk, you quickly scribble a messy carbon copy into a notebook chained to the wall. You don't sort it; you just scribble it. If the building burns down, you can find the notebook and see what was on your desk.

    In Code: This is the WAL (Write Ahead Log). It is an "append-only" file. It is ugly and unsorted, but it guarantees you never lose data if the program crashes.

Phase 3: The SSTable (The Filing Cabinet)

    The Problem: Your desk (RAM) is small. Eventually, it gets full.

    The Solution: When your desk stack gets too high, you pause, staple the whole stack together into a neat folder, walk over to the filing cabinet, and shove it in.

    In Code: This is the SSTable (Sorted String Table). It is an "immutable" (unchangeable) file on the disk. Once you write it, you never touch it again. This is extremely fast because modern disks love writing large chunks of data at once (sequential I/O).

Phase 4: The Read Path (Looking for a File)

    The Problem: Now your boss asks for "Alice's File". Where is it?

    The Solution:

        Check your Desk (MemTable) first. (Maybe she just updated it?)

        If not there, check the newest folder in the cabinet.

        If not there, check the older folders.

    In Code: This is the Get() function. It checks memory, then scans the disk files from newest to oldest.

Phase 5: Compaction (Spring Cleaning)

    The Problem: Over time, your cabinet gets messy. You have 50 different folders. "Alice's File" might be in Folder 1 (old version) and Folder 10 (new version). You are wasting space, and searching 50 folders takes too long.

    The Solution: You stay late one night. You take 5 small folders, merge them into 1 big, perfectly sorted folder, and throw away the duplicates (old versions of Alice).

    In Code: This is Compaction. It keeps the database fast (fewer files to search) and small (removes overwritten/deleted data).

Summary of the Flow

    User says: "Save this."

    WAL: "I wrote it down in the messy log just in case." (Safety)

    MemTable: "I have it here in RAM, sorted and ready." (Speed)

    ...Time Passes, Memory Fills...

    SSTable: "Memory is full! I dumped it all into a permanent file on disk." (Persistence)

    Compaction: "I cleaned up the old files so reading stays fast." (Maintenance)

Does this help clarify why we aren't just writing to a text file? We are building a system that balances speed (MemTable), safety (WAL), and long-term storage (SSTable/Compaction).


### Phase 1: The MemTable & The Skip List

The Goal: In this phase, you are building the "short-term memory" of your database. When a user saves data, it lands here first.

You have two requirements for this memory:

    Fast Writes: We can't shift megabytes of memory around every time we add a key.

    Sorted Order: The data must be sorted alphabetically by key. If it's sorted now, we can write it to disk sequentially later (which is fast).

To achieve both without going insane writing a complex Balanced Binary Tree (like a Red-Black Tree), we use a Skip List.
What is a Skip List?

Imagine a standard Linked List. To find the number "90", you have to start at the beginning and check every single node: 1, 5, 10... all the way to 90. That is O(n) (slow).

A Skip List adds "express lanes" on top of the list.

    Level 0: Stops at every node (The slow lane).

    Level 1: Skips a few nodes.

    Level 2: Skips even more.

    Level 3: The super express lane (jumps halfway across the list).

How Search Works: You start at the top level. You go as far right as you can without passing your target. Then you drop down a level and repeat. It’s like searching a sorted array with Binary Search, but for a Linked List. This gives you O(logn) speed for both Reads and Writes.
Why is this important?

    Sorted Data: The Skip List keeps keys sorted automatically. When the MemTable is full, you can just iterate from start to finish and write a perfectly sorted file to disk.

    Simplicity: Implementing a Red-Black tree involves complex "node rotations" to keep the tree balanced. A Skip List uses randomness (coin flips) to stay balanced. It is much easier to write code for.

#### Here is the breakdown of the logic behind every major part of the MemTable struct.
1. The update Array (The Most Critical Concept)

In memtable_put, you see this variable: update: [MAX_LEVEL]^Node.

The Idea: When you insert a node into a Linked List, you need access to the node before the spot where you want to insert.

    Standard List: A -> C. To insert B, you need a pointer to A.

    Skip List: You are inserting B at multiple levels simultaneously. You need pointers to the "node before" at every single level.

The update array is your Breadcrumb Trail. As you drop down from Level 12 to Level 0 searching for the spot, you save a pointer to the "last node you visited" at each level.

Why? Because when you finally create your new node, you have to stitch it into the list at Level 0, Level 1, Level 2, etc. The update array tells you who your neighbor is on the left side at every height.
2. memtable_put (The Insertion Logic)

This function does three distinct jobs:
Job A: The Descent (Finding the spot)
Code snippet

for i := MAX_LEVEL - 1; i >= 0; i -= 1 {
    // Look ahead. If next neighbor is smaller than us, move there.
    for current.next[i] != nil && compare_keys(current.next[i].key, key) < 0 {
        current = current.next[i]
    }
    // STOP! The next node is either bigger than us, or nil.
    // So 'current' is the node immediately to our LEFT at this level.
    update[i] = current 
}

    The Idea: We act like a car looking for a parking spot. We drive fast (Level 12). We see the next spot has a Key "Zeus". We are "Apple". "Zeus" is too big. We stop. We mark this spot in our update array. Then we slow down (drop a level) and look again.

    Result: By the time the loop finishes, update[0] holds the node right before us at the bottom. update[1] holds the node right before us at level 1, etc.

Job B: The Creation (Allocating)
Code snippet

lvl := random_level() // Flip coin. Say we get Level 2.
new_node := new(Node, mt.allocator)

    The Idea: We create the new node in memory. We decided it will be 2 stories tall.

Job C: The Stitching (Linking pointers)

This is where the magic happens. We have to splice this new node into the list at every level it exists on.
Code snippet

for i := 0; i < lvl; i += 1 {
    // 1. My new node points to what the previous node pointed to.
    new_node.next[i] = update[i].next[i]
    
    // 2. The previous node now points to ME.
    update[i].next[i] = new_node
}

Visualizing the Stitch: Imagine Level 1 looked like this: A ---------> C We want to insert B.

    update[1] is A.

    new_node is B.

    B points to whatever A was pointing to (C). Result: B -> C.

    A changes to point to B. Result: A -> B.

    Final Chain: A -> B -> C.

3. memtable_get (The Read Logic)

This is a simplified version of put.

The Idea: We don't need the update array because we aren't changing anything. We just need to find the target.

    Start at the top.

    Slide Right as far as possible without going past the key.

    Drop Down if the next neighbor is too big.

    Repeat until Level 0.

The Crucial Check:
Code snippet

current = current.next[0] // Move one step forward on the bottom level
if current != nil && compare_keys(current.key, key) == 0 {
    return current.value, true // Found match
}

    Why? The loop ensures we stop at the node strictly before or at the target. Once we hit the bottom, we take one step forward on the "Local Track" (Level 0) to check if the very next node is the one we want.

4. memtable_init (The Sentinel)
Code snippet

mt.head = new(Node, mt.allocator)
mt.head.level = MAX_LEVEL

The Idea: A common bug in Linked Lists is handling the "Empty List" or "Insert at Start" edge cases.

    If the list is empty, head is nil. You have to write if head == nil checks everywhere.

    The Solution: Create a Dummy Head (Sentinel Node).

        It has no key/value.

        It is always the tallest tower (Level 12).

        The list is never empty; it always contains at least the Head.

        Your first real data node is always head.next[0].

        Benefit: You never have to check for nil logic when starting a search. You always start at head.

5. mem.Arena (The Memory Strategy)

The Idea: mt.arena and mt.allocator.

If we used the standard system allocator (malloc in C, or new in Odin):

    Every node is scattered randomly in RAM (bad for CPU cache).

    When we flush to disk and clear memory, we have to loop through 100,000 nodes and free() them one by one. This is slow.

The Arena Solution:

    We grab one giant 4MB block of contiguous RAM at the start.

    When we make a Node, we just take the next few bytes of that block.

    The Wipe: When we want to clear the MemTable, we simply say arena.offset = 0. We reset the whole thing instantly without traversing the list.

Summary

    Put: Search down, leave breadcrumbs (update array), stitch the new node into the breadcrumbs.

    Get: Search down, check the immediate neighbor at the bottom.

    Head: A permanent dummy node so we never deal with "empty list" logic.

    Arena: A bulk memory grab for speed and instant deletion.
 

## Phase 2: The Write-Ahead Log (WAL)

The Problem: Right now, your database is 100% in RAM (The MemTable). If you trip over the power cord, or if the program crashes (Segfault), every single "Zebra" you inserted is gone forever.

The Solution: The Write-Ahead Log (WAL) is a "dumb", append-only file that lives on the hard drive. Before we touch the MemTable (RAM), we append the data to this file (Disk).

    Rule: The user does not get a "Success" message until the data is safely in the WAL file.

    Result: If the power goes out, we reboot, read the WAL from start to finish, and "replay" every action to rebuild the MemTable.

The "Receipt Book" Analogy

Imagine you run a store (The Database).

    MemTable: This is the cash in your register. It changes fast. If the store burns down, the cash melts.

    WAL: This is the carbon-copy receipt book. Every time you take cash, you first scribble the transaction on the receipt paper.

        You never erase a line.

        You never go back and edit a line.

        You just write the next line at the bottom.

If the store burns down, you grab the receipt book. You can calculate exactly how much money you should have had.
The Data Format (Binary Protocol)

We cannot just write text like Key:Value to the file.

    Problem: What if the Value contains a colon? Or a newline? The file parser will break.

    Solution: We use Length-Prefixed Binary.

For every entry, we write exactly 4 distinct chunks of data packed together:

    Key Length (4 bytes, Little Endian integer)

    Value Length (4 bytes, Little Endian integer)

    Key Data (The actual bytes)

    Value Data (The actual bytes)

Example: Key: "Cat" (3 bytes), Value: "Meow" (4 bytes).

The file on disk will look like this hexadecimal stream:
Plaintext

[03 00 00 00] [04 00 00 00] [43 61 74] [4D 65 6F 77]
^             ^             ^          ^
Key Len (3)   Val Len (4)   "Cat"      "Meow"


