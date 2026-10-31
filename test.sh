#!/usr/bin/env bash
# Checks the tools' failure handling. Builds and runs in a temp dir, so the repo stays clean.
set -u
repo=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp" || exit 1

gcc -O2 -std=c17 -Wall -Wextra -Werror "$repo/mkfs_builder.c" -o mkfs_builder || exit 1
gcc -O2 -std=c17 -Wall -Wextra -Werror "$repo/mkfs_adder.c" -o mkfs_adder || exit 1

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

[ "$failures" -eq 0 ] && echo "All checks passed." || { echo "$failures check(s) failed."; exit 1; }
