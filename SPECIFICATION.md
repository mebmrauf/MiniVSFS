# MiniVSFS: A C-based VSFS Image Generator — Full Specification

## 1. Overview

This project implements two C programs for a small, inode-based file system called
**MiniVSFS**:

- **`mkfs_builder`** — creates a raw disk image for MiniVSFS. It takes parameters from
  the command line and emits a byte-exact binary `.img` file.
- **`mkfs_adder`** — takes a raw MiniVSFS file system image and a file to be added to
  that file system. It finds the file in the working directory, adds it to the root
  directory (`/`) of the file system, and saves the result to a new output image.

MiniVSFS is based on VSFS (Very Simple File System) but is fairly minimal: a block-based
structure with a superblock, inode and data bitmaps, an inode table, and data blocks.
Compared to a regular VSFS, MiniVSFS cuts the following corners:

- No indirect pointer mechanism (only direct blocks).
- Only the root (`/`) directory is supported — no subdirectories.
- Only one block each for the inode bitmap and the data bitmap.
- Limited size and inode counts.

## 2. What You'll Build

### 2.1 `mkfs_builder`

```
mkfs_builder \
  --image out.img \
  --size-kib <180..4096> \
  --inodes <128..512>
```

| Flag | Meaning |
|---|---|
| `--image` | Name of the output image |
| `--size-kib` | Total size of the image in kilobytes (must be a multiple of 4) |
| `--inodes` | Number of inodes in the file system |

### 2.2 `mkfs_adder`

```
mkfs_adder \
  --input out.img \
  --output out2.img \
  --file <file>
```

| Flag | Meaning |
|---|---|
| `--input` | Name of the input image |
| `--output` | Name of the output image |
| `--file` | The file to be added to the file system |

**Output:** the updated output binary image with the file added.

## 3. Program Workflow

### 3.1 `mkfs_builder`

1. Parse the command line inputs.
2. Create the file system according to the provided specifications.
3. Save the file system as a binary file with the name specified by the `--image` flag.

### 3.2 `mkfs_adder`

1. Parse the command line inputs.
2. Open the input image as a binary file.
3. Search for the file in the present working directory, and add it to the file system.
4. Update the file system binary image (write it to `--output`).

## 4. MiniVSFS Specifications

- Block size = **4096 bytes**
- Inode size = **128 bytes**
- Total blocks = `size_kib * 1024 / 4096`

### 4.1 Disk model

All on-disk structures are **little endian**. The disk is divided into equally sized
(4096 B) blocks, arranged as:

| Superblock (1 block) | Inode Bitmap (1 block) | Data Bitmap (1 block) | Inode Table | Data |
|---|---|---|---|---|

### 4.2 Superblock

Placed on the first block (block 0) of the image:

| Field | Size (bytes) | Default |
|---|---|---|
| `magic` | 4 | `0x4D565346` |
| `version` | 4 | `1` |
| `block_size` | 4 | `4096` |
| `total_blocks` | 8 | — |
| `inode_count` | 8 | — |
| `inode_bitmap_start` | 8 | — |
| `inode_bitmap_blocks` | 8 | — |
| `data_bitmap_start` | 8 | — |
| `data_bitmap_blocks` | 8 | — |
| `inode_table_start` | 8 | — |
| `inode_table_blocks` | 8 | — |
| `data_region_start` | 8 | — |
| `data_region_blocks` | 8 | — |
| `root_inode` | 8 | `1` |
| `mtime_epoch` | 8 | Build time (Unix epoch) |
| `flags` | 4 | `0` |
| `checksum` | 4 | See §6 (Checksum) |

Skeleton struct: `superblock_t`.

### 4.3 Inodes

128-byte structures:

| Field | Size (bytes) | Default |
|---|---|---|
| `mode` | 2 | See §5.1 (Inode Modes) |
| `links` | 2 | See §5.2 (Links) |
| `uid` | 4 | `0` |
| `gid` | 4 | `0` |
| `size_bytes` | 8 | — |
| `atime` | 8 | Build time (Unix epoch) |
| `mtime` | 8 | Build time (Unix epoch) |
| `ctime` | 8 | Build time (Unix epoch) |
| `direct[12]` | 4 each | — |
| `reserved_0` | 4 | `0` |
| `reserved_1` | 4 | `0` |
| `reserved_2` | 4 | `0` |
| `proj_id` | 4 | Your group ID |
| `uid16_gid16` | 4 | `0` |
| `xattr_ptr` | 8 | `0` |
| `inode_crc` | 8 | See §6 (Checksum) |

