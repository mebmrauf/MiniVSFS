// Build: gcc -O2 -std=c17 -Wall -Wextra mkfs_ls.c -o mkfs_ls
#define _FILE_OFFSET_BITS 64
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <inttypes.h>

#define BS 4096u
#define INODE_SIZE 128u
#define DIRECT_MAX 12
#define MIN_BLOCKS 45u   // 180 KiB, the smallest image mkfs_builder creates
#define MAX_BLOCKS 1024u // 4096 KiB, the largest
#define MIN_INODES 128u
#define MAX_INODES 512u

#pragma pack(push, 1)
typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t block_size;
    uint64_t total_blocks;
    uint64_t inode_count;
    uint64_t inode_bitmap_start;
    uint64_t inode_bitmap_blocks;
    uint64_t data_bitmap_start;
    uint64_t data_bitmap_blocks;
    uint64_t inode_table_start;
    uint64_t inode_table_blocks;
    uint64_t data_region_start;
    uint64_t data_region_blocks;
    uint64_t root_inode;
    uint64_t mtime_epoch;
    uint32_t flags;
    uint32_t checksum;
} superblock_t;
#pragma pack(pop)
_Static_assert(sizeof(superblock_t) == 116, "superblock must fit in one block");

#pragma pack(push,1)
typedef struct {
    uint16_t mode;
    uint16_t links;
    uint32_t uid;
    uint32_t gid;
    uint64_t size_bytes;
    uint64_t atime;
    uint64_t mtime;
    uint64_t ctime;
    uint32_t direct[12];
    uint32_t reserved_0;
    uint32_t reserved_1;
    uint32_t reserved_2;
    uint32_t proj_id;
    uint32_t uid16_gid16;
    uint64_t xattr_ptr;
    uint64_t inode_crc;

} inode_t;
#pragma pack(pop)
_Static_assert(sizeof(inode_t)==INODE_SIZE, "inode size mismatch");

#pragma pack(push,1)
typedef struct {
    uint32_t inode_no;
    uint8_t type;
    char name[58];
    uint8_t checksum;
} dirent64_t;
#pragma pack(pop)
_Static_assert(sizeof(dirent64_t)==64, "dirent size mismatch");


// ==========================DO NOT CHANGE THIS PORTION=========================
// These functions are there for your help. You should refer to the specifications to see how you can use them.
// ====================================CRC32====================================
uint32_t CRC32_TAB[256];
void crc32_init(void){
    for (uint32_t i=0;i<256;i++){
        uint32_t c=i;
        for(int j=0;j<8;j++) c = (c&1)?(0xEDB88320u^(c>>1)):(c>>1);
        CRC32_TAB[i]=c;
    }
}
uint32_t crc32(const void* data, size_t n){
    const uint8_t* p=(const uint8_t*)data; uint32_t c=0xFFFFFFFFu;
    for(size_t i=0;i<n;i++) c = CRC32_TAB[(c^p[i])&0xFF] ^ (c>>8);
    return c ^ 0xFFFFFFFFu;
}
// ====================================CRC32====================================

// WARNING: CALL THIS ONLY AFTER ALL OTHER SUPERBLOCK ELEMENTS HAVE BEEN FINALIZED
static uint32_t superblock_crc_finalize(superblock_t *sb) {
    sb->checksum = 0;
    uint32_t s = crc32((void *) sb, BS - 4);
    sb->checksum = s;
    return s;
}

static void print_usage(FILE *out, const char *prog) {
    fprintf(out, "Usage: %s --image <file>\n", prog);
    fprintf(out, "  --image  MiniVSFS image to list\n");
}

static int count_set_bits(const uint8_t *bitmap, uint64_t bits) {
    int count = 0;
    for (uint64_t i = 0; i < bits; ++i) {
        if (bitmap[i / 8] & (1 << (i % 8))) count++;
    }
    return count;
}

// Every value here comes from the image, so check it before using it as a size or offset.
// Ranges are checked first, which keeps the arithmetic below from overflowing.
static const char *layout_error(const superblock_t *sb) {
    uint64_t total = sb->total_blocks;
    if (total < MIN_BLOCKS || total > MAX_BLOCKS) return "total block count is out of range";
    if (sb->inode_count < MIN_INODES || sb->inode_count > MAX_INODES) return "inode count is out of range";
    if (sb->inode_bitmap_start >= total || sb->data_bitmap_start >= total) return "a bitmap is outside the image";
    if (sb->inode_table_start >= total || sb->inode_table_blocks > total - sb->inode_table_start) {
        return "the inode table is outside the image";
    }
    if (sb->inode_count * INODE_SIZE > sb->inode_table_blocks * BS) return "the inode table is too small";
    if (sb->data_region_start >= total || sb->data_region_blocks > total - sb->data_region_start) {
        return "the data region is outside the image";
    }
    return NULL;
}

