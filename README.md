# Blanche

## Project General Idea
Build a key-value store like LevelDB or Rocks DB.
To implement this, instead of using a B-Tree, the goal is to use Log-Structured Merge (LSM) Trees as described in the paper [The Log-Structured Merge-Tree (LSM-Tree)
Patrick O'Neil1, Edward Cheng2
Dieter Gawlick3, Elizabeth O'Neil1
To be published: Acta Informatica](https://www.cs.umb.edu/~poneil/lsmtree.pdf)
