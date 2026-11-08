/* Accès à SQLite sous Linux.
 * Si le paquet de développement (libsqlite3-dev) est installé, son en-tête est
 * utilisé. Sinon, les seules fonctions dont Photothèque a besoin sont déclarées
 * ici (API stable de SQLite 3) : il suffit alors de la bibliothèque partagée
 * libsqlite3.so.0, présente sur toutes les distributions. */
#ifndef PHOTOTHEQUE_CSQLITE_SHIM_H
#define PHOTOTHEQUE_CSQLITE_SHIM_H

#if __has_include(<sqlite3.h>)
#include <sqlite3.h>
#else

typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
typedef long long sqlite3_int64;
typedef void (*sqlite3_destructor_type)(void *);

#define SQLITE_OK 0
#define SQLITE_ROW 100
#define SQLITE_DONE 101
#define SQLITE_INTEGER 1
#define SQLITE_FLOAT 2
#define SQLITE_TEXT 3
#define SQLITE_BLOB 4
#define SQLITE_NULL 5
#define SQLITE_OPEN_READONLY 0x00000001
#define SQLITE_OPEN_READWRITE 0x00000002
#define SQLITE_OPEN_CREATE 0x00000004
#define SQLITE_OPEN_FULLMUTEX 0x00010000

const char *sqlite3_libversion(void);
int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
int sqlite3_close_v2(sqlite3 *);
const char *sqlite3_errmsg(sqlite3 *);
int sqlite3_exec(sqlite3 *, const char *sql, int (*callback)(void *, int, char **, char **), void *, char **errmsg);
void sqlite3_free(void *);
int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
int sqlite3_step(sqlite3_stmt *);
int sqlite3_reset(sqlite3_stmt *);
int sqlite3_finalize(sqlite3_stmt *);
int sqlite3_bind_parameter_count(sqlite3_stmt *);
int sqlite3_bind_null(sqlite3_stmt *, int);
int sqlite3_bind_int64(sqlite3_stmt *, int, sqlite3_int64);
int sqlite3_bind_double(sqlite3_stmt *, int, double);
int sqlite3_bind_text(sqlite3_stmt *, int, const char *, int, void (*)(void *));
int sqlite3_bind_blob(sqlite3_stmt *, int, const void *, int, void (*)(void *));
int sqlite3_column_count(sqlite3_stmt *);
const char *sqlite3_column_name(sqlite3_stmt *, int);
int sqlite3_column_type(sqlite3_stmt *, int);
sqlite3_int64 sqlite3_column_int64(sqlite3_stmt *, int);
double sqlite3_column_double(sqlite3_stmt *, int);
const unsigned char *sqlite3_column_text(sqlite3_stmt *, int);
const void *sqlite3_column_blob(sqlite3_stmt *, int);
int sqlite3_column_bytes(sqlite3_stmt *, int);
int sqlite3_changes(sqlite3 *);
sqlite3_int64 sqlite3_last_insert_rowid(sqlite3 *);

#endif
#endif
