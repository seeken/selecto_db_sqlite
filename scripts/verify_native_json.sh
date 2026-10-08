#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_build=$(mktemp -d "${TMPDIR:-/tmp}/selecto-native-json.XXXXXX")
trap 'rm -rf "$task_build"' EXIT HUP INT TERM
headers=${SQLITE_HEADERS:-${MIX_DEPS_PATH:-$root/deps}/exqlite/c_src}
compiler=${CC:-clang}
flags='-std=c11 -O1 -g -Wall -Wextra -Werror -pedantic -fno-omit-frame-pointer -fsanitize=address,undefined'
sqlite_library=${SQLITE_LIB_DIR:-}
if [ -z "$sqlite_library" ] && [ -d /opt/homebrew/opt/sqlite/lib ]; then
  sqlite_library=/opt/homebrew/opt/sqlite/lib
fi

make -C "$root" CC="$compiler" SQLITE_HEADERS="$headers" MIX_APP_PATH="$task_build" \
  CFLAGS="$flags -fPIC -fvisibility=hidden"
# The standalone consumer uses only an in-memory SQLite database.
if [ -n "$sqlite_library" ]; then
  "$compiler" $flags -I"$headers" "$root/test/native_json_contains.c" \
    -L"$sqlite_library" -Wl,-rpath,"$sqlite_library" -lsqlite3 -o "$task_build/native_json_contains"
else
  "$compiler" $flags -I"$headers" "$root/test/native_json_contains.c" -lsqlite3 \
    -o "$task_build/native_json_contains"
fi
"$task_build/native_json_contains" "$task_build/priv/selecto_json_contains.so"
