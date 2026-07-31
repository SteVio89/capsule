/* SQLITE_TRANSIENT is `((sqlite3_destructor_type)-1)`: a sentinel sqlite compares against
 * and never calls. Zig cannot express it — `@ptrFromInt` onto a function-pointer type
 * rejects the unaligned address at comptime, and in Debug the runtime alignment check
 * rejects it again. Both refusals are correct; the value is not a real pointer.
 *
 * Rather than fight that with casts, the two binds that need a copy live here, where the
 * sentinel is ordinary C. The alternative was binding with SQLITE_STATIC and promising
 * every bound slice outlives its statement — a lifetime contract that would be broken
 * quietly the first time a caller passed a temporary.
 */

#include <sqlite3.h>

int capsule_bind_text(sqlite3_stmt *stmt, int index, const char *data, sqlite3_uint64 len) {
  return sqlite3_bind_text64(stmt, index, data, len, SQLITE_TRANSIENT, SQLITE_UTF8);
}

int capsule_bind_blob(sqlite3_stmt *stmt, int index, const void *data, sqlite3_uint64 len) {
  return sqlite3_bind_blob64(stmt, index, data, len, SQLITE_TRANSIENT);
}
