const std = @import("std");
const debug_log = @import("debug_log.zig");

const c = @cImport(@cInclude("sqlite3.h"));

// SQLITE_TRANSIENT is ((void(*)(void*))-1), which Zig's C translator can't handle.
// We link a tiny C helper instead.
extern fn cog_sqlite3_bind_text_transient(?*c.sqlite3_stmt, c_int, [*c]const u8, c_int) c_int;

pub const Error = error{
    SqliteError,
    SqliteBusy,
    SqliteConstraint,
    SqliteMisuse,
};

fn mapError(rc: c_int) Error {
    return switch (rc) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.SqliteBusy,
        c.SQLITE_CONSTRAINT, c.SQLITE_CONSTRAINT_UNIQUE, c.SQLITE_CONSTRAINT_PRIMARYKEY => error.SqliteConstraint,
        c.SQLITE_MISUSE => error.SqliteMisuse,
        else => error.SqliteError,
    };
}

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(path: [*:0]const u8) Error!Db {
        debug_log.log("sqlite: opening {s}", .{path});
        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path, &handle);
        if (rc != c.SQLITE_OK) {
            debug_log.log("sqlite: open failed rc={d}", .{rc});
            if (handle) |h| _ = c.sqlite3_close(h);
            return mapError(rc);
        }
        return .{ .handle = handle.? };
    }

    pub fn close(self: *Db) void {
        debug_log.log("sqlite: closing db", .{});
        _ = c.sqlite3_close(self.handle);
    }

    pub fn exec(self: *Db, sql: [*:0]const u8) Error!void {
        debug_log.log("sqlite: exec", .{});
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                debug_log.log("sqlite: exec error: {s}", .{msg});
                c.sqlite3_free(msg);
            }
            return mapError(rc);
        }
    }

    pub fn prepare(self: *Db, sql: [*:0]const u8) Error!Stmt {
        var stmt_handle: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt_handle, null);
        if (rc != c.SQLITE_OK) {
            debug_log.log("sqlite: prepare failed rc={d}", .{rc});
            return mapError(rc);
        }
        return .{ .handle = stmt_handle.? };
    }

    pub fn lastInsertRowId(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    pub fn changes(self: *Db) c_int {
        return c.sqlite3_changes(self.handle);
    }

    pub fn errmsg(self: *Db) []const u8 {
        const msg = c.sqlite3_errmsg(self.handle);
        return std.mem.span(msg);
    }
};

pub const StepResult = enum { row, done };

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    pub fn bindText(self: *Stmt, col: c_int, text: []const u8) Error!void {
        const rc = cog_sqlite3_bind_text_transient(self.handle, col, text.ptr, @intCast(text.len));
        if (rc != c.SQLITE_OK) return mapError(rc);
    }

    pub fn bindInt(self: *Stmt, col: c_int, val: i64) Error!void {
        const rc = c.sqlite3_bind_int64(self.handle, col, val);
        if (rc != c.SQLITE_OK) return mapError(rc);
    }

    pub fn bindReal(self: *Stmt, col: c_int, val: f64) Error!void {
        const rc = c.sqlite3_bind_double(self.handle, col, val);
        if (rc != c.SQLITE_OK) return mapError(rc);
    }

    pub fn bindNull(self: *Stmt, col: c_int) Error!void {
        const rc = c.sqlite3_bind_null(self.handle, col);
        if (rc != c.SQLITE_OK) return mapError(rc);
    }

    pub fn step(self: *Stmt) Error!StepResult {
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) return .row;
        if (rc == c.SQLITE_DONE) return .done;
        return mapError(rc);
    }

    pub fn columnText(self: *Stmt, col: c_int) ?[]const u8 {
        const ptr = c.sqlite3_column_text(self.handle, col);
        if (ptr == null) return null;
        const len = c.sqlite3_column_bytes(self.handle, col);
        if (len <= 0) return "";
        return ptr[0..@intCast(len)];
    }

    pub fn columnInt(self: *Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, col);
    }

    pub fn columnReal(self: *Stmt, col: c_int) f64 {
        return c.sqlite3_column_double(self.handle, col);
    }

    pub fn columnCount(self: *Stmt) c_int {
        return c.sqlite3_column_count(self.handle);
    }

    pub fn reset(self: *Stmt) Error!void {
        const rc = c.sqlite3_reset(self.handle);
        if (rc != c.SQLITE_OK) return mapError(rc);
    }

    pub fn finalize(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "open in-memory db, create table, insert and select" {
    var db = try Db.open(":memory:");
    defer db.close();

    try db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT, value REAL)");

    {
        var stmt = try db.prepare("INSERT INTO test (name, value) VALUES (?, ?)");
        defer stmt.finalize();
        try stmt.bindText(1, "hello");
        try stmt.bindReal(2, 3.14);
        const r = try stmt.step();
        try std.testing.expectEqual(StepResult.done, r);
    }

    const row_id = db.lastInsertRowId();
    try std.testing.expectEqual(@as(i64, 1), row_id);

    {
        var stmt = try db.prepare("SELECT id, name, value FROM test WHERE id = ?");
        defer stmt.finalize();
        try stmt.bindInt(1, 1);
        const r = try stmt.step();
        try std.testing.expectEqual(StepResult.row, r);
        try std.testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
        try std.testing.expectEqualStrings("hello", stmt.columnText(1).?);
        try std.testing.expectApproxEqRel(@as(f64, 3.14), stmt.columnReal(2), 0.001);
    }
}

test "exec error on bad SQL" {
    var db = try Db.open(":memory:");
    defer db.close();
    const result = db.exec("THIS IS NOT SQL");
    try std.testing.expectError(error.SqliteError, result);
}

test "prepare error on bad SQL" {
    var db = try Db.open(":memory:");
    defer db.close();
    const result = db.prepare("SELECT * FROM nonexistent");
    try std.testing.expectError(error.SqliteError, result);
}

test "bind null" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (a TEXT)");
    var stmt = try db.prepare("INSERT INTO t VALUES (?)");
    defer stmt.finalize();
    try stmt.bindNull(1);
    try std.testing.expectEqual(StepResult.done, try stmt.step());
}

test "changes count" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (a INTEGER)");
    try db.exec("INSERT INTO t VALUES (1)");
    try db.exec("INSERT INTO t VALUES (2)");
    try db.exec("INSERT INTO t VALUES (3)");
    try db.exec("DELETE FROM t WHERE a > 1");
    try std.testing.expectEqual(@as(c_int, 2), db.changes());
}

test "column count" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (a INTEGER, b TEXT, c REAL)");
    var stmt = try db.prepare("SELECT * FROM t");
    defer stmt.finalize();
    try std.testing.expectEqual(@as(c_int, 3), stmt.columnCount());
}

test "stmt reset allows re-execution" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (v INTEGER)");
    try db.exec("INSERT INTO t VALUES (10)");
    try db.exec("INSERT INTO t VALUES (20)");

    var stmt = try db.prepare("SELECT v FROM t ORDER BY v");
    defer stmt.finalize();

    // First pass
    try std.testing.expectEqual(StepResult.row, try stmt.step());
    try std.testing.expectEqual(@as(i64, 10), stmt.columnInt(0));
    try std.testing.expectEqual(StepResult.row, try stmt.step());

    // Reset and re-read
    try stmt.reset();
    try std.testing.expectEqual(StepResult.row, try stmt.step());
    try std.testing.expectEqual(@as(i64, 10), stmt.columnInt(0));
}