int main(int argc, char **argv) {
    crc32_init();
    char *image_name = NULL;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--help")) {
            print_usage(stdout, argv[0]);
            return 0;
        } else if (!strcmp(argv[i], "--image") && i + 1 < argc) {
            image_name = argv[++i];
        }
    }
    if (!image_name) {
        fprintf(stderr, "Error: --image is required.\n");
        print_usage(stderr, argv[0]);
        return 1;
    }

    FILE *f = fopen(image_name, "rb");
    if (!f) {
        perror(image_name);
        return 1;
    }

    // Read and validate the superblock
    uint8_t first_block[BS];
    if (fread(first_block, 1, BS, f) != BS) {
        fprintf(stderr, "Error: '%s' is not a MiniVSFS image (too short to hold a superblock).\n", image_name);
        fclose(f);
        return 1;
    }
    superblock_t sb;
    memcpy(&sb, first_block, sizeof(superblock_t));
    if (sb.magic != 0x4D565346 || sb.version != 1 || sb.block_size != BS) {
        fprintf(stderr, "Error: '%s' is not a MiniVSFS image.\n", image_name);
        fclose(f);
        return 1;
    }
    if (superblock_crc_finalize((superblock_t *)first_block) != sb.checksum) {
        fprintf(stderr, "Error: '%s' is damaged: the superblock checksum doesn't match.\n", image_name);
        fclose(f);
        return 1;
    }
    const char *layout_problem = layout_error(&sb);
    if (layout_problem) {
        fprintf(stderr, "Error: '%s' is damaged: %s.\n", image_name, layout_problem);
        fclose(f);
        return 1;
    }

    // Read the whole image; total_blocks is known to be small and in range
    uint64_t image_bytes = sb.total_blocks * BS;
    uint8_t *image = malloc(image_bytes);
    if (!image) {
        fprintf(stderr, "Error: not enough memory to read the image.\n");
        fclose(f);
        return 1;
    }
    rewind(f);
    size_t bytes_read = fread(image, 1, image_bytes, f);
    int extra_data = fgetc(f) != EOF;
    fclose(f);
    if (bytes_read != image_bytes || extra_data) {
        fprintf(stderr, "Error: '%s' is damaged: its size doesn't match its superblock.\n", image_name);
        free(image);
        return 1;
    }

    const uint8_t *inode_bitmap = image + sb.inode_bitmap_start * BS;
    const uint8_t *data_bitmap = image + sb.data_bitmap_start * BS;
    const inode_t *inode_table = (const inode_t *)(image + sb.inode_table_start * BS);
    const inode_t *root = &inode_table[0];
    if (!(root->mode & 040000)) {
        fprintf(stderr, "Error: '%s' is damaged: the root inode isn't a directory.\n", image_name);
        free(image);
        return 1;
    }

    printf("%s: %" PRIu64 " blocks, %d of %" PRIu64 " inodes used, %" PRIu64 " data blocks free\n\n",
           image_name, sb.total_blocks, count_set_bits(inode_bitmap, sb.inode_count), sb.inode_count,
           sb.data_region_blocks - count_set_bits(data_bitmap, sb.data_region_blocks));
    printf("%5s  %-4s  %8s  %s\n", "INODE", "TYPE", "SIZE", "NAME");

    int rc = 0;
    for (int b = 0; b < DIRECT_MAX && root->direct[b] != 0 && rc == 0; ++b) {
        uint64_t blk = root->direct[b];
        if (blk < sb.data_region_start || blk >= sb.data_region_start + sb.data_region_blocks) {
            fprintf(stderr, "Error: '%s' is damaged: the root directory points outside the data region.\n", image_name);
            rc = 1;
            break;
        }
        const dirent64_t *entries = (const dirent64_t *)(image + blk * BS);
        for (uint32_t i = 0; i < BS / sizeof(dirent64_t); ++i) {
            const dirent64_t *de = &entries[i];
            if (de->inode_no == 0) continue;
            if (de->inode_no > sb.inode_count) {
                fprintf(stderr, "Error: '%s' is damaged: a directory entry has an invalid inode number.\n", image_name);
                rc = 1;
                break;
            }
            // Names come from the image: make sure it ends, and that it can't send terminal control codes
            char name[sizeof(de->name) + 1] = {0};
            memcpy(name, de->name, sizeof(de->name));
            for (char *c = name; *c; ++c) {
                if ((unsigned char)*c < 0x20 || *c == 0x7f) *c = '?';
            }
            printf("%5" PRIu32 "  %-4s  %8" PRIu64 "  %s\n", de->inode_no,
                   de->type == 2 ? "dir" : de->type == 1 ? "file" : "?",
                   inode_table[de->inode_no - 1].size_bytes, name);
        }
    }

    free(image);
    return rc;
}
