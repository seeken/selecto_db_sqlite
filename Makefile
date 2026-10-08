MIX_APP_PATH ?= _build/dev/lib/selecto_db_sqlite
MIX_DEPS_PATH ?= deps
SQLITE_HEADERS ?= $(MIX_DEPS_PATH)/exqlite/c_src
CC ?= cc
CFLAGS ?= -O2
CFLAGS += -std=c11 -Wall -Wextra -Werror -pedantic -fPIC -fvisibility=hidden

ifeq ($(shell uname -s),Darwin)
SHARED_FLAGS = -dynamiclib -undefined dynamic_lookup
else
SHARED_FLAGS = -shared
endif

LIBRARY = $(MIX_APP_PATH)/priv/selecto_json_contains.so

.PHONY: all clean
all: $(LIBRARY)

$(LIBRARY): c_src/selecto_json.c $(SQLITE_HEADERS)/sqlite3ext.h $(SQLITE_HEADERS)/sqlite3.h Makefile
	mkdir -p "$(@D)"
	$(CC) $(CFLAGS) $(CPPFLAGS) -I"$(SQLITE_HEADERS)" $(SHARED_FLAGS) $(LDFLAGS) c_src/selecto_json.c -o "$@"

clean:
	rm -f "$(LIBRARY)"
