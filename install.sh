#!/usr/bin/env bash
# mco-proton-fix - make the Motor City Online Revival portable build run under Steam Proton.
#
# Fixes three Linux-only problems:
#   1. "Failed to initialize database"  -> installs DAO 3.5 / Jet 3.5 into the Proton prefix
#   2. Missing triangles / spikes        -> patches a vertex-buffer lock size in dx8z.dll
#   3. Login fails ("No servers...")     -> installs WineCertFix.asi so the MCOExOps
#                                           certificate pin works under Wine's WinINet
# See docs/TECHNICAL.md for the root causes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/mco-proton-fix"

JET_URL='https://web.archive.org/web/20210225171713/http://download.microsoft.com/download/4/3/9/4393c9ac-e69e-458d-9f6d-2fe191c51469/Jet40SP8_9xNT.exe'
JET_SHA256='b060246cd499085a31f15873689d5fa7df817e407c8261a5c71fa6b9f7042560'
VBAJET32_SHA256='9d25584e69ca0cc1ee76b2be2fa42ba08eaab41f6fff74a2562999680e1df420'
EXPSRV_SHA256='2b7d594459350dfc16d2314b93127fcb360544e6fbc57e1d4d1c67b704e2c2ff'

# dx8z.dll: THRASH_drawquad locks 4 vertices but writes 6. Signature = 48 bytes at 0x2790.
DX8Z_OFF=$((0x2790))
DX8Z_SIG_ORIG='518b0dccda0160a180c0016053555657bb060000004153bf04000000578d348500000000c744241800000000890dccda'
DX8Z_SIG_PATCHED='518b0dccda0160a180c0016053555657bb060000004153bf04000000578d344001f69090c744241800000000890dccda'
DX8Z_PATCH_OFF=$((0x27ad))
DX8Z_PATCH_BYTES='\x8d\x34\x40\x01\xf6\x90\x90'   # lea esi,[eax+eax*2]; add esi,esi; nop; nop  (6*stride)

GAME="" PFX="" PROTON="" APPID=""
DO_DAO=1 DO_DX8Z=1 DO_CERT=1 VERIFY=0 UNINSTALL=0 ASSUME_YES=0

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m %s\n' "$*"; }
warn() { printf '    \033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
cat <<EOF
Usage: $0 [options]

Launch the game once through Steam/Proton before running this, so the Proton
prefix exists. Close the game and launcher before running it.

Options:
  --game DIR      Game folder (the one containing mcity.exe). Default: auto-detect.
  --appid ID      Steam app id of the (non-Steam) shortcut, i.e. compatdata/<ID>.
  --prefix DIR    Wine prefix to use directly (the .../pfx directory).
  --proton DIR    Proton install to use (e.g. ".../steamapps/common/Proton 11.0").
  --skip-dao      Don't install DAO/Jet into the prefix.
  --skip-dx8z     Don't patch dx8z.dll.
  --skip-certfix  Don't install WineCertFix.asi.
  --verify        After installing, open the game database through DAO as a check.
  --uninstall     Restore dx8z.dll from backup and remove WineCertFix.asi.
  -y, --yes       Don't ask for confirmation.
  -h, --help      Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --game) GAME="$2"; shift 2 ;;
        --appid) APPID="$2"; shift 2 ;;
        --prefix) PFX="$2"; shift 2 ;;
        --proton) PROTON="$2"; shift 2 ;;
        --skip-dao) DO_DAO=0; shift ;;
        --skip-dx8z) DO_DX8Z=0; shift ;;
        --skip-certfix) DO_CERT=0; shift ;;
        --verify) VERIFY=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown option: $1" ;;
    esac
done

# ---------------------------------------------------------------- discovery

steam_libraries() {
    local root vdf
    for root in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
        [[ -d "$root/steamapps" ]] || continue
        echo "$root"
        vdf="$root/steamapps/libraryfolders.vdf"
        [[ -f "$vdf" ]] && sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"/\1/p' "$vdf"
    done | while read -r p; do [[ -d "$p/steamapps" ]] && realpath "$p"; done | sort -u
}

