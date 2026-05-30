// A tiny software synthesizer: band-limited-ish oscillators + ADSR envelopes +
// a multi-voice mixer, driven by a row sequencer. No MIDI, no samples - the
// score is plain data (a chord progression + a lead line) and every sample is
// computed here. This is the audio half of the RT showcase: render() produces
// one period of PCM per call on the playback deadline.

const std = @import("std");

pub const RATE: u32 = 44100;
const TAU: f32 = std.math.tau;

pub const Wave = enum { sine, square, saw, triangle, noise };

// One sounding voice: an oscillator shaped by an ADSR envelope.
const Voice = struct {
    wave: Wave = .square,
    phase: f32 = 0,
    inc: f32 = 0,
    gain: f32 = 0,
    // ADSR levels/rates are per-sample deltas computed at note-on.
    env: f32 = 0,
    stage: Stage = .idle,
    a_rate: f32 = 0,
    d_rate: f32 = 0,
    sustain: f32 = 0,
    r_rate: f32 = 0,
    rng: u32 = 0x2463534,

    const Stage = enum { idle, attack, decay, sustain, release };

    fn on(self: *Voice, freq: f32, wave: Wave, gain: f32, a_ms: f32, d_ms: f32, sus: f32, r_ms: f32) void {
        self.wave = wave;
        self.inc = freq / @as(f32, RATE);
        self.gain = gain;
        self.sustain = sus;
        self.a_rate = if (a_ms <= 0) 1.0 else 1.0 / (a_ms * 0.001 * @as(f32, RATE));
        self.d_rate = if (d_ms <= 0) 1.0 else (1.0 - sus) / (d_ms * 0.001 * @as(f32, RATE));
        self.r_rate = if (r_ms <= 0) 1.0 else sus / (r_ms * 0.001 * @as(f32, RATE));
        self.stage = .attack;
        // keep self.phase for click-free retrigger
    }

    fn off(self: *Voice) void {
        if (self.stage != .idle) self.stage = .release;
    }

    fn osc(self: *Voice) f32 {
        const p = self.phase;
        const v: f32 = switch (self.wave) {
            .sine => @sin(p * TAU),
            .square => if (p < 0.5) 1.0 else -1.0,
            .saw => 2.0 * p - 1.0,
            .triangle => if (p < 0.5) 4.0 * p - 1.0 else 3.0 - 4.0 * p,
            .noise => blk: {
                self.rng = self.rng *% 1664525 +% 1013904223;
                break :blk 2.0 * (@as(f32, @floatFromInt(self.rng >> 9)) / @as(f32, 1 << 23)) - 1.0;
            },
        };
        self.phase += self.inc;
        if (self.phase >= 1.0) self.phase -= 1.0;
        return v;
    }

    fn sample(self: *Voice) f32 {
        if (self.stage == .idle) return 0;
        switch (self.stage) {
            .attack => {
                self.env += self.a_rate;
                if (self.env >= 1.0) {
                    self.env = 1.0;
                    self.stage = .decay;
                }
            },
            .decay => {
                self.env -= self.d_rate;
                if (self.env <= self.sustain) {
                    self.env = self.sustain;
                    self.stage = .sustain;
                }
            },
            .sustain => {},
            .release => {
                self.env -= self.r_rate;
                if (self.env <= 0) {
                    self.env = 0;
                    self.stage = .idle;
                    return 0;
                }
            },
            .idle => return 0,
        }
        return self.osc() * self.env * self.gain;
    }
};

// Channels: lead (melody), bass, arpeggio, and kick/snare/hat drums.
const CH_LEAD = 0;
const CH_BASS = 1;
const CH_ARP = 2;
const CH_KICK = 3;
const CH_SNARE = 4;
const CH_HAT = 5;
const N_VOICES = 6;
var voices: [N_VOICES]Voice = [_]Voice{.{}} ** N_VOICES;

fn midiFreq(note: i32) f32 {
    // A4 (MIDI 69) = 440 Hz, equal temperament.
    return 440.0 * std.math.pow(f32, 2.0, @as(f32, @floatFromInt(note - 69)) / 12.0);
}

// ----- Score (our own format) -----
//
// Multi-track score transcribed offline from a real Bad Apple!! MIDI (the
// Handhule90 138 BPM arrangement): melody (vocals), bass, arp, and a
// kick/snare/hat drum bitmask, quantized to a 16th-note grid. Embedded as
// score.bin (see /tmp/transcribe.py); rendered here by our own oscillators.
// No MIDI is touched at runtime -- this is our score data, our synthesis.
//
// score.bin: "FSC1", u32 n_rows, u32 rows_per_beat, u32 bpm, then the melody,
// bass and arp grids (n_rows x i16 MIDI note, 0 = hold/rest) and a drum grid
// (n_rows x u8 bitmask: 1=kick 2=snare 4=hat).
pub const score = @embedFile("score.bin");