Twelve direct blocks are allowed. **Elements inside the `direct` array are absolute data
block numbers** (i.e. the actual block number on disk, not an index relative to the data
region). Skeleton struct: `inode_t`.

**N.B.** Inodes do not have an explicit id/inode-number field — they are referred to by
their index in the inode table. The superblock's `root_inode` field is `1` because
inodes are **1-indexed**: add 1 to an inode's table index to get its inode number. Unused
direct-block slots are simply set to `0`.

#### 5.1 Inode Modes

| Type | Octal mode |
|---|---|
| File | `0100000` |
| Directory | `0040000` |

#### 5.2 Links

`links` counts the number of directories that point to the file/directory:

- The root directory starts with **2 links** (`.` and `..`).
- Every regular file inside root has **1 link**.
- When a new file is added to root, **root's link count increases by 1**, since the new
  entry refers back to root.

### 4.4 Bitmaps (inode and data)

- Bit = `1` means allocated, `0` means free.
- Bit 0 of byte 0 refers to the first object: inode #1 for the inode bitmap, or the first
  data block in the data region for the data bitmap.
- Bitmaps always occupy an entire block (zero-padded tail).

### 4.5 Directory Entry

Each directory entry:

| Field | Size (bytes) | Default |
|---|---|---|
| `inode_no` | 4 | `0` if free |
| `type` | 1 | `1` = file, `2` = dir |
| `name` | 58 | — |
| `checksum` | 1 | See §6 (Checksum) |

Skeleton struct: `dirent64_t`.

### 4.6 File Allocation Policy

- Inodes and data blocks are placed on a **first-fit** basis — the first available slot
  is allotted to the new resource.
- If a file cannot be accommodated within 12 direct blocks, the program must emit a
  warning/error message and reject the operation (no partial writes).

### 4.7 Root Directory

The root directory has a fixed inode number of **1**, with two initial entries: `.` and
`..`, both pointing to itself. It occupies the first data block for its own entries.

## 5. Checksum

Each of the superblock, inode, and directory-entry structures carries a checksum,
computed with the provided helper functions:

```c
superblock_t superblock;
inode_t inode;
dirent64_t dirent;

/* proper configuration of the structures */

superblock_crc_finalize(&superblock);
inode_crc_finalize(&inode);
dirent_checksum_finalize(&dirent);
```

- **Superblock:** `checksum = crc32(superblock_block[0..4091])` — CRC32 over the full
  zero-padded 4096-byte block, excluding the last 4 bytes (the checksum field itself).
  **Important:** `superblock_crc_finalize` hashes `BS - 4` (4092) bytes starting at the
  pointer it's given, so it must be called on a zero-padded, block-sized buffer — never
  directly on the 116-byte `superblock_t` struct, or it will read out of bounds.
- **Inode:** low 4 bytes of `inode_crc` store `crc32(inode[0..119])`; the high 4 bytes
  are `0`.
- **Directory entry:** `checksum` is the XOR of bytes `[0..62]` (covers `inode_no` (4) +
  `type` (1) + `name` (58)).

These helper functions (along with `crc32_init`/`crc32`) are provided in the skeleton and
must not be modified — only called correctly, after all other fields of the structure
have been finalized.

## 6. Time

Use the standard C time library to get the Unix epoch for all timestamp fields:

```c
#include <time.h>
time_t now = time(NULL);
```

## 7. Discussion / Implementation Notes

- The skeleton files will not compile until the required structures and logic are filled
  in accurately.
- Since this involves a lot of binary data, a solid grasp of pointers and typecasting is
  essential for laying out chunks of memory correctly.
- Fields are unsigned integers of 8/16/32/64 bits — use `uint8_t`, `uint16_t`,
  `uint32_t`, `uint64_t` respectively.
- **Error handling is mandatory.** For incompatible starting states (bad CLI args,
  malformed images, missing files, etc.), the programs must fail gracefully with a
  clear message and a non-zero exit code — never crash or segfault.
- Use `hexdump` or `xxd` to inspect and debug the generated `.img` files.