find_game() {
    [[ -f "$PWD/mcity.exe" ]] && { echo "$PWD"; return; }
    local lib hits=()
    while read -r lib; do
        while IFS= read -r -d '' f; do hits+=("$(dirname "$f")"); done \
            < <(find "$lib/steamapps/common" -maxdepth 3 -iname mcity.exe -print0 2>/dev/null)
    done < <(steam_libraries)
    mapfile -t hits < <(printf '%s\n' "${hits[@]}" | xargs -rd '\n' realpath | sort -u)
    [[ ${#hits[@]} -eq 1 ]] && { echo "${hits[0]}"; return; }
    [[ ${#hits[@]} -eq 0 ]] && die "could not find mcity.exe - pass --game DIR"
    printf '    %s\n' "${hits[@]}" >&2
    die "found several game folders - pass --game DIR"
}

find_prefix() {
    local lib d hits=()
    while read -r lib; do
        if [[ -n "$APPID" ]]; then
            [[ -d "$lib/steamapps/compatdata/$APPID/pfx" ]] && hits+=("$lib/steamapps/compatdata/$APPID")
            continue
        fi
        for d in "$lib"/steamapps/compatdata/*/; do
            [[ -f "$d/pfx/user.reg" ]] || continue
            if grep -q 'Motor City Online Launcher' "$d/pfx/user.reg" 2>/dev/null ||
               grep -q 'Electronic Arts\\\\Motor City\]' "$d/pfx/system.reg" 2>/dev/null; then
                hits+=("${d%/}")
            fi
        done
    done < <(steam_libraries)
    [[ ${#hits[@]} -eq 1 ]] && { echo "${hits[0]}"; return; }
    [[ ${#hits[@]} -eq 0 ]] && die "no Proton prefix for the game found - launch it once through Steam first, or pass --appid/--prefix"
    printf '    %s\n' "${hits[@]}" >&2
    die "several candidate prefixes - pass --appid ID"
}

find_proton() {   # $1 = compatdata dir
    local fonts
    fonts="$(sed -n 2p "$1/config_info" 2>/dev/null || true)"
    [[ "$fonts" == */files/* ]] && echo "${fonts%%/files/*}"
}

# ---------------------------------------------------------------- wine helpers

wine32() {   # run a 32-bit tool from syswow64 inside the prefix
    WINEPREFIX="$PFX" WINEDEBUG=-all "$PROTON/files/bin/wine" "$@" >/dev/null 2>&1
}
wine_wait() { WINEPREFIX="$PFX" "$PROTON/files/bin/wineserver" -w; }
winpath()   { local p; p="$(realpath "$1")"; printf 'Z:%s' "${p//\//\\}"; }

# ---------------------------------------------------------------- steps

install_dao() {
    say "DAO 3.5 / Jet 3.5 -> prefix"
    local dao="$GAME/scripts/DAO" f
    for f in dao350.dll msjet35.dll msjint35.dll msjter35.dll; do
        [[ -f "$dao/$f" ]] || die "$dao/$f missing - this script expects the Revival portable build with scripts/DAO"
    done

    # vbajet32.dll + expsrv.dll (Jet expression service) from Microsoft's Jet 4.0 SP8 redistributable
    mkdir -p "$CACHE"
    local exe="$CACHE/Jet40SP8_9xNT.exe"
    if ! echo "$JET_SHA256  $exe" | sha256sum -c --status 2>/dev/null; then
        say "downloading Jet 4.0 SP8 redistributable (same file winetricks uses)"
        curl -fL --retry 3 -o "$exe.part" "$JET_URL"
        mv "$exe.part" "$exe"
        echo "$JET_SHA256  $exe" | sha256sum -c --status || die "Jet40SP8_9xNT.exe checksum mismatch"
    fi
    local tmp; tmp="$(mktemp -d)"
    cabextract -q -d "$tmp/a" "$exe"
    cabextract -q -d "$tmp/b" "$tmp/a/jetsetup.exe"
    cabextract -q -d "$tmp/c" -F vbajet32.dll -F expsrv.dll "$tmp/b/jetsetup.cab"
    echo "$VBAJET32_SHA256  $tmp/c/vbajet32.dll" | sha256sum -c --status || die "vbajet32.dll checksum mismatch"
    echo "$EXPSRV_SHA256  $tmp/c/expsrv.dll"     | sha256sum -c --status || die "expsrv.dll checksum mismatch"

    install -m644 "$dao/msjet35.dll" "$dao/msjint35.dll" "$dao/msjter35.dll" "$tmp/c/vbajet32.dll" "$tmp/c/expsrv.dll" "$SYS32/"
    local shared="$PFX/drive_c/Program Files (x86)/Common Files/Microsoft Shared/DAO"
    mkdir -p "$shared"
    install -m644 "$dao/dao350.dll" "$shared/"
    rm -rf "$tmp"
    ok "DLLs copied"

    cp "$HERE/reg/jet35.reg" "$PFX/drive_c/mco-proton-fix-jet35.reg"
    wine32 'C:\windows\syswow64\regedit.exe' /S 'C:\mco-proton-fix-jet35.reg'
    wine32 'C:\windows\syswow64\regsvr32.exe' /s 'C:\Program Files (x86)\Common Files\Microsoft Shared\DAO\dao350.dll'
    wine_wait
    rm -f "$PFX/drive_c/mco-proton-fix-jet35.reg"
    grep -q 'Wow6432Node\\\\Microsoft\\\\Jet\\\\3.5\\\\Engines\\\\Jet 3.5\]' "$PFX/system.reg" || die "Jet registry keys did not land in the 32-bit view"
    grep -q 'Licenses\\\\F4FC596D-DFFE-11CF-9551-00AA00A3DC45\]' "$PFX/system.reg" || die "DAO license key missing"
    grep -qi 'Common Files\\\\Microsoft Shared\\\\DAO\\\\dao350.dll' "$PFX/system.reg" || die "dao350.dll did not register"
    ok "Jet engine keys, DAO license and COM registration in place"
}

verify_dao() {
    say "checking DAO can open Data/DB/Online.mdb"
    local tmp out; tmp="$(mktemp -d)"; out="$tmp/result.txt"
    cp "$HERE/tools/daotest.vbs" "$tmp/"
    wine32 'C:\windows\syswow64\cscript.exe' //nologo "$(winpath "$tmp/daotest.vbs")" "$(winpath "$GAME/Data/DB/Online.mdb")" "$(winpath "$tmp")\\result.txt" || true
    wine_wait
    local r; r="$(tr -d '\r' < "$out" 2>/dev/null || echo 'FAIL no output')"
    rm -rf "$tmp"
    [[ "$r" == OK* ]] && ok "$r" || die "DAO check: $r"
}

patch_one_dx8z() {   # $1 = dll path
    local dll="$1" sig
    [[ -f "$dll" ]] || return 0
    sig="$(xxd -s $DX8Z_OFF -l 48 -p "$dll" | tr -d '\n')"
    if [[ "$sig" == "$DX8Z_SIG_PATCHED" ]]; then ok "$(basename "$dll") already patched"; return; fi
    [[ "$sig" == "$DX8Z_SIG_ORIG" ]] || die "$(basename "$dll") is not the expected build (drawquad signature mismatch) - not patching"
    [[ -f "$dll.orig" ]] || cp -p "$dll" "$dll.orig"
    printf "$DX8Z_PATCH_BYTES" | dd of="$dll" bs=1 seek=$DX8Z_PATCH_OFF conv=notrunc status=none
    [[ "$(xxd -s $DX8Z_OFF -l 48 -p "$dll" | tr -d '\n')" == "$DX8Z_SIG_PATCHED" ]] || die "patch verification failed for $dll"
    ok "$(basename "$dll") patched (backup: $(basename "$dll").orig)"
}

patch_dx8z() {
    say "dx8z.dll drawquad vertex-buffer lock size (4 -> 6 vertices)"
    patch_one_dx8z "$GAME/dx8z.dll"
    patch_one_dx8z "$GAME/dx8zDB.dll"
}

install_certfix() {
    say "WineCertFix.asi -> scripts/"
    [[ -f "$GAME/dinput8.dll" && -f "$GAME/scripts/MCOExOps.asi" ]] ||
        warn "ASI loader (dinput8.dll) or MCOExOps.asi not found - the plugin only matters with MCOExOps' certificate pin"
    local asi="$HERE/prebuilt/WineCertFix.asi"
    if command -v i686-w64-mingw32-gcc >/dev/null 2>&1; then
        make -s -C "$HERE/src" >/dev/null && asi="$HERE/build/WineCertFix.asi" && ok "built from source"
    else
        ok "MinGW not found - using prebuilt/WineCertFix.asi"
    fi
    install -m644 "$asi" "$GAME/scripts/WineCertFix.asi"
    ok "installed (logs to scripts/WineCertFix.log when it steps in)"
}

uninstall() {
    say "restoring game files"
    local f
    for f in dx8z.dll dx8zDB.dll; do
        if [[ -f "$GAME/$f.orig" ]]; then mv -f "$GAME/$f.orig" "$GAME/$f"; ok "restored $f"; fi
    done
    rm -f "$GAME/scripts/WineCertFix.asi" "$GAME/scripts/WineCertFix.log" && ok "removed WineCertFix.asi"
    echo "    (DAO/Jet stay installed in the Proton prefix; they're harmless. Delete the prefix to remove them.)"
}

# ---------------------------------------------------------------- main

for t in cabextract curl sha256sum xxd dd realpath; do command -v "$t" >/dev/null || die "missing tool: $t"; done

[[ -n "$GAME" ]] || GAME="$(find_game)"
GAME="$(realpath "$GAME")"
[[ -f "$GAME/mcity.exe" ]] || die "$GAME does not contain mcity.exe"

if pgrep -fi 'mcity\.exe|mco-launcher\.exe' >/dev/null; then die "the game or launcher is running - close it first"; fi

if [[ $UNINSTALL -eq 1 ]]; then uninstall; exit 0; fi

if [[ $DO_DAO -eq 1 || $VERIFY -eq 1 ]]; then
    if [[ -z "$PFX" ]]; then
        compat="$(find_prefix)"; PFX="$compat/pfx"
        [[ -n "$PROTON" ]] || PROTON="$(find_proton "$compat")"
    fi
    [[ -n "$PROTON" ]] || die "could not tell which Proton the prefix uses - pass --proton DIR"
    PFX="$(realpath "$PFX")"
    [[ -x "$PROTON/files/bin/wine" ]] || die "$PROTON/files/bin/wine not found - pass --proton DIR"
    [[ -d "$PFX/drive_c/windows/syswow64" ]] || die "$PFX is not a 64-bit Wine prefix"
    SYS32="$PFX/drive_c/windows/syswow64"
fi

echo "Game folder : $GAME"
[[ -n "$PFX" ]] && echo "Prefix      : $PFX" && echo "Proton      : $PROTON"
echo "Steps       : $([[ $DO_DAO == 1 ]] && echo 'dao ')$([[ $DO_DX8Z == 1 ]] && echo 'dx8z ')$([[ $DO_CERT == 1 ]] && echo 'certfix ')$([[ $VERIFY == 1 ]] && echo 'verify')"
if [[ $ASSUME_YES -eq 0 ]]; then read -r -p "Continue? [y/N] " a; [[ "$a" == [yY]* ]] || exit 1; fi

[[ $DO_DAO  -eq 1 ]] && install_dao
[[ $DO_DX8Z -eq 1 ]] && patch_dx8z
[[ $DO_CERT -eq 1 ]] && install_certfix
[[ $VERIFY  -eq 1 ]] && verify_dao
say "done - launch the game through Steam as usual"
