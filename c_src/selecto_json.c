/* SPDX-License-Identifier: Apache-2.0
 * Adapter-owned exact JSON containment. Numbers retain their original decimal
 * tokens; no SQLite REAL or host floating-point conversion occurs.
 */
#include "sqlite3ext.h"
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Several Exqlite connections can install this library concurrently. Keep
 * SQLite's shared API pointer atomic across initialization and callback use. */
static _Atomic(const sqlite3_api_routines *) sqlite3_api;

#define MAX_INPUT ((size_t)1048576)
#define MAX_NODES ((size_t)32768)
#define MAX_MEMORY ((size_t)16777216)
#define MAX_WORK ((size_t)8388608)
#define MAX_DEPTH 32

enum { VALID = 0, MALFORMED = 1, LIMITED = 2, NO_MEMORY = 3 };
enum { J_NULL, J_FALSE, J_TRUE, J_NUMBER, J_STRING, J_ARRAY, J_OBJECT };

typedef struct { const unsigned char *data; size_t length; } Span;
typedef struct Block { struct Block *next; unsigned char bytes[]; } Block;
typedef struct Node {
  struct Node *allocation_next, *next, *children;
  int type, sign, exponent_sign;
  Span text, key, exponent;
} Node;
typedef struct { size_t nodes, memory, work; int status; } Budget;
typedef struct {
  const unsigned char *input;
  size_t length, position;
  Budget *budget;
  Node *nodes;
  Block *blocks;
} Parser;

static int spend(Budget *budget, size_t work) {
  if (budget->status != VALID) return 0;
  if (work > budget->work) { budget->status = LIMITED; return 0; }
  budget->work -= work;
  return 1;
}

static void *allocate(Parser *parser, size_t length) {
  Budget *budget = parser->budget;
  if (length > MAX_MEMORY - budget->memory) { budget->status = LIMITED; return NULL; }
  void *result = malloc(length);
  if (!result) { budget->status = NO_MEMORY; return NULL; }
  budget->memory += length;
  return result;
}

static unsigned char *buffer(Parser *parser, size_t length) {
  if (length > MAX_INPUT + 32) { parser->budget->status = LIMITED; return NULL; }
  Block *block = allocate(parser, sizeof(Block) + length);
  if (!block) return NULL;
  block->next = parser->blocks;
  parser->blocks = block;
  return block->bytes;
}

static Node *new_node(Parser *parser, int type) {
  if (!spend(parser->budget, 1)) return NULL;
  if (++parser->budget->nodes > MAX_NODES) { parser->budget->status = LIMITED; return NULL; }
  Node *node = allocate(parser, sizeof(Node));
  if (!node) return NULL;
  memset(node, 0, sizeof(Node));
  node->type = type;
  node->allocation_next = parser->nodes;
  parser->nodes = node;
  return node;
}

static void release(Parser *parser) {
  while (parser->nodes) {
    Node *next = parser->nodes->allocation_next;
    free(parser->nodes); parser->nodes = next;
  }
  while (parser->blocks) {
    Block *next = parser->blocks->next;
    free(parser->blocks); parser->blocks = next;
  }
}

static int whitespace(Parser *parser) {
  while (parser->position < parser->length) {
    unsigned char c = parser->input[parser->position];
    if (c != ' ' && c != '\t' && c != '\n' && c != '\r') break;
    if (!spend(parser->budget, 1)) return 0;
    parser->position++;
  }
  return 1;
}