fn rdU32(o: usize) u32 {
    return @as(u32, score[o]) | (@as(u32, score[o + 1]) << 8) | (@as(u32, score[o + 2]) << 16) | (@as(u32, score[o + 3]) << 24);
}
fn rdI16(o: usize) i16 {
    return @bitCast(@as(u16, score[o]) | (@as(u16, score[o + 1]) << 8));
}

const N_ROWS: u32 = rdU32(4);
const ROWS_PER_BEAT: u32 = rdU32(8);
const BPM: u32 = rdU32(12);
const SAMPLES_PER_ROW: u32 = RATE * 60 / (BPM * ROWS_PER_BEAT);
const MEL_OFF: usize = 16;
const BASS_OFF: usize = MEL_OFF + @as(usize, N_ROWS) * 2;
const ARP_OFF: usize = BASS_OFF + @as(usize, N_ROWS) * 2;
const DRUM_OFF: usize = ARP_OFF + @as(usize, N_ROWS) * 2;

comptime {
    if (!std.mem.eql(u8, score[0..4], "FSC1")) @compileError("score.bin: bad magic");
}

var row: u32 = 0;
var samples_into_row: u32 = 0;
var started = false;

// (Re)trigger the voices for whatever notes begin on global row `r`. A held
// note rings until its track's next note retriggers the voice (legato).
fn triggerRow(r: u32) void {
    const ro: usize = r;
    const mel = rdI16(MEL_OFF + ro * 2);
    if (mel > 0) voices[CH_LEAD].on(midiFreq(mel), .saw, 0.30, 4, 90, 0.65, 180);
    const bs = rdI16(BASS_OFF + ro * 2);
    if (bs > 0) voices[CH_BASS].on(midiFreq(bs), .triangle, 0.42, 2, 80, 0.5, 120);
    const ar = rdI16(ARP_OFF + ro * 2);
    if (ar > 0) voices[CH_ARP].on(midiFreq(ar), .square, 0.10, 1, 40, 0.0, 35);
    const dr = score[DRUM_OFF + ro];
    if (dr & 1 != 0) voices[CH_KICK].on(70.0, .noise, 0.5, 1, 110, 0.0, 40);
    if (dr & 2 != 0) voices[CH_SNARE].on(300.0, .noise, 0.30, 1, 130, 0.0, 60);
    if (dr & 4 != 0) voices[CH_HAT].on(9000.0, .noise, 0.11, 1, 22, 0.0, 14);
}

// Wall-clock loop length in samples. 0 = use the score's natural length
// (N_ROWS * SAMPLES_PER_ROW). The host sets this to its OWN loop length (e.g.
// badapple sets it to the video duration) so audio and video reset together,
// and the synth zero-pads with silence past the score's last row.
pub var loop_samples: u64 = 0;
var total_samples: u64 = 0;

inline fn effLoopSamples() u64 {
    return if (loop_samples != 0) loop_samples else @as(u64, N_ROWS) * @as(u64, SAMPLES_PER_ROW);
}

fn resetVoices() void {
    for (&voices) |*v| v.* = .{};
}

// Jump the sequencer to absolute sample `sample` (wrapped into the loop) and
// (re)trigger that row, so a late-starting audio thread can line up with the
// video's wall clock instead of beginning at row 0. Voices are reset so no
// stale note rings across the jump.
pub fn seekTo(sample: u64) void {
    const loop_n = effLoopSamples();
    const pos = sample % loop_n;
    total_samples = pos;
    row = @intCast(pos / SAMPLES_PER_ROW);
    samples_into_row = @intCast(pos % SAMPLES_PER_ROW);
    resetVoices();
    if (row < N_ROWS) triggerRow(row);
    started = true;
}

// Render one period of interleaved S16 stereo into `out` (PERIOD_FRAMES*2 i16s).
pub fn render(out: [*]i16, frames: u32) void {
    if (!started) {
        triggerRow(0);
        started = true;
    }
    const loop_n = effLoopSamples();
    var f: u32 = 0;
    while (f < frames) : (f += 1) {
        if (total_samples >= loop_n) {
            // Wall-clock wrap. Silence anything still ringing from the tail
            // of the previous iteration so the next loop starts clean and any
            // mismatch between score length and loop length never leaks a
            // sustained voice across the boundary.
            resetVoices();
            total_samples = 0;
            samples_into_row = 0;
            row = 0;
            triggerRow(0);
        } else if (samples_into_row >= SAMPLES_PER_ROW) {
            samples_into_row = 0;
            row += 1;
            // Past the score's last row but before the wall-clock wrap: render
            // silence (voices keep releasing on their own).
            if (row < N_ROWS) triggerRow(row);
        }
        var acc: f32 = 0;
        for (&voices) |*v| acc += v.sample();
        acc *= 0.7; // headroom so simultaneous voices don't hard-clip harshly
        if (acc > 1.0) acc = 1.0;
        if (acc < -1.0) acc = -1.0;
        const s: i16 = @intFromFloat(acc * 30000.0);
        out[f * 2] = s;
        out[f * 2 + 1] = s;
        samples_into_row += 1;
        total_samples += 1;
    }
}
