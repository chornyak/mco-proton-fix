# Builds WineCertFix.asi (32-bit Windows DLL) with the MinGW-w64 cross compiler.
CROSS   ?= i686-w64-mingw32-
CC      := $(CROSS)gcc
CFLAGS  ?= -O2 -Wall -Wno-unused-parameter
LDFLAGS := -shared -static-libgcc -nostartfiles -Wl,--entry,_DllMain@12 -Wl,--no-insert-timestamp -s
LIBS    := -lwininet -lkernel32 -luser32

OUT := ../build/WineCertFix.asi

$(OUT): WineCertFix.c
	mkdir -p ../build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< $(LIBS)

clean:
	rm -f $(OUT)

.PHONY: clean
