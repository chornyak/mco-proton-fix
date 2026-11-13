# mco-proton-fix

Makes the **Motor City Online: Revival** portable build (the one with `mco-launcher.exe`
and the MCOExOps mods) playable on Linux through Steam's Proton.

Without it, the game under Proton:

1. stops after the intro with **"Failed to initialize database. Please be sure you have
   setup the DCOM and DAO drivers…"**,
2. draws the intro, menus and text with **missing triangles and long spikes** (under both
   DXVK and WineD3D), and
3. can't log in: **"No servers are available at this time"** / **"The connection to Motor City
   has failed"**.

All three work on Windows. The causes are differences in how Wine/Proton handles old
components and APIs that Windows lets slide; see [docs/TECHNICAL.md](docs/TECHNICAL.md).

## What it changes

| Problem | Change | Where |
|---|---|---|
| Database error | Installs DAO 3.5 + Jet 3.5 (from the game's own `scripts/DAO`), plus `vbajet32.dll`/`expsrv.dll` from Microsoft's Jet 4.0 SP8 redistributable, and registers them | Proton prefix |
| Broken geometry | Patches 7 bytes in `dx8z.dll` (and the identical `dx8zDB.dll`) so `THRASH_drawquad` locks the 6 vertices it writes instead of 4. Originals kept as `*.orig` | Game folder |
| Login fails | Adds `scripts/WineCertFix.asi`, which lets MCOExOps' certificate pin read the server certificate under Wine | Game folder |

No game files or Microsoft binaries are included in this repository. The Jet 4.0 SP8
redistributable is downloaded from the Internet Archive (the same file and checksum
winetricks uses) and checked before use.

## Requirements

- The Revival portable build added to Steam as a non-Steam game (`mco-launcher.exe`),
  set to run with Proton (tested with Proton 11.0)
- `bash`, `curl`, `cabextract`, `xxd` (usually part of `vim`), `sha256sum`
- Optional: `i686-w64-mingw32-gcc` to build the plugin from source (otherwise
  `prebuilt/WineCertFix.asi` is used)

## Usage

1. Launch the game once through Steam so Proton creates its prefix, then close it
   (and the launcher).
2. Run:

   ```sh
   git clone <this repo> && cd mco-proton-fix
   ./install.sh --verify
   ```

   The script finds the game folder, its Proton prefix and Proton version by itself, shows
   what it found, and asks before changing anything. If it finds more than one candidate,
   point it at the right one:

   ```sh
   ./install.sh --game "/path/to/Motor City Online Portable" --appid 1234567890
   ```

3. Launch the game through Steam as usual.

`--verify` opens the game's database through DAO inside the prefix as a final check.
The script is safe to re-run: finished steps are detected and skipped or redone harmlessly.

Other options: `--skip-dao`, `--skip-dx8z`, `--skip-certfix`, `--prefix DIR`, `--proton DIR`,
`-y`. Run `./install.sh --help` for details.

### If Steam recreates the prefix

Changing the Proton version for the shortcut, or deleting its compatdata folder, gives you a
new prefix without DAO. Re-run `./install.sh` (the game-folder changes are kept).

## Undo

```sh
./install.sh --uninstall
```

Restores `dx8z.dll`/`dx8zDB.dll` from their `.orig` backups and removes `WineCertFix.asi`.
DAO/Jet stay in the prefix (harmless); delete the prefix to remove them.

## Notes

- `WineCertFix.asi` does nothing on Windows (it checks for Wine first). Under Wine it only
  acts when a request for a server's certificate chain fails, and the certificate it supplies
  is still compared against the pinned fingerprint in `MCOExOps.ini` by MCOExOps itself.
  It writes `scripts/WineCertFix.log` when it steps in.
- `prebuilt/WineCertFix.asi` is a reproducible build of `src/WineCertFix.c`, for people without
  MinGW. To check it, rebuild and compare:

  ```sh
  make -C src && sha256sum build/WineCertFix.asi prebuilt/WineCertFix.asi
  # 98e859b2442368ffb94b30b8e1aaf53e01cf572f3d23b4189459d21d38cd6125
  ```

  Built with i686-w64-mingw32-gcc 16.2.0 / binutils 2.47. Other toolchain versions produce a
  working plugin with a different hash.
- The `dx8z.dll` change is a real bug fix, not a Wine workaround: it is correct on Windows
  too. The patcher only touches files whose bytes around the patch site match the known build.

## Disclaimer

Not affiliated with Electronic Arts or the Motor City Online Revival team. Motor City Online
is a trademark of its respective owner.

## License

MIT, see [LICENSE](LICENSE). Covers this repository's scripts and source only, not the game or the Microsoft components the installer downloads.
