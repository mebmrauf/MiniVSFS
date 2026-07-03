# MiniVSFS

MiniVSFS is a small, inode-based file system format (modeled after VSFS) along with two C
programs that create and modify raw disk images for it:

- **`mkfs_builder`** — builds a fresh MiniVSFS image from scratch (superblock, bitmaps,
  inode table, root directory).
- **`mkfs_adder`** — takes an existing MiniVSFS image and a file from the working
  directory, and adds that file into the root (`/`) directory of the image.

Both tools emit byte-exact, little-endian `.img` binary files that can be inspected with
tools like `xxd` or `hexdump`.

## Design

MiniVSFS deliberately cuts a few corners compared to a full VSFS implementation:

- No indirect block pointers — only 12 direct blocks per inode.
- Only the root (`/`) directory is supported; no subdirectories.
- Exactly one block each for the inode bitmap and the data bitmap.
- Fixed, limited ranges for image size and inode count (see below).

### On-disk layout

Each block is 4096 bytes. The image is laid out as:

| Superblock | Inode Bitmap | Data Bitmap | Inode Table | Data Region |
|---|---|---|---|---|
| 1 block | 1 block | 1 block | variable | variable |

### Superblock (block 0)

| Field | Size | Notes |
|---|---|---|
| `magic` | 4 | `0x4D565346` |
| `version` | 4 | `1` |
| `block_size` | 4 | `4096` |
| `total_blocks` | 8 | |
| `inode_count` | 8 | |
| `inode_bitmap_start/blocks` | 8+8 | |
| `data_bitmap_start/blocks` | 8+8 | |
| `inode_table_start/blocks` | 8+8 | |
| `data_region_start/blocks` | 8+8 | |
| `root_inode` | 8 | `1` |
| `mtime_epoch` | 8 | build time |
| `flags` | 4 | `0` |
| `checksum` | 4 | CRC32 over bytes `[0..4091]` of the zero-padded block |

### Inode (128 bytes each)

Fixed-size record with `mode`, `links`, `uid`/`gid`, `size_bytes`, `atime`/`mtime`/`ctime`,
12 direct block pointers (**absolute** block numbers on disk), reserved fields, `proj_id`,
`xattr_ptr`, and a CRC over bytes `[0..119]`.

### Directory entry (64 bytes each)

`inode_no` (4, 0 = free), `type` (1: 1=file, 2=dir), `name` (58 bytes), and an XOR checksum
over bytes `[0..62]`.

### Bitmaps

Bit 0 of byte 0 = the first object (inode #1 for the inode bitmap, first data-region block
for the data bitmap). `1` = allocated, `0` = free. Bitmaps always occupy a full block,
zero-padded at the tail.

### Allocation policy

Inodes and data blocks are allocated **first-fit**. Files that need more than 12 blocks are
rejected with an error rather than accepted partially.

## Build

```bash
gcc -O2 -std=c17 -Wall -Wextra mkfs_builder.c -o mkfs_builder
gcc -O2 -std=c17 -Wall -Wextra mkfs_adder.c  -o mkfs_adder
```

## Usage

### Create a new image

```bash
./mkfs_builder --image out.img --size-kib <180..4096> --inodes <128..512>
```

- `--image` — output image filename
- `--size-kib` — total image size in KiB (multiple of 4, 180–4096)
- `--inodes` — number of inodes (128–512)

The result is a fresh image containing just the root directory (`.` and `..`).

### Add a file to an image

```bash
./mkfs_adder --input out.img --output out2.img --file <file>
```

- `--input` — existing MiniVSFS image
- `--output` — filename for the updated image
- `--file` — file (from the current working directory) to add to root

`mkfs_adder` looks up a free inode and enough free data blocks (first-fit, max 12 direct
blocks), writes the file's contents, adds a directory entry in root, and updates root's
metadata (`links`, `size_bytes`, `mtime`/`ctime`). It exits non-zero on any failure
(duplicate filename, missing file, no free inode/blocks, file too large, etc.) and leaves
the input image untouched.

## Repository contents

| File | Description |
|---|---|
| `mkfs_builder.c` | Image builder implementation |
| `mkfs_adder.c` | File-adder implementation |
| `SPECIFICATION.md` | Full project specification |
| `file_8.txt`, `file_19.txt`, `file_31.txt`, `file_38.txt` | Sample files for testing `mkfs_adder` |
