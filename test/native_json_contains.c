/* SPDX-License-Identifier: Apache-2.0 */
#include "sqlite3.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static sqlite3_stmt *statement;
static size_t checks;

static void fail(const char *message) { fprintf(stderr, "%s\n", message); exit(1); }

static void check_bytes(const char *source, int source_length, const char *needle,
                        int needle_length, int expected) {
  sqlite3_reset(statement);
  sqlite3_clear_bindings(statement);
  if (source) sqlite3_bind_text(statement, 1, source, source_length, SQLITE_TRANSIENT);
  if (needle) sqlite3_bind_text(statement, 2, needle, needle_length, SQLITE_TRANSIENT);
  int status = sqlite3_step(statement);
  if (expected == -2) {
    if (status != SQLITE_TOOBIG) fail("resource limit must explicitly refuse");
  } else if (status != SQLITE_ROW) fail(sqlite3_errmsg(sqlite3_db_handle(statement)));
  else if (expected == -1) {
    if (sqlite3_column_type(statement, 0) != SQLITE_NULL) fail("SQL NULL must propagate");
  } else if (expected != -3 && sqlite3_column_int(statement, 0) != expected) {
    fprintf(stderr, "wrong containment: %s contains %s (expected %d)\n", source, needle, expected);
    exit(1);
  }
  checks++;
}

static void check(const char *source, const char *needle, int expected) {
  check_bytes(source, source ? (int)strlen(source) : 0,
              needle, needle ? (int)strlen(needle) : 0, expected);
}

static char *array(size_t count, int reverse) {
  char *result = malloc(count * 16 + 3);
  if (!result) fail("allocation");
  size_t used = 0;
  result[used++] = '[';
  for (size_t i = 0; i < count; i++) {
    if (i) result[used++] = ',';
    used += (size_t)snprintf(result + used, count * 16 + 3 - used, "%zu", reverse ? count - i - 1 : i);
  }
  result[used++] = ']'; result[used] = 0;
  return result;
}

