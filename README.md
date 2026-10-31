# MiniVSFS

MiniVSFS is a tiny file system you can inspect byte by byte. It comes with three C programs:
**`mkfs_builder`** creates an empty disk image (a single `.img` file that acts like a small
disk), **`mkfs_adder`** copies a file into that image, and **`mkfs_ls`** lists what's inside
it.

It's built for learning how file systems store data. Images can't be mounted; you read them
with `mkfs_ls`, or with a hex viewer such as `xxd` to see the actual bytes.

## Try it in 60 seconds

Build the tools, create an image, and add one of the sample files:

```bash
gcc -O2 -std=c17 -Wall -Wextra mkfs_builder.c -o mkfs_builder
gcc -O2 -std=c17 -Wall -Wextra mkfs_adder.c -o mkfs_adder
gcc -O2 -std=c17 -Wall -Wextra mkfs_ls.c -o mkfs_ls
./mkfs_builder --image out.img --size-kib 180 --inodes 128
./mkfs_adder --input out.img --output out2.img --file file_8.txt
```

You should see:

```
Created out.img: 45 blocks, 128 inodes, 37 data blocks free.
Successfully added file 'file_8.txt' to filesystem.
```

List what's in the new image:

```bash
./mkfs_ls --image out2.img
```

```
out2.img: 45 blocks, 2 of 128 inodes used, 36 data blocks free

INODE  TYPE      SIZE  NAME
    1  dir        192  .
    1  dir        192  ..
    2  file        73  file_8.txt
```

### Explore it in the browser

Open the [MiniVSFS viewer](https://mebmrauf.github.io/MiniVSFS/) and drop in `out2.img`, or open
`viewer.html` from this repo. It shows every block as a map. Click a file to follow it from its
name to its inode to its data, or click any block to see what it holds. Your image stays on your
computer: the page can't send anything over the network.

### See the actual bytes

To see how that listing is stored, look at the raw image. With these settings, the root
directory is in block 7. macOS includes `xxd`, but some Linux systems need it installed first
(on Debian and Ubuntu, the `xxd` package):

```bash
xxd -s $((7*4096)) -l 192 out2.img
```

Each directory entry takes 64 bytes, which is 4 lines of output. There are three entries:
`.`, `..`, and the file you added.

```
00007000: 0100 0000 022e 0000 0000 0000 0000 0000  ................   <- "." (inode 1)
00007010: 0000 0000 0000 0000 0000 0000 0000 0000  ................
00007020: 0000 0000 0000 0000 0000 0000 0000 0000  ................
00007030: 0000 0000 0000 0000 0000 0000 0000 002d  ...............-
00007040: 0100 0000 022e 2e00 0000 0000 0000 0000  ................   <- ".." (inode 1)
00007050: 0000 0000 0000 0000 0000 0000 0000 0000  ................
00007060: 0000 0000 0000 0000 0000 0000 0000 0000  ................
00007070: 0000 0000 0000 0000 0000 0000 0000 0003  ................
00007080: 0200 0000 0166 696c 655f 382e 7478 7400  .....file_8.txt.   <- file_8.txt (inode 2)
00007090: 0000 0000 0000 0000 0000 0000 0000 0000  ................
000070a0: 0000 0000 0000 0000 0000 0000 0000 0000  ................
000070b0: 0000 0000 0000 0000 0000 0000 0000 0034  ...............4
```

In each entry, the first 4 bytes are the inode number, the next byte is the type (`01` = file,
`02` = directory), then comes the name, and the last byte is a checksum.

The file's contents are in the next block:

```bash
xxd -s $((8*4096)) -l 80 out2.img
```

```
00008000: 6e61 7277 6861 6c20 6e6f 7665 6d62 6572  narwhal november
00008010: 2077 616c 7275 7320 7175 6f6b 6b61 206b   walrus quokka k
00008020: 696c 6f20 6472 6167 6f6e 6672 7569 7420  ilo dragonfruit 
00008030: 7175 6f6b 6b61 206c 696d 6120 666f 7874  quokka lima foxt
00008040: 726f 7420 616c 7068 6100 0000 0000 0000  rot alpha.......
```

## How it works

The image is divided into 4096-byte **blocks**, and each part of the file system has a job:

| Part | What it does |
|---|---|
| **Superblock** | Describes the image: its size and where every other part starts. |
| **Inode bitmap** | Records which inodes are in use, one bit per inode. |
| **Data bitmap** | Records which data blocks are in use, one bit per block. |
| **Inode table** | Holds the inodes. An **inode** is a file's record: its size, its timestamps, and which blocks hold its data. It doesn't contain the file's name. |
| **Data region** | Holds file contents and directories. A **directory** is a list of names, each pointing to an inode. |

### What happens when you add a file

Adding `file_8.txt` to the image from the demo takes these steps:

1. `mkfs_adder` checks the root directory to make sure the name isn't already taken.
2. It finds the first free inode in the inode bitmap, which is inode 2, and marks it as used.
3. It finds the first free data block in the data bitmap, which is block 8, and marks it as
   used.
4. It copies the file's contents into block 8.
5. It fills in inode 2 with the file's size and timestamps, and points it to block 8.
6. It adds an entry to the root directory linking the name `file_8.txt` to inode 2.
7. It updates the root directory's inode and saves everything to the output image.

If any check fails, no output image is created. If saving fails partway, for example on a
full disk, the incomplete output image is removed. The input image and the file being added
are never changed, because `--output` must be a different file from both.

## Limits

| Limit | Value |
|---|---|
| Largest file | 48 KiB (12 blocks); larger files are rejected |
| Number of files | One less than `--inodes`, because the root directory uses one inode |
| File name length | 57 characters; longer names are rejected |
| Directories | Root (`/`) only, with no subdirectories |
| Image size | 180–4096 KiB, in multiples of 4 |
| Inode count | 128–512 |

The space for files is smaller than the image size, because the superblock, the bitmaps and
the inode table take up blocks too. For example, a 180 KiB image with 128 inodes has 38 data
blocks (152 KiB), and the root directory uses one of them.

## Usage

All three tools print their options with `--help`. They exit with a non-zero code and an
error message if something goes wrong.

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
- `--output` — filename for the updated image; must be different from `--input` and `--file`
- `--file` — name of a file in the current directory; paths such as `dir/a.txt` are rejected

To add several files, use each output image as the next input. Adding fails if the name
already exists in the image or is too long, the file is missing or too large, or there's no
free inode or data block left.

### List what's in an image

```bash
./mkfs_ls --image out2.img
```

- `--image` — MiniVSFS image to list

`mkfs_ls` only reads the image. It shows how much of the image is used, then each entry in the
root directory. It stops with an error if the image is damaged, for example if its size or
superblock checksum is wrong. It doesn't verify the checksums of individual inodes and
directory entries.

## On-disk format

This section is the reference for reading images byte by byte. All values are little-endian.
For the complete format, see [SPECIFICATION.md](SPECIFICATION.md).

### Layout

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

## Repository contents

| File | Description |
|---|---|
| `mkfs_builder.c` | Image builder implementation |
| `mkfs_adder.c` | File-adder implementation |
| `mkfs_ls.c` | Image-listing implementation |
| `viewer.html` | Browser viewer for images, published at <https://mebmrauf.github.io/MiniVSFS/> |
| `test.sh` | Checks the tools' error handling; run it with `bash test.sh` |
| `SPECIFICATION.md` | Original assignment specification and full format details |
| `file_8.txt`, `file_19.txt`, `file_31.txt`, `file_38.txt` | Sample files for testing `mkfs_adder` |
