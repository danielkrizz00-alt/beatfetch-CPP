CXX      ?= g++
CXXFLAGS ?= -O2 -std=c++17 -Wall -Wextra -pipe
LDFLAGS  ?= -pthread

SRC = main.cpp
BIN = beatfetch

all: $(BIN)

$(BIN): $(SRC)
	$(CXX) $(CXXFLAGS) -o $(BIN) $(SRC) $(LDFLAGS)

clean:
	rm -f $(BIN)

install: $(BIN)
	install -Dm755 $(BIN) $(HOME)/.local/bin/$(BIN)

.PHONY: all clean install
