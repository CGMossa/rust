#!/bin/bash
# Validation matrix for the windows-gnu function_sections experiment.
#   A: rust-win-gnu-fs default          (function_sections ON, --gc-sections auto)
#   B: rust-win-gnu-fs, gc disabled     (function_sections ON, --no-gc-sections)
#   C: nightly default                  (function_sections OFF in std; --gc-sections auto but ineffective)
set -u
cd "$(dirname "$0")"
TARGET=x86_64-pc-windows-gnu
LINKER="-C linker=x86_64-w64-mingw32-gcc"
OBJDUMP=x86_64-w64-mingw32-objdump

build() { # $1 toolchain  $2 extra-flags  $3 src  $4 out
    rustc "+$1" -O --target $TARGET $LINKER $2 "$3" -o "$4" 2>"$4.err"
    if [ $? -ne 0 ]; then echo "LINK FAILED: $4"; sed -n 1,15p "$4.err"; return 1; fi
    return 0
}

sec() { # $1 exe  $2 section -> size in decimal (0 if absent)
    local hex
    hex=$($OBJDUMP -h "$1" | awk -v s="$2" '$2==s {print $3; exit}')
    echo $((16#${hex:-0}))
}

report() { # $1 label  $2 exe
    local bytes stripped text pdata xdata nsec
    bytes=$(stat -f%z "$2")
    cp -f "$2" "$2.stripped" && x86_64-w64-mingw32-strip --strip-debug "$2.stripped"
    stripped=$(stat -f%z "$2.stripped")
    text=$(sec "$2" .text)
    pdata=$(sec "$2" .pdata)
    xdata=$(sec "$2" .xdata)
    nsec=$($OBJDUMP -h "$2" | grep -cE '^ *[0-9]+ ')
    printf "%-28s %10d %10d %10d %8d %8d %5d %8d\n" "$1" "$bytes" "$stripped" "$text" "$pdata" "$xdata" "$nsec" $((pdata / 12))
}

echo "=== build matrix ==="
for prog in hello medium; do
    build rust-win-gnu-fs ""                                    $prog.rs ${prog}_A.exe && echo "OK ${prog}_A"
    build rust-win-gnu-fs "-C link-args=-Wl,--no-gc-sections"   $prog.rs ${prog}_B.exe && echo "OK ${prog}_B"
    build nightly         ""                                    $prog.rs ${prog}_C.exe && echo "OK ${prog}_C"
done

echo
printf "%-28s %10s %10s %10s %8s %8s %5s %8s\n" "variant" "bytes" "stripped" ".text" ".pdata" ".xdata" "#sec" "#funcs"
for prog in hello medium; do
    report "${prog} A (fs+gc, branch)"  ${prog}_A.exe
    report "${prog} B (fs, no gc)"      ${prog}_B.exe
    report "${prog} C (nightly base)"   ${prog}_C.exe
done

echo
echo "=== std rlib .text\$ section counts (per-function granularity) ==="
OURS=$(ls /Users/elea/Documents/GitHub/rust/build/host/stage1-win-gnu-fs/lib/rustlib/$TARGET/lib/libstd-*.rlib)
THEIRS=$(ls ~/.rustup/toolchains/nightly-aarch64-apple-darwin/lib/rustlib/$TARGET/lib/libstd-*.rlib)
echo "branch libstd:  $($OBJDUMP -h "$OURS" 2>/dev/null | grep -c 'text\$') .text\$ sections"
echo "nightly libstd: $($OBJDUMP -h "$THEIRS" 2>/dev/null | grep -c 'text\$') .text\$ sections"
