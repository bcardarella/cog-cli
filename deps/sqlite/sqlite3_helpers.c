#include "sqlite3.h"

int cog_sqlite3_bind_text_transient(
    sqlite3_stmt *stmt, int col, const char *text, int len)
{
    return sqlite3_bind_text(stmt, col, text, len, SQLITE_TRANSIENT);
}
