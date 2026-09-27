//! The only place libpq's C API is imported. Everything else uses `db.zig`,
//! so replacing the client means replacing `db.zig`'s internals and this file.

pub const c = @cImport(@cInclude("libpq-fe.h"));

/// PostgreSQL type OIDs checked by `Row.get` (see `pg_type.dat`).
pub const oid = struct {
    pub const bool_ = 16;
    pub const int8 = 20;
    pub const int2 = 21;
    pub const int4 = 23;
    pub const float4 = 700;
    pub const float8 = 701;
};