int main(int argc, char **argv) {
  if (argc != 2) fail("usage: native_json_contains extension-path");
  sqlite3 *database = NULL;
  if (sqlite3_open(":memory:", &database) != SQLITE_OK) fail("memory SQLite open");
  if (sqlite3_enable_load_extension(database, 1) != SQLITE_OK) fail("enable extension");
  char *error = NULL;
  if (sqlite3_load_extension(database, argv[1], "sqlite3_selectojson_init", &error) != SQLITE_OK)
    fail(error ? error : "extension load");
  if (sqlite3_enable_load_extension(database, 0) != SQLITE_OK) fail("disable extension");
  if (sqlite3_prepare_v2(database, "SELECT selecto_json_contains_exact_v1(?, ?)", -1,
                         &statement, NULL) != SQLITE_OK) fail("prepare comparator");

  check("{\"n\":1.0000000000000000001}", "{\"n\":1}", 0);
  check("{\"n\":9007199254740993.0}", "{\"n\":9007199254740993}", 1);
  check("9007199254740992.0", "9007199254740993", 0);
  check("1e-999999999999999999999999", "10e-1000000000000000000000000", 1);
  check("1e999999999999999999999999", "10e999999999999999999999998", 1);
  check("-0.000e999999999999999999999999", "0", 1);
  check("12300", "1.23e4", 1);
  check("0.0012300", "123e-5", 1);
  check("{\"a\":1,\"a\":2}", "{\"a\":1}", 0);
  check("{\"a\":2}", "{\"a\":1,\"a\":2}", 1);
  check("{\"a\":1,\"\\u0061\":2}", "{\"a\":2}", 1);
  check("{\"a\\u0000b\":1,\"a\":2}", "{\"a\\u0000b\":1}", 1);
  check("{\"\\ud83d\\ude00\":\"\\u6771\\u4eac\"}", "{\"😀\":\"東京\"}", 1);
  check("[null,true,1]", "true", 1);
  check("[1]", "true", 0);
  check("[[1]]", "1", 0);
  check("{\"a\":[1]}", "{\"a\":1}", 0);
  check("[1,2]", "[2,2]", 1);
  check("{}", "{}", 1);
  check("[]", "{}", 0);
  check(NULL, "{}", -1);
  check("{}", NULL, -1);

  const char *malformed[] = {"", " ", "01", "-", "1.", "1e", "1e+", "NaN",
    "Infinity", "true false", "[1,]", "{\"x\":1,}", "{1:2}", "\"\\ud800\"",
    "\"\\udc00\"", "\"\\ud800\\u0000\"", "\"\\x00\"", "\"\n\"", "\"\xc0\xaf\"",
    "\"\xed\xa0\x80\"", "\"\xf4\x90\x80\x80\"", "\"unterminated"};
  for (size_t i = 0; i < sizeof(malformed) / sizeof(*malformed); i++) {
    check(malformed[i], "{}", 0); check("{}", malformed[i], 0);
  }
  for (int i = -1000; i <= 1000; i++) {
    char source[64], needle[64];
    snprintf(source, sizeof(source), "%d00e-2", i);
    snprintf(needle, sizeof(needle), "%d.0000", i);
    /* -000 is outside JSON grammar; zero has its ordinary canonical form. */
    if (!i) strcpy(source, "0e-2");
    check(source, needle, 1);
    snprintf(needle, sizeof(needle), "%d", i + 1); check(source, needle, 0);
  }

  char depth[80];
  for (size_t i = 0; i < 32; i++) depth[i] = '[';
  depth[32] = '0';
  for (size_t i = 33; i < 65; i++) depth[i] = ']';
  depth[65] = 0;
  check(depth, depth, 1);
  memmove(depth + 1, depth, 66); depth[0] = '['; depth[66] = ']'; depth[67] = 0;
  check(depth, "[]", -2);

  char *large = malloc(1048578);
  if (!large) fail("allocation");
  memset(large, ' ', 1048577); large[0] = '0'; large[1048577] = 0;
  check_bytes(large, 1048576, "0", 1, 1);
  check_bytes(large, 1048577, "0", 1, -2);
  free(large);
  char *many = array(32766, 0); check(many, "[]", 1); free(many);
  many = array(32767, 0); check(many, "[]", -2); free(many);
  char *forward = array(3000, 0), *backward = array(3000, 1);
  check(forward, backward, -2); free(forward); free(backward);

  /* Deterministic malformed-byte fuzzing exercises parser boundaries and
   * cleanup after partially allocated trees under ASan/UBSan. */
  uint32_t state = 0x25bc192u;
  char bytes[128];
  for (size_t iteration = 0; iteration < 25000; iteration++) {
    state = state * 1664525u + 1013904223u;
    int length = (int)(state % sizeof(bytes));
    for (int i = 0; i < length; i++) {
      state = state * 1664525u + 1013904223u; bytes[i] = (char)(state >> 24);
    }
    check_bytes(bytes, length, "{}", 2, -3);
    check_bytes("{}", 2, bytes, length, -3);
  }
  const char seed[] = "{\"a\":[1,true,null,{\"x\":\"\\ud83d\\ude00\",\"n\":1.2500e-2}],\"a\":[{\"k\":2}]}";
  char mutation[sizeof(seed)];
  for (size_t iteration = 0; iteration < 10000; iteration++) {
    memcpy(mutation, seed, sizeof(seed));
    state = state * 1664525u + 1013904223u;
    int length = (int)(state % sizeof(seed));
    for (int edit = 0; edit < 3; edit++) {
      state = state * 1664525u + 1013904223u;
      mutation[state % (sizeof(seed) - 1)] = (char)(state >> 24);
    }
    check_bytes(mutation, length, "{}", 2, -3);
    check_bytes("{}", 2, mutation, length, -3);
  }
  sqlite3_finalize(statement);
  if (sqlite3_close(database) != SQLITE_OK) fail("SQLite close");
  printf("native exact JSON: %zu checks passed (memory SQLite)\n", checks);
  return 0;
}
