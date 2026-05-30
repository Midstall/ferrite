//! <ctype.h>. ASCII-only, POSIX locale semantics. All predicates
//! return 0/non-zero `c_int` so the C `if (isdigit(c)) ...` idiom works.

export fn isspace(c: c_int) c_int {
    return @intFromBool(switch (c) {
        ' ', '\t', '\n', '\r', 11, 12 => true,
        else => false,
    });
}

export fn isalpha(c: c_int) c_int {
    return @intFromBool((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z'));
}

export fn isdigit(c: c_int) c_int {
    return @intFromBool(c >= '0' and c <= '9');
}

export fn isxdigit(c: c_int) c_int {
    return @intFromBool((c >= '0' and c <= '9') or (c >= 'A' and c <= 'F') or (c >= 'a' and c <= 'f'));
}

export fn isalnum(c: c_int) c_int {
    return @intFromBool(isalpha(c) != 0 or isdigit(c) != 0);
}

export fn isupper(c: c_int) c_int {
    return @intFromBool(c >= 'A' and c <= 'Z');
}

export fn islower(c: c_int) c_int {
    return @intFromBool(c >= 'a' and c <= 'z');
}

export fn ispunct(c: c_int) c_int {
    return @intFromBool(switch (c) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/' => true,
        ':', ';', '<', '=', '>', '?', '@' => true,
        '[', '\\', ']', '^', '_', '`' => true,
        '{', '|', '}', '~' => true,
        else => false,
    });
}

export fn iscntrl(c: c_int) c_int {
    return @intFromBool(c < 0x20 or c == 0x7f);
}

export fn isprint(c: c_int) c_int {
    return @intFromBool(c >= 0x20 and c < 0x7f);
}

export fn isgraph(c: c_int) c_int {
    return @intFromBool(c > 0x20 and c < 0x7f);
}

export fn isblank(c: c_int) c_int {
    return @intFromBool(c == ' ' or c == '\t');
}

export fn toupper(c: c_int) c_int {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

export fn tolower(c: c_int) c_int {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
