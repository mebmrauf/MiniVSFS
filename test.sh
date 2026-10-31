#!/usr/bin/env bash
# Checks the tools' failure handling. Builds and runs in a temp dir, so the repo stays clean.
set -u
repo=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp" || exit 1

gcc -O2 -std=c17 -Wall -Wextra -Werror "$repo/mkfs_builder.c" -o mkfs_builder || exit 1
gcc -O2 -std=c17 -Wall -Wextra -Werror "$repo/mkfs_adder.c" -o mkfs_adder || exit 1
gcc -O2 -std=c17 -Wall -Wextra -Werror "$repo/mkfs_ls.c" -o mkfs_ls || exit 1

failures=0
check() { # check <description> <expected exit code> <command...>
    local desc=$1 want=$2; shift 2
    "$@" >/dev/null 2>&1
    local got=$?
    if [ "$got" -eq "$want" ]; then
        echo "ok    $desc"
    else
        echo "FAIL  $desc (exit code $got, expected $want)"
        failures=$((failures + 1))
    fi
}
# The file size limit makes writes fail the same way a full disk does
limited() { ( trap '' XFSZ; ulimit -f 40; "$@" ); }

./mkfs_builder --image base.img --size-kib 180 --inodes 128 >/dev/null || exit 1
before=$(cksum < base.img)
echo hello > small.txt

name57=$(printf 'a%.0s' {1..57}); echo hello > "$name57"
name58=$(printf 'a%.0s' {1..58}); echo hello > "$name58"
check "57-character name is accepted" 0 ./mkfs_adder --input base.img --output long.img --file "$name57"
check "58-character name is rejected" 1 ./mkfs_adder --input base.img --output bad.img --file "$name58"

ln -s base.img link.img
ln base.img hard.img
check "same input and output is rejected" 1 ./mkfs_adder --input base.img --output base.img --file small.txt
check "./ path to the input is rejected" 1 ./mkfs_adder --input base.img --output ./base.img --file small.txt
check "symlink to the input is rejected" 1 ./mkfs_adder --input base.img --output link.img --file small.txt
check "hard link to the input is rejected" 1 ./mkfs_adder --input base.img --output hard.img --file small.txt
small_before=$(cksum < small.txt)
check "same file and output is rejected" 1 ./mkfs_adder --input base.img --output small.txt --file small.txt
check "file being added is unchanged" 0 test "$small_before" = "$(cksum < small.txt)"

# Make the Nth calloc fail, to exercise each out-of-memory path in the builder
cat > fail_calloc.h <<'EOF'
#include <stdlib.h>
static int calloc_calls = 0;
static void *fail_calloc(size_t n, size_t size) { return ++calloc_calls == FAIL_AT ? NULL : calloc(n, size); }
#define calloc fail_calloc
EOF
for n in 1 2 3 4; do
    gcc -std=c17 -include fail_calloc.h -DFAIL_AT=$n "$repo/mkfs_builder.c" -o builder_nomem || exit 1
    check "builder handles failed allocation $n" 1 ./builder_nomem --image nomem.img --size-kib 180 --inodes 128
    check "no image after failed allocation $n" 1 test -e nomem.img
done

check "builder reports a failed write" 1 limited ./mkfs_builder --image full1.img --size-kib 180 --inodes 128
check "adder reports a failed write" 1 limited ./mkfs_adder --input base.img --output full2.img --file small.txt
check "builder removes the incomplete image" 1 test -e full1.img
check "adder removes the incomplete image" 1 test -e full2.img
check "rejected output was not created" 1 test -e bad.img

check "normal add still works" 0 ./mkfs_adder --input base.img --output good.img --file small.txt
check "input image is unchanged" 0 test "$before" = "$(cksum < base.img)"

# mkfs_ls: normal listings
./mkfs_ls --image good.img > listing.txt
check "mkfs_ls succeeds" 0 ./mkfs_ls --image good.img
check "mkfs_ls lists the added file" 0 grep -Eq '^ +2  file +6  small.txt$' listing.txt
check "mkfs_ls lists the root directory" 0 grep -Eq '^ +1  dir +192  \.$' listing.txt
check "mkfs_ls shows inode and block counts" 0 grep -q '2 of 128 inodes used, 36 data blocks free' listing.txt

# mkfs_ls: damaged images must give a clean error (exit code 1), not a crash
patch_bytes() { # patch_bytes <file> <offset> <bytes as printf escapes>
    printf "$3" | dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null
}
head -c 100 /dev/urandom > junk.img
head -c 8192 good.img > short.img
{ cat good.img; echo extra; } > long.img
cp good.img badcrc.img; patch_bytes badcrc.img 20 '\377'
cp good.img badblock.img; patch_bytes badblock.img $((3*4096+44)) '\377\377\377\377'
cp good.img badino.img; patch_bytes badino.img $((7*4096+128)) '\377\377\377\377'
check "mkfs_ls rejects a missing image" 1 ./mkfs_ls --image missing.img
check "mkfs_ls rejects a directory" 1 ./mkfs_ls --image .
check "mkfs_ls rejects a non-image" 1 ./mkfs_ls --image junk.img
check "mkfs_ls rejects a truncated image" 1 ./mkfs_ls --image short.img
check "mkfs_ls rejects an image with extra data" 1 ./mkfs_ls --image long.img
check "mkfs_ls rejects a bad superblock checksum" 1 ./mkfs_ls --image badcrc.img
check "mkfs_ls rejects a bad block pointer" 1 ./mkfs_ls --image badblock.img
check "mkfs_ls rejects a bad inode number" 1 ./mkfs_ls --image badino.img

# viewer.html: its parser must agree with mkfs_ls, since both read the same format
if command -v node >/dev/null; then
    cat > viewer_list.js <<'EOF'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
const parseImage = new Function(html.match(/<script id="parser">([\s\S]*?)<\/script>/)[1] + "; return parseImage;")();
const name = process.argv[3], img = parseImage(new Uint8Array(fs.readFileSync(name)));
if (img.error) process.exit(1);
console.log(`${name}: ${img.sb.total_blocks} blocks, ${img.inodesUsed} of ${img.sb.inode_count} inodes used, ${img.blocksFree} data blocks free\n`);
console.log("INODE  TYPE      SIZE  NAME");
for (const e of img.entries) {
    const type = e.type === 2 ? "dir" : e.type === 1 ? "file" : "?";
    console.log(`${String(e.ino).padStart(5)}  ${type.padEnd(4)}  ${String(e.inode.size).padStart(8)}  ${e.name}`);
}
EOF
    viewer_list() { node viewer_list.js "$repo/viewer.html" "$1"; }
    ./mkfs_adder --input good.img --output viewer.img --file "$name57" >/dev/null
    viewer_list viewer.img > viewer_listing.txt
    ./mkfs_ls --image viewer.img > ls_listing.txt
    check "viewer and mkfs_ls list the same contents" 0 cmp viewer_listing.txt ls_listing.txt
    check "viewer rejects a non-image" 1 viewer_list junk.img
    check "viewer rejects a truncated image" 1 viewer_list short.img
    check "viewer rejects an image with extra data" 1 viewer_list long.img
    check "viewer rejects a bad superblock checksum" 1 viewer_list badcrc.img
else
    echo "skip  viewer checks (node isn't installed)"
fi

[ "$failures" -eq 0 ] && echo "All checks passed." || { echo "$failures check(s) failed."; exit 1; }