static int digit(unsigned char c) { return c >= '0' && c <= '9'; }
static int hex(unsigned char c) {
  if (digit(c)) return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

static int code_unit(Parser *parser, size_t *position, size_t end, uint32_t *value) {
  if (end - *position < 4 || !spend(parser->budget, 4)) return 0;
  *value = 0;
  for (int i = 0; i < 4; i++) {
    int h = hex(parser->input[(*position)++]);
    if (h < 0) return 0;
    *value = (*value << 4) | (uint32_t)h;
  }
  return 1;
}

static size_t emit_utf8(unsigned char *output, uint32_t codepoint) {
  if (codepoint < 0x80) { output[0] = (unsigned char)codepoint; return 1; }
  if (codepoint < 0x800) {
    output[0] = (unsigned char)(0xc0 | (codepoint >> 6));
    output[1] = (unsigned char)(0x80 | (codepoint & 63)); return 2;
  }
  if (codepoint < 0x10000) {
    output[0] = (unsigned char)(0xe0 | (codepoint >> 12));
    output[1] = (unsigned char)(0x80 | ((codepoint >> 6) & 63));
    output[2] = (unsigned char)(0x80 | (codepoint & 63)); return 3;
  }
  output[0] = (unsigned char)(0xf0 | (codepoint >> 18));
  output[1] = (unsigned char)(0x80 | ((codepoint >> 12) & 63));
  output[2] = (unsigned char)(0x80 | ((codepoint >> 6) & 63));
  output[3] = (unsigned char)(0x80 | (codepoint & 63)); return 4;
}

/* Decode once into a length-bearing byte span; embedded escaped NUL is valid. */
static int string(Parser *parser, Span *result) {
  if (parser->position >= parser->length || parser->input[parser->position] != '"') return 0;
  size_t begin = ++parser->position, end = begin;
  while (end < parser->length && parser->input[end] != '"') {
    if (!spend(parser->budget, 1)) return 0;
    if (parser->input[end++] == '\\') {
      if (end == parser->length) return 0;
      end++;
    }
  }
  if (end == parser->length) return 0;
  unsigned char *decoded = buffer(parser, end - begin + 1);
  if (!decoded) return 0;
  size_t position = begin, used = 0;
  while (position < end) {
    if (!spend(parser->budget, 1)) return 0;
    unsigned char c = parser->input[position++];
    if (c < 0x20) return 0;
    if (c == '\\') {
      if (position == end) return 0;
      c = parser->input[position++];
      switch (c) {
        case '"': case '\\': case '/': decoded[used++] = c; break;
        case 'b': decoded[used++] = '\b'; break;
        case 'f': decoded[used++] = '\f'; break;
        case 'n': decoded[used++] = '\n'; break;
        case 'r': decoded[used++] = '\r'; break;
        case 't': decoded[used++] = '\t'; break;
        case 'u': {
          uint32_t value, low;
          if (!code_unit(parser, &position, end, &value)) return 0;
          if (value >= 0xd800 && value <= 0xdbff) {
            if (end - position < 6 || parser->input[position] != '\\' || parser->input[position + 1] != 'u') return 0;
            position += 2;
            if (!code_unit(parser, &position, end, &low) || low < 0xdc00 || low > 0xdfff) return 0;
            value = 0x10000 + ((value - 0xd800) << 10) + low - 0xdc00;
          } else if (value >= 0xdc00 && value <= 0xdfff) return 0;
          used += emit_utf8(decoded + used, value); break;
        }
        default: return 0;
      }
    } else if (c < 0x80) decoded[used++] = c;
    else {
      size_t extra;
      uint32_t value, minimum;
      if (c >= 0xc2 && c <= 0xdf) { extra = 1; value = c & 31; minimum = 0x80; }
      else if (c >= 0xe0 && c <= 0xef) { extra = 2; value = c & 15; minimum = 0x800; }
      else if (c >= 0xf0 && c <= 0xf4) { extra = 3; value = c & 7; minimum = 0x10000; }
      else return 0;
      if (end - position < extra || !spend(parser->budget, extra)) return 0;
      for (size_t i = 0; i < extra; i++) {
        unsigned char next = parser->input[position++];
        if ((next & 0xc0) != 0x80) return 0;
        value = (value << 6) | (next & 63);
      }
      if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return 0;
      used += emit_utf8(decoded + used, value);
    }
  }
  decoded[used] = 0;
  *result = (Span){decoded, used};
  parser->position = end + 1;
  return 1;
}

static int equal(Budget *budget, Span left, Span right) {
  if (!spend(budget, 1)) return 0;
  return left.length == right.length && spend(budget, left.length)
      && (left.length == 0 || memcmp(left.data, right.data, left.length) == 0);
}

static Span trim_zeros(Span value) {
  while (value.length > 1 && *value.data == '0') { value.data++; value.length--; }
  return value;
}

/* Add a bounded mantissa offset to an arbitrarily long signed decimal exponent.
 * Both are digit strings, avoiding exponent overflow as well as REAL rounding. */
static int exponent(Parser *parser, Node *node, Span raw, int raw_sign, int64_t adjustment) {
  unsigned char small[32];
  size_t small_length = 0;
  uint64_t amount = (uint64_t)(adjustment < 0 ? -adjustment : adjustment);
  do { small[sizeof(small) - 1 - small_length++] = (unsigned char)('0' + amount % 10); amount /= 10; } while (amount);
  Span add = {small + sizeof(small) - small_length, small_length};
  raw = trim_zeros(raw);
  if (raw.length == 1 && raw.data[0] == '0') raw_sign = 0;
  int add_sign = adjustment == 0 ? 0 : adjustment < 0 ? -1 : 1;
  size_t capacity = (raw.length > add.length ? raw.length : add.length) + 1;
  unsigned char *result = buffer(parser, capacity);
  if (!result || !spend(parser->budget, capacity * 2)) return 0;
  size_t used = capacity, a = raw.length, b = add.length;
  if (raw_sign == add_sign || !raw_sign || !add_sign) {
    int carry = 0;
    while (a || b || carry) {
      int value = carry + (a ? raw.data[--a] - '0' : 0) + (b ? add.data[--b] - '0' : 0);
      result[--used] = (unsigned char)('0' + value % 10); carry = value / 10;
    }
    node->exponent_sign = raw_sign ? raw_sign : add_sign;
  } else {
    int comparison = raw.length > add.length ? 1 : raw.length < add.length ? -1 : memcmp(raw.data, add.data, raw.length);
    Span large = comparison >= 0 ? raw : add, little = comparison >= 0 ? add : raw;
    a = large.length; b = little.length;
    int borrow = 0;
    while (a) {
      int value = large.data[--a] - '0' - borrow - (b ? little.data[--b] - '0' : 0);
      borrow = value < 0;
      result[--used] = (unsigned char)('0' + value + (borrow ? 10 : 0));
    }
    node->exponent_sign = comparison >= 0 ? raw_sign : add_sign;
  }
  node->exponent = trim_zeros((Span){result + used, capacity - used});
  if (node->exponent.length == 1 && node->exponent.data[0] == '0') node->exponent_sign = 0;
  return 1;
}

static Node *number(Parser *parser) {
  size_t begin = parser->position;
  int sign = 1;
  if (parser->input[parser->position] == '-') { sign = -1; parser->position++; }
  size_t integer = parser->position;
  if (integer == parser->length || !digit(parser->input[integer])) return NULL;
  if (parser->input[integer] == '0') parser->position++;
  else while (parser->position < parser->length && digit(parser->input[parser->position])) parser->position++;
  size_t integer_end = parser->position, fraction = integer_end, fraction_end = fraction;
  if (parser->position < parser->length && parser->input[parser->position] == '.') {
    fraction = ++parser->position;
    while (parser->position < parser->length && digit(parser->input[parser->position])) parser->position++;
    fraction_end = parser->position;
    if (fraction == fraction_end) return NULL;
  }
  static const unsigned char zero[] = "0";
  Span power = {zero, 1};
  int power_sign = 0;
  if (parser->position < parser->length && (parser->input[parser->position] == 'e' || parser->input[parser->position] == 'E')) {
    parser->position++; power_sign = 1;
    if (parser->position < parser->length && (parser->input[parser->position] == '-' || parser->input[parser->position] == '+'))
      power_sign = parser->input[parser->position++] == '-' ? -1 : 1;
    size_t start = parser->position;
    while (parser->position < parser->length && digit(parser->input[parser->position])) parser->position++;
    if (start == parser->position) return NULL;
    power = (Span){parser->input + start, parser->position - start};
  }
  if (!spend(parser->budget, (parser->position - begin) * 3)) return NULL;
  Node *node = new_node(parser, J_NUMBER);
  if (!node) return NULL;
  size_t count = integer_end - integer + fraction_end - fraction;
  unsigned char *digits = buffer(parser, count);
  if (!digits) return NULL;
  memcpy(digits, parser->input + integer, integer_end - integer);
  memcpy(digits + integer_end - integer, parser->input + fraction, fraction_end - fraction);
  size_t first = 0, last = count;
  while (first < count && digits[first] == '0') first++;
  if (first == count) {
    node->text = (Span){zero, 1}; node->exponent = (Span){zero, 1}; return node;
  }
  while (last > first && digits[last - 1] == '0') last--;
  node->sign = sign;
  node->text = (Span){digits + first, last - first};
  int64_t adjustment = (int64_t)(count - last) - (int64_t)(fraction_end - fraction);
  return exponent(parser, node, power, power_sign, adjustment) ? node : NULL;
}

static Node *value(Parser *parser, unsigned depth) {
  if (depth > MAX_DEPTH) { parser->budget->status = LIMITED; return NULL; }
  if (!whitespace(parser) || parser->position == parser->length || !spend(parser->budget, 1)) return NULL;
  unsigned char c = parser->input[parser->position];
  if (c == '-' || digit(c)) return number(parser);
  if (c == '"') {
    Node *node = new_node(parser, J_STRING);
    return node && string(parser, &node->text) ? node : NULL;
  }
  if (c == '[' || c == '{') {
    int object = c == '{';
    Node *node = new_node(parser, object ? J_OBJECT : J_ARRAY);
    if (!node) return NULL;
    parser->position++;
    if (!whitespace(parser) || parser->position == parser->length) return NULL;
    unsigned char closing = object ? '}' : ']';
    if (parser->input[parser->position] == closing) { parser->position++; return node; }
    Node **tail = &node->children;
    while (parser->budget->status == VALID) {
      Span key = {NULL, 0};
      if (object && (!string(parser, &key) || !whitespace(parser) || parser->position == parser->length || parser->input[parser->position++] != ':')) return NULL;
      Node *child = value(parser, depth + 1);
      if (!child) return NULL;
      child->key = key; *tail = child; tail = &child->next;
      if (!whitespace(parser) || parser->position == parser->length) return NULL;
      c = parser->input[parser->position++];
      if (c == closing) return node;
      if (c != ',' || !whitespace(parser)) return NULL;
    }
    return NULL;
  }
  const char *literal = c == 'n' ? "null" : c == 't' ? "true" : c == 'f' ? "false" : "";
  size_t length = strlen(literal);
  if (!length || parser->length - parser->position < length || memcmp(parser->input + parser->position, literal, length) != 0 || !spend(parser->budget, length)) return NULL;
  parser->position += length;
  return new_node(parser, c == 'n' ? J_NULL : c == 't' ? J_TRUE : J_FALSE);
}

static Node *document(Parser *parser) {
  Node *root = value(parser, 0);
  if (!root || !whitespace(parser) || parser->position != parser->length) {
    if (parser->budget->status == VALID) parser->budget->status = MALFORMED;
    return NULL;
  }
  return root;
}

static int contains(Budget *budget, const Node *source, const Node *needle, int root) {
  if (!spend(budget, 1)) return 0;
  if (root && source->type == J_ARRAY && needle->type < J_ARRAY) {
    for (const Node *member = source->children; member && budget->status == VALID; member = member->next)
      if (contains(budget, member, needle, 0)) return 1;
    return 0;
  }
  if (source->type != needle->type) return 0;
  switch (needle->type) {
    case J_NULL: case J_FALSE: case J_TRUE: return 1;
    case J_STRING: return equal(budget, source->text, needle->text);
    case J_NUMBER:
      return source->sign == needle->sign && equal(budget, source->text, needle->text)
          && source->exponent_sign == needle->exponent_sign && equal(budget, source->exponent, needle->exponent);
    case J_ARRAY:
      for (const Node *wanted = needle->children; wanted && budget->status == VALID; wanted = wanted->next) {
        int found = 0;
        for (const Node *member = source->children; member && budget->status == VALID; member = member->next)
          if (contains(budget, member, wanted, 0)) { found = 1; break; }
        if (!found) return 0;
      }
      return budget->status == VALID;
    case J_OBJECT:
      for (const Node *wanted = needle->children; wanted && budget->status == VALID; wanted = wanted->next) {
        int superseded = 0;
        for (const Node *later = wanted->next; later && budget->status == VALID; later = later->next)
          if (equal(budget, wanted->key, later->key)) { superseded = 1; break; }
        if (superseded) continue;
        const Node *last = NULL;
        for (const Node *member = source->children; member && budget->status == VALID; member = member->next)
          if (equal(budget, wanted->key, member->key)) last = member;
        if (!last || !contains(budget, last, wanted, 0)) return 0;
      }
      return budget->status == VALID;
    default: return 0;
  }
}

static void json_contains(sqlite3_context *context, int argc, sqlite3_value **argv) {
  (void)argc;
  if (sqlite3_value_type(argv[0]) == SQLITE_NULL || sqlite3_value_type(argv[1]) == SQLITE_NULL) { sqlite3_result_null(context); return; }
  int source_length = sqlite3_value_bytes(argv[0]), needle_length = sqlite3_value_bytes(argv[1]);
  if ((size_t)source_length > MAX_INPUT || (size_t)needle_length > MAX_INPUT) {
    sqlite3_result_error(context, "selecto_json_contains: input byte limit exceeded", -1);
    sqlite3_result_error_code(context, SQLITE_TOOBIG); return;
  }
  const unsigned char *source_text = sqlite3_value_text(argv[0]), *needle_text = sqlite3_value_text(argv[1]);
  if (!source_text || !needle_text) { sqlite3_result_error_nomem(context); return; }
  Budget budget = {0, 0, MAX_WORK, VALID};
  Parser source = {source_text, (size_t)source_length, 0, &budget, NULL, NULL};
  Parser needle = {needle_text, (size_t)needle_length, 0, &budget, NULL, NULL};
  Node *left = document(&source), *right = NULL;
  if (left) right = document(&needle);
  int result = left && right && contains(&budget, left, right, 1);
  release(&source); release(&needle);
  if (budget.status == NO_MEMORY) sqlite3_result_error_nomem(context);
  else if (budget.status == LIMITED) {
    sqlite3_result_error(context, "selecto_json_contains: depth, nodes, memory or comparison work limit exceeded", -1);
    sqlite3_result_error_code(context, SQLITE_TOOBIG);
  } else sqlite3_result_int(context, result);
}

#if defined(_WIN32)
__declspec(dllexport)
#else
__attribute__((visibility("default")))
#endif
int sqlite3_selectojson_init(sqlite3 *database, char **error, const sqlite3_api_routines *api) {
  (void)error;
  SQLITE_EXTENSION_INIT2(api);
  return sqlite3_create_function_v2(database, "selecto_json_contains_exact_v1", 2,
      SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS, NULL, json_contains, NULL, NULL, NULL);
}
