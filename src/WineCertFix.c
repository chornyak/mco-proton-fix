// WineCertFix.asi - Wine/Proton compatibility shim for MCOExOps' certificate pin.
//
// Under Wine, InternetQueryOptionA(INTERNET_OPTION_SERVER_CERT_CHAIN_CONTEXT)
// fails with ERROR_INTERNET_INCORRECT_HANDLE_STATE after a TLS handshake that
// failed certificate validation, whereas Windows still returns the server's
// chain. MCOExOps needs that chain to compare against its pinned SHA-1, so the
// login never gets pinned. When that query fails, this shim opens a separate
// probe request to the same host (certificate errors ignored, nothing sent but
// a HEAD) and returns the probe's server chain. The pin comparison itself is
// still done by MCOExOps. Does nothing when not running under Wine.
#include <windows.h>
#include <wininet.h>

#define OPT_SERVER_CERT_CHAIN 105
typedef BOOL (WINAPI *QOA)(HINTERNET, DWORD, LPVOID, LPDWORD);
static QOA g_real;
static HANDLE g_log = INVALID_HANDLE_VALUE;

static void shimlog(const char *fmt, ...){
    if (g_log == INVALID_HANDLE_VALUE) return;
    char b[512]; va_list a; va_start(a, fmt); wvsprintfA(b, fmt, a); va_end(a);
    lstrcatA(b, "\r\n"); DWORD w; WriteFile(g_log, b, lstrlenA(b), &w, NULL);
}

static BOOL probe_chain(HINTERNET req, LPVOID buf, LPDWORD len){
    char url[2048]; DWORD ul = sizeof url;
    if (!g_real(req, INTERNET_OPTION_URL, url, &ul)) { shimlog("no URL on handle (err %lu)", GetLastError()); return FALSE; }
    char host[256]; URL_COMPONENTSA uc; ZeroMemory(&uc, sizeof uc);
    uc.dwStructSize = sizeof uc; uc.lpszHostName = host; uc.dwHostNameLength = sizeof host;
    if (!InternetCrackUrlA(url, 0, 0, &uc) || uc.nScheme != INTERNET_SCHEME_HTTPS) { shimlog("not an https URL"); return FALSE; }
    BOOL ok = FALSE;
    HINTERNET s = InternetOpenA("MCO cert probe", INTERNET_OPEN_TYPE_PRECONFIG, NULL, NULL, 0);
    HINTERNET c = s ? InternetConnectA(s, host, uc.nPort, NULL, NULL, INTERNET_SERVICE_HTTP, 0, 0) : NULL;
    HINTERNET r = c ? HttpOpenRequestA(c, "HEAD", "/", NULL, NULL, NULL,
                        INTERNET_FLAG_SECURE|INTERNET_FLAG_RELOAD|INTERNET_FLAG_NO_CACHE_WRITE|INTERNET_FLAG_NO_COOKIES, 0) : NULL;
    if (r) {
        DWORD f = SECURITY_FLAG_IGNORE_UNKNOWN_CA|SECURITY_FLAG_IGNORE_CERT_CN_INVALID|SECURITY_FLAG_IGNORE_CERT_DATE_INVALID|
                  SECURITY_FLAG_IGNORE_REVOCATION|SECURITY_FLAG_IGNORE_WRONG_USAGE;
        InternetSetOptionA(r, INTERNET_OPTION_SECURITY_FLAGS, &f, sizeof f);
        if (HttpSendRequestA(r, NULL, 0, NULL, 0)) ok = g_real(r, OPT_SERVER_CERT_CHAIN, buf, len);
        shimlog("probe %s:%u -> %s", host, uc.nPort, ok ? "server chain returned to caller" : "failed");
    }
    if (r) InternetCloseHandle(r);
    if (c) InternetCloseHandle(c);
    if (s) InternetCloseHandle(s);
    return ok;
}

static BOOL WINAPI hook(HINTERNET h, DWORD opt, LPVOID buf, LPDWORD len){
    BOOL r = g_real(h, opt, buf, len);
    if (r || opt != OPT_SERVER_CERT_CHAIN || !buf || !len || *len < sizeof(void*)) return r;
    DWORD e = GetLastError();
    shimlog("server cert chain query failed (err %lu) - probing", e);
    if (probe_chain(h, buf, len)) return TRUE;
    SetLastError(e);
    return FALSE;
}

static void install(void){
    if (!GetProcAddress(GetModuleHandleA("ntdll.dll"), "wine_get_version")) return;   // Windows: do nothing
    HMODULE w = LoadLibraryA("wininet.dll");
    BYTE *f = w ? (BYTE*)GetProcAddress(w, "InternetQueryOptionA") : NULL;
    static const BYTE pro[5] = {0x55,0x89,0xe5,0x56,0x53};   // push ebp; mov ebp,esp; push esi; push ebx
    if (!f || memcmp(f, pro, 5)) { shimlog("InternetQueryOptionA prologue not recognised - not hooking"); return; }
    BYTE *t = VirtualAlloc(NULL, 16, MEM_COMMIT|MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    memcpy(t, f, 5); t[5] = 0xE9; *(DWORD*)(t+6) = (DWORD)(f+5) - (DWORD)(t+10);
    g_real = (QOA)t;
    DWORD old; VirtualProtect(f, 5, PAGE_EXECUTE_READWRITE, &old);
    f[0] = 0xE9; *(DWORD*)(f+1) = (DWORD)hook - (DWORD)(f+5);
    VirtualProtect(f, 5, old, &old); FlushInstructionCache(GetCurrentProcess(), f, 5);
    shimlog("hooked wininet!InternetQueryOptionA");
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD r, LPVOID p){
    if (r == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(h);
        char path[MAX_PATH]; GetModuleFileNameA(h, path, MAX_PATH);
        char *s = path + lstrlenA(path); while (s > path && s[-1] != '\\') s--; lstrcpyA(s, "WineCertFix.log");
        g_log = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, 0, NULL);
        install();
    }
    return TRUE;
}
