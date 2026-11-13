# Root causes

Three separate problems stop the Revival portable build from working under Proton. Each one
is a case of Windows being more forgiving than Wine/Proton.

## 1. "Failed to initialize database" — DAO 3.5 / Jet 3.5

`mcity.exe` opens `Data/DB/Online.mdb` and `SaveData/DB/Tmp.MDB` through DAO 3.5
(`CoCreateInstance` of `DBEngine`, CLSID `{00000010-0000-0010-8000-00AA006D2EA4}`), which
loads the Jet 3.5 engine. Proton ships neither.

MCOExOps ("Portable" mode) works around a missing install by hooking `CoCreateInstance` and
loading `scripts\DAO\dao350.dll` directly. That gets DAO loaded, but not working:

- **Jet isn't found.** DAO loads `MSJET35.DLL` by name. `scripts\DAO` isn't on the DLL
  search path, and the `HKLM\SOFTWARE\Microsoft\Jet\3.5\Engines` keys a real install writes
  are missing.
- **Licensing.** DAO 3.5's class factory checks
  `HKCR\Licenses\F4FC596D-DFFE-11CF-9551-00AA00A3DC45` and fails with
  `CLASS_E_NOTLICENSED` (VB error 429) without it.
- **Expression service.** Opening a database needs `VBAJET32.DLL` and `EXPSRV.DLL`
  (Jet error 3446), which the mod doesn't bundle. They come from Microsoft's Jet 4.0 SP8
  redistributable. Winetricks' `jet40` verb refuses 64-bit prefixes, and every Proton prefix is
  64-bit, so `install.sh` extracts just those two DLLs.

Proton prefixes are WOW64, so the Jet keys must be written with the 32-bit `regedit`
(`C:\windows\syswow64\regedit.exe`). Otherwise they land in the 64-bit view, which the
32-bit game never reads.

## 2. Missing triangles and spikes — `THRASH_drawquad` lock size

The intro video, menus and text are drawn through `dx8z.dll` (the Direct3D 8 "THRASH"
renderer). Every frame was missing one triangle of each quad, and the rest were stretched
into spikes, under both DXVK and WineD3D, and with every mod disabled.

A logging wrapper on the `_THRASH_draw*` exports showed almost all of it goes through
`_THRASH_drawquad@16`, and the vertices the game passes in are correct. The bug is inside
`drawquad` (`dx8z.dll` at `0x60002790`). It appends to one dynamic vertex buffer
(`D3DUSAGE_DYNAMIC|WRITEONLY`) and expands each quad into a triangle list:

```
600027ad  lea  esi,[eax*4+0]          ; SizeToLock = 4 * stride
...
6000285a  call [edx+0x2c]             ; IDirect3DVertexBuffer8::Lock(offset, 4*stride, &p, NOOVERWRITE)
          ... copies v0 v1 v2 v0 v2 v3 ; 6 vertices written
60002990  call [ecx+0x30]             ; Unlock
6000299a  add  eax,6                  ; write position advances by 6
```

It locks room for 4 vertices but writes 6, so the last two (the second triangle's v2 and v3)
go past the locked range.

- **Windows drivers** map the whole buffer, so those writes land and the quad draws fine.
- **DXVK and WineD3D** only treat the locked range as written and upload just that. The second
  triangle reads stale data, so it disappears or turns into a spike.

The fix changes the lock size to 6 × stride:

```
600027ad  8d 34 85 00 00 00 00   lea esi,[eax*4+0]
      ->  8d 34 40 01 f6 90 90   lea esi,[eax+eax*2] ; add esi,esi ; nop ; nop
```

The other draw functions (`drawtri`, the line, sprite and mesh versions) lock exactly what
they write. This patch is correct on Windows as well, so it could be fixed upstream.

## 3. Login fails — certificate chain unavailable after a rejected handshake

The login server (`mc.novaserv.cc`) presents a self-signed `mcouniverse.com` certificate that
expired in 2022, so normal validation fails (`ERROR_INTERNET_SEC_CERT_DATE_INVALID`, 12037).
MCOExOps handles this with a pin. After the failure it asks for the server's chain with
`InternetQueryOptionA(INTERNET_OPTION_SERVER_CERT_CHAIN_CONTEXT = 105)`, compares the leaf's
SHA-1 with `Server Certificate =` in `MCOExOps.ini`
(`FF230DB6F36F18B85D5998D6647C3588812CA3F5`), and if they match it sets the
`SECURITY_FLAG_IGNORE_*` flags and resends.

Under Wine, option 105 fails with `ERROR_INTERNET_INCORRECT_HANDLE_STATE` (12019) once the
handshake has been rejected. Wine only keeps the server certificate on a request whose
handshake succeeded. The pin can never match, so the login fails with
`IAUTHORIZE_BAD_CONNECTION` / "EA.com is temporarily unavailable (INV-300)".

`WineCertFix.asi` hooks `wininet!InternetQueryOptionA`, using a 5-byte prologue detour that is
only installed when `ntdll!wine_get_version` exists. When option 105 fails it:

1. reads the URL from the caller's handle,
2. sends a separate `HEAD /` to the same host and port with the certificate errors ignored,
3. returns that connection's server chain to the caller.

MCOExOps still does the fingerprint comparison itself, so a server with any other
certificate is still rejected.

Tested results under Proton 11.0, standalone and in game:

```
1st send: err=12037                         (as on Windows)
query 105 (no shim):   err=12019            (Windows: succeeds)
query 105 (with shim): sha1=FF230DB6F36F18B85D5998D6647C3588812CA3F5
MCOExOps: "server certificate: pinned certificate accepted"
authlogin: "GetTicketSync(1) connection succeed with valid result."
```

## Things that were ruled out

- **DXVK vs WineD3D.** Identical corruption under both (`PROTON_USE_WINED3D=1`).
- **MCOExOps / other ASI mods.** Identical corruption with the ASI loader removed.
- **CPU feature paths.** `mcity.exe` has 3DNow!/SSE paths, but Wine passes the real CPUID
  through, and 3DNow! is only used when CPUID reports it.
- **x87 state.** The FPU tag word was clean (no leftover MMX state) at every draw call.
