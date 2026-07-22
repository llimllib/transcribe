# Makefile for the transcribe CLI (Apple SpeechAnalyzer / SpeechTranscriber).
# Requires macOS 26+ and a Swift 6 toolchain.

SWIFTC   := swiftc
SWIFTFLAGS := -O -parse-as-library
BIN      := transcribe
SRC      := transcribe.swift
PREFIX   ?= /usr/local

.PHONY: all clean run install uninstall

all: $(BIN)

$(BIN): $(SRC)
	$(SWIFTC) $(SWIFTFLAGS) $(SRC) -o $(BIN)

# Build then transcribe: make run FILE=mlk.wav [LOCALE=en-US]
run: $(BIN)
	./$(BIN) $(if $(V),-v) $(FILE) $(LOCALE)

install: $(BIN)
	install -d $(PREFIX)/bin
	install -m 0755 $(BIN) $(PREFIX)/bin/$(BIN)

uninstall:
	rm -f $(PREFIX)/bin/$(BIN)

clean:
	rm -f $(BIN)
