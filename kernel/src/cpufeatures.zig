// Unified CPU feature layer. Each arch's `arch.features` reports two views of the
// optional hardware features (FP/SIMD, virtualization, crypto, atomics, wide
// vectors): what the build-time -Dcpu target enabled (comptimeSet) and what the
// silicon actually reports at boot (detect, via ID registers / CPUID / misa).
// The -Dcpu-features policy decides which view the kernel's runtime gates trust.
const arch = @import("arch");
const options = @import("kernel-options");

pub const Features = arch.features.Features;

var eff: Features = .{};
var ready = false;

// Per-feature merge of detected vs build-time, honoring the policy. A field is
// `?bool`: null means "that view doesn't know", so `auto` can fall back.
fn pick(det: ?bool, fix: ?bool) ?bool {
    return switch (options.cpu_features) {
        .fixed => fix,
        .detect => det,
        .auto => if (det != null) det else fix,
    };
}

pub fn init() void {
    const det = arch.features.detect();
    const fix = arch.features.comptimeSet();
    inline for (@typeInfo(Features).@"struct".fields) |f| {
        @field(eff, f.name) = pick(@field(det, f.name), @field(fix, f.name));
    }
    ready = true;
    report(det, fix);
}

/// Whether an optional feature should be used at runtime (false until init()).
pub fn has(comptime name: []const u8) bool {
    return (@field(eff, name) orelse false);
}

pub fn fp() bool {
    return has("fp");
}
pub fn simd() bool {
    return has("simd");
}
pub fn hypervisor() bool {
    return has("hypervisor");
}

fn report(det: Features, fix: Features) void {
    arch.uart.print("[cpu] features (policy={s}):", .{@tagName(options.cpu_features)});
    inline for (@typeInfo(Features).@"struct".fields) |f| {
        if (@field(eff, f.name) orelse false) arch.uart.print(" {s}", .{f.name});
    }
    arch.uart.print("\n", .{});
    // Warn on a mismatch the compiler can't recover from: -Dcpu assumed a feature
    // the silicon lacks, so emitted instructions for it would fault.
    inline for (@typeInfo(Features).@"struct".fields) |f| {
        if ((@field(fix, f.name) orelse false) and @field(det, f.name) == false) {
            arch.uart.print("[cpu] WARNING: -Dcpu enabled '{s}' but the CPU does not report it\n", .{f.name});
        }
    }
}
