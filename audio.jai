// audio.jai: streaming audio engine.
//
// Decoding: Windows Media Foundation (mp3, flac, m4a/aac, wma, wav, ...) loaded
// dynamically from system DLLs, plus stb_vorbis (statically linked) for .ogg.
// Output: waveOut with small buffers, driven by a dedicated audio thread, so a
// 3-hour mp3 starts instantly and never has to be decoded into memory.
// Volume is applied while mixing, and the exact samples being played are kept in
// a ring buffer so the UI can draw a real spectrum.

#import "Thread";
#import "stb_vorbis";

//
// Public state (written by the audio thread, read by the UI thread).
//
Audio_State :: enum s32 { IDLE; LOADING; PLAYING; PAUSED; ENDED; ERROR; }

audio_state: Audio_State;
audio_duration: float64;
audio_rate: s32 = 44100;
audio_pos_frames: s64;
audio_pos_stamp: float64;
audio_serial: s64;            // identifies which audio_play() the state belongs to
audio_error: string;
audio_gain: float = 1.0;      // linear gain applied while mixing

VIZ_N :: 1 << 17;
viz_ring: [VIZ_N] s16;        // mono mix of everything submitted, indexed by track frame

//
// Commands (UI thread -> audio thread).
//
Audio_Cmd :: struct {
    kind: enum { PLAY; PAUSE; RESUME; SEEK; STOP; QUIT; };
    path: string;
    t: float64;
    serial: s64;
}

cmd_mutex: Mutex;
cmd_queue: [..] Audio_Cmd;
audio_thread: Thread;
audio_started := false;
audio_serial_counter: s64;

audio_start :: () {
    init(*cmd_mutex);
    thread_init(*audio_thread, audio_thread_proc);
    thread_start(*audio_thread);
    audio_started = true;
}

audio_stop_thread :: () {
    if !audio_started return;
    push_cmd(.{kind = .QUIT});
    thread_is_done(*audio_thread, 3000);
}

push_cmd :: (c: Audio_Cmd) {
    lock(*cmd_mutex);
    defer unlock(*cmd_mutex);
    array_add(*cmd_queue, c);
}

audio_play :: (path: string, start_seconds: float64 = 0) -> s64 {
    audio_serial_counter += 1;
    audio_state = .LOADING;
    audio_serial = audio_serial_counter;
    audio_pos_frames = cast(s64) (start_seconds * audio_rate);
    audio_pos_stamp = seconds_since_init();
    push_cmd(.{kind = .PLAY, path = copy_string(path), t = start_seconds, serial = audio_serial_counter});
    return audio_serial_counter;
}

audio_pause  :: () { push_cmd(.{kind = .PAUSE}); if audio_state == .PLAYING { audio_pos_frames = audio_position_frames(); audio_state = .PAUSED; } }
audio_resume :: () { push_cmd(.{kind = .RESUME}); if audio_state == .PAUSED { audio_pos_stamp = seconds_since_init(); audio_state = .PLAYING; } }
audio_stop   :: () { push_cmd(.{kind = .STOP}); audio_state = .IDLE; audio_pos_frames = 0; }

audio_seek :: (seconds: float64) {
    seconds = clamp(seconds, 0, max(audio_duration, 0));
    push_cmd(.{kind = .SEEK, t = seconds});
    audio_pos_frames = cast(s64) (seconds * audio_rate);
    audio_pos_stamp = seconds_since_init();
}

// Current position in frames, extrapolated between audio-thread updates.
audio_position_frames :: () -> s64 {
    p := audio_pos_frames;
    if audio_state == .PLAYING {
        p += cast(s64) ((seconds_since_init() - audio_pos_stamp) * audio_rate);
    }
    return p;
}

audio_position :: () -> float64 {
    return clamp(cast(float64) audio_position_frames() / audio_rate, 0, max(audio_duration, 0));
}

//
// Media Foundation plumbing (hand-written COM; no SDK bindings needed).
//
Propvariant_ :: struct { vt: u16; r1: u16; r2: u16; r3: u16; value: s64; extra: s64; }

G_MT_MAJOR_TYPE  :: GUID.{0x48eba18e, 0xf8c9, 0x4687, .[0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f]};
G_MT_SUBTYPE     :: GUID.{0xf7e34c9a, 0x42e8, 0x4714, .[0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5]};
G_MEDIATYPE_AUDIO :: GUID.{0x73647561, 0x0000, 0x0010, .[0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]};
G_AUDIOFORMAT_PCM :: GUID.{0x00000001, 0x0000, 0x0010, .[0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]};
G_MT_CHANNELS    :: GUID.{0x37e48bf5, 0x645e, 0x4c5b, .[0x89, 0xde, 0xad, 0xa9, 0xe2, 0x9b, 0x69, 0x6a]};
G_MT_RATE        :: GUID.{0x5faeeae7, 0x0290, 0x4c31, .[0x9e, 0x8a, 0xc5, 0x34, 0xf6, 0x8d, 0x9d, 0xba]};
G_MT_BITS        :: GUID.{0xf2deb57f, 0x40fa, 0x4764, .[0xaa, 0x33, 0xed, 0x4f, 0x2d, 0x1f, 0xf6, 0x69]};
G_PD_DURATION    :: GUID.{0x6c990d33, 0xbb8e, 0x477a, .[0x85, 0x98, 0x0d, 0x5d, 0x96, 0xfc, 0xd8, 0x8a]};
G_NULL           :: GUID.{};

MF_VERSION      :: 0x00020070;
MF_FIRST_AUDIO  :: 0xFFFFFFFD;
MF_ALL_STREAMS  :: 0xFFFFFFFE;
MF_MEDIASOURCE  :: 0xFFFFFFFF;
MF_SOURCE_READERF_ENDOFSTREAM :: 2;

VT_I8  :: 20;
VT_UI8 :: 21;

// Vtable slots of the COM methods we call.
SLOT_RELEASE :: 2;
// IMFAttributes (and IMFMediaType, which derives from it)
SLOT_ATTR_GET_UINT32 :: 7;
SLOT_ATTR_SET_UINT32 :: 21;
SLOT_ATTR_SET_GUID   :: 24;
// IMFSourceReader
SLOT_READER_SET_STREAM_SELECTION     :: 4;
SLOT_READER_GET_CURRENT_MEDIA_TYPE   :: 6;
SLOT_READER_SET_CURRENT_MEDIA_TYPE   :: 7;
SLOT_READER_SET_CURRENT_POSITION     :: 8;
SLOT_READER_READ_SAMPLE              :: 9;
SLOT_READER_GET_PRESENTATION_ATTRIBUTE :: 12;
// IMFSample, IMFMediaBuffer
SLOT_SAMPLE_CONVERT_TO_CONTIGUOUS :: 41;
SLOT_BUFFER_LOCK   :: 3;
SLOT_BUFFER_UNLOCK :: 4;

Fn_MFStartup      :: #type (version: u32, flags: u32) -> s32 #c_call;
Fn_MFCreateReader :: #type (url: *u16, attrs: *void, reader: **void) -> s32 #c_call;
Fn_MFCreateType   :: #type (mt: **void) -> s32 #c_call;

Fn_Release     :: #type (this: *void) -> u32 #c_call;
Fn_SetGUID     :: #type (this: *void, key: *GUID, value: *GUID) -> s32 #c_call;
Fn_SetUINT32   :: #type (this: *void, key: *GUID, value: u32) -> s32 #c_call;
Fn_GetUINT32   :: #type (this: *void, key: *GUID, value: *u32) -> s32 #c_call;
Fn_SetStreamSel :: #type (this: *void, index: u32, selected: s32) -> s32 #c_call;
Fn_SetCurType  :: #type (this: *void, index: u32, reserved: *u32, mt: *void) -> s32 #c_call;
Fn_GetCurType  :: #type (this: *void, index: u32, mt: **void) -> s32 #c_call;
Fn_SetPosition :: #type (this: *void, format: *GUID, pos: *Propvariant_) -> s32 #c_call;
Fn_ReadSample  :: #type (this: *void, index: u32, flags: u32, actual: *u32, sflags: *u32, ts: *s64, sample: **void) -> s32 #c_call;
Fn_GetPresAttr :: #type (this: *void, index: u32, key: *GUID, value: *Propvariant_) -> s32 #c_call;
Fn_Contiguous  :: #type (this: *void, buffer: **void) -> s32 #c_call;
Fn_BufLock     :: #type (this: *void, data: **u8, max: *u32, cur: *u32) -> s32 #c_call;
Fn_BufUnlock   :: #type (this: *void) -> s32 #c_call;

mf_startup: Fn_MFStartup;
mf_create_reader: Fn_MFCreateReader;
mf_create_type: Fn_MFCreateType;
mf_ready := false;
mf_failed := false;

com_slot :: (obj: *void, slot: int) -> *void {
    vtable := (cast(**void) obj).*;
    fns := cast(**void) vtable;
    return fns[slot];
}

com_release :: (obj: *void) {
    if obj {
        release := cast(Fn_Release) com_slot(obj, SLOT_RELEASE);
        release(obj);
    }
}

mf_load :: () -> bool {
    if mf_ready return true;
    if mf_failed return false;
    plat  := LoadLibraryW(utf8_to_wide("mfplat.dll",, temp));
    rw    := LoadLibraryW(utf8_to_wide("mfreadwrite.dll",, temp));
    if !plat || !rw { mf_failed = true; return false; }
    mf_startup       = cast(Fn_MFStartup)      GetProcAddress(plat, "MFStartup");
    mf_create_type   = cast(Fn_MFCreateType)   GetProcAddress(plat, "MFCreateMediaType");
    mf_create_reader = cast(Fn_MFCreateReader) GetProcAddress(rw,   "MFCreateSourceReaderFromURL");
    if !mf_startup || !mf_create_type || !mf_create_reader { mf_failed = true; return false; }
    if mf_startup(MF_VERSION, 0) < 0 { mf_failed = true; return false; }
    mf_ready = true;
    return true;
}

//
// Decoder
//
Decoder :: struct {
    kind: enum { NONE; MF; VORBIS; };
    src_channels: s32;
    channels: s32;                 // channels we output (1 or 2)
    rate: s32;
    duration: float64;
    cursor_frame: s64;             // frame index of the next frame dec_read returns

    // Media Foundation
    reader: *void;
    pending: [..] s16;
    pending_off: s64;
    resync: bool;
    eof: bool;

    // Vorbis
    vorbis: *stb_vorbis;
    vorbis_data: string;
}

dec_close :: (d: *Decoder) {
    if d.kind == .MF {
        com_release(d.reader);
    } else if d.kind == .VORBIS {
        stb_vorbis_close(d.vorbis);
        free(d.vorbis_data.data);
    }
    array_reset(*d.pending);
    d.* = .{};
}

dec_open :: (d: *Decoder, path: string) -> bool, string {
    d.* = .{};
    ext, found := path_extension(path);
    if found && to_lower_copy(ext,, temp) == "ogg" {
        ok, err := dec_open_vorbis(d, path);
        return ok, err;
    }
    ok, err := dec_open_mf(d, path);
    return ok, err;
}

dec_open_vorbis :: (d: *Decoder, path: string) -> bool, string {
    data, ok := read_entire_file(path);
    if !ok return false, "Could not read file";
    err: s32;
    v := stb_vorbis_open_memory(data.data, cast(s32) data.count, *err, null);
    if !v { free(data.data); return false, "Not a valid Ogg Vorbis file"; }
    info := stb_vorbis_get_info(v);
    d.kind = .VORBIS;
    d.vorbis = v;
    d.vorbis_data = data;
    d.src_channels = info.channels;
    d.channels = ifx info.channels >= 2 then cast(s32) 2 else cast(s32) 1;
    d.rate = cast(s32) info.sample_rate;
    d.duration = cast(float64) stb_vorbis_stream_length_in_samples(v) / cast(float64) info.sample_rate;
    return true, "";
}

dec_open_mf :: (d: *Decoder, path: string) -> bool, string {
    if !mf_load() return false, "Media Foundation is not available";

    reader: *void;
    hr := mf_create_reader(utf8_to_wide(path,, temp), null, *reader);
    if hr < 0 return false, "Could not open file (unsupported format?)";

    set_stream_sel := cast(Fn_SetStreamSel) com_slot(reader, SLOT_READER_SET_STREAM_SELECTION);
    set_stream_sel(reader, MF_ALL_STREAMS, 0);
    set_stream_sel(reader, MF_FIRST_AUDIO, 1);

    mt: *void;
    if mf_create_type(*mt) < 0 { com_release(reader); return false, "MF error"; }
    major := G_MT_MAJOR_TYPE; sub := G_MT_SUBTYPE;
    media_audio := G_MEDIATYPE_AUDIO; pcm := G_AUDIOFORMAT_PCM;
    bits := G_MT_BITS;
    set_guid := cast(Fn_SetGUID) com_slot(mt, SLOT_ATTR_SET_GUID);
    set_guid(mt, *major, *media_audio);
    set_guid(mt, *sub, *pcm);
    (cast(Fn_SetUINT32) com_slot(mt, SLOT_ATTR_SET_UINT32))(mt, *bits, 16);
    hr = (cast(Fn_SetCurType) com_slot(reader, SLOT_READER_SET_CURRENT_MEDIA_TYPE))(reader, MF_FIRST_AUDIO, null, mt);
    com_release(mt);
    if hr < 0 { com_release(reader); return false, "No audio stream could be decoded"; }

    cur: *void;
    hr = (cast(Fn_GetCurType) com_slot(reader, SLOT_READER_GET_CURRENT_MEDIA_TYPE))(reader, MF_FIRST_AUDIO, *cur);
    if hr < 0 { com_release(reader); return false, "MF error"; }
    ch, rate, bps: u32;
    key_ch := G_MT_CHANNELS; key_rate := G_MT_RATE; key_bits := G_MT_BITS;
    getu := cast(Fn_GetUINT32) com_slot(cur, SLOT_ATTR_GET_UINT32);
    getu(cur, *key_ch, *ch);
    getu(cur, *key_rate, *rate);
    getu(cur, *key_bits, *bps);
    com_release(cur);
    if bps != 16 || ch == 0 || rate == 0 { com_release(reader); return false, "Unsupported sample format"; }

    pv: Propvariant_;
    key_dur := G_PD_DURATION;
    (cast(Fn_GetPresAttr) com_slot(reader, SLOT_READER_GET_PRESENTATION_ATTRIBUTE))(reader, MF_MEDIASOURCE, *key_dur, *pv);

    d.kind = .MF;
    d.reader = reader;
    d.src_channels = cast(s32) ch;
    d.channels = ifx ch >= 2 then cast(s32) 2 else cast(s32) 1;
    d.rate = cast(s32) rate;
    d.duration = ifx pv.vt == VT_UI8 then cast(float64) pv.value / 10000000.0 else 0.0;   // 100 ns units
    d.resync = true;
    return true, "";
}

// Reads up to `frames` frames of 16-bit interleaved audio (d.channels per frame).
dec_read :: (d: *Decoder, dst: *s16, frames: s64) -> s64 {
    if d.kind == .VORBIS {
        tmp_count := frames * d.src_channels;
        if d.src_channels == d.channels {
            n := stb_vorbis_get_samples_short_interleaved(d.vorbis, d.src_channels, dst, cast(s32) tmp_count);
            d.cursor_frame += n;
            return n;
        }
        // More than two channels: decode all, keep the first two.
        tmp := NewArray(tmp_count, s16,, temp);
        n := stb_vorbis_get_samples_short_interleaved(d.vorbis, d.src_channels, tmp.data, cast(s32) tmp_count);
        for f: 0..n-1 { dst[f * 2] = tmp[f * d.src_channels]; dst[f * 2 + 1] = tmp[f * d.src_channels + 1]; }
        d.cursor_frame += n;
        return n;
    }
    if d.kind != .MF return 0;

    got: s64 = 0;
    while got < frames {
        if d.pending_off >= d.pending.count {
            if d.eof break;
            d.pending.count = 0;
            d.pending_off = 0;

            flags: u32; ts: s64; sample: *void; actual: u32;
            hr := (cast(Fn_ReadSample) com_slot(d.reader, SLOT_READER_READ_SAMPLE))(d.reader, MF_FIRST_AUDIO, 0, *actual, *flags, *ts, *sample);
            if hr < 0 || (flags & MF_SOURCE_READERF_ENDOFSTREAM) { d.eof = true; com_release(sample); break; }
            if !sample continue;

            if d.resync {
                d.cursor_frame = cast(s64) (cast(float64) ts * d.rate / 10000000.0 + 0.5);
                d.resync = false;
            }

            buffer: *void;
            if (cast(Fn_Contiguous) com_slot(sample, SLOT_SAMPLE_CONVERT_TO_CONTIGUOUS))(sample, *buffer) >= 0 {
                data: *u8; max_len, cur_len: u32;
                if (cast(Fn_BufLock) com_slot(buffer, SLOT_BUFFER_LOCK))(buffer, *data, *max_len, *cur_len) >= 0 {
                    n := cur_len / 2;
                    old := d.pending.count;
                    array_resize(*d.pending, old + n, initialize = false);
                    memcpy(d.pending.data + old, data, cur_len);
                    (cast(Fn_BufUnlock) com_slot(buffer, SLOT_BUFFER_UNLOCK))(buffer);
                }
                com_release(buffer);
            }
            com_release(sample);
            continue;
        }

        avail := (d.pending.count - d.pending_off) / d.src_channels;
        take := min(avail, frames - got);
        if take <= 0 { d.pending_off = d.pending.count; continue; }
        if d.src_channels == d.channels {
            memcpy(dst + got * d.channels, d.pending.data + d.pending_off, take * d.channels * 2);
            d.pending_off += take * d.channels;
        } else {
            for f: 0..take-1 {
                base := d.pending_off + f * d.src_channels;
                dst[(got + f) * 2]     = d.pending[base];
                dst[(got + f) * 2 + 1] = d.pending[base + 1];
            }
            d.pending_off += take * d.src_channels;
        }
        got += take;
    }
    d.cursor_frame += got;
    return got;
}

dec_seek :: (d: *Decoder, seconds: float64) {
    seconds = clamp(seconds, 0, max(d.duration, 0));
    d.cursor_frame = cast(s64) (seconds * d.rate);
    if d.kind == .VORBIS {
        stb_vorbis_seek(d.vorbis, cast(u32) d.cursor_frame);
    } else if d.kind == .MF {
        pv: Propvariant_;
        pv.vt = VT_I8;
        pv.value = cast(s64) (seconds * 10000000.0);
        none := G_NULL;
        (cast(Fn_SetPosition) com_slot(d.reader, SLOT_READER_SET_CURRENT_POSITION))(d.reader, *none, *pv);
        d.pending.count = 0;
        d.pending_off = 0;
        d.eof = false;
        d.resync = true;
    }
}

//
// waveOut
//
WAVEFORMATEX_ :: struct {
    wFormatTag: u16; nChannels: u16; nSamplesPerSec: u32; nAvgBytesPerSec: u32;
    nBlockAlign: u16; wBitsPerSample: u16; cbSize: u16;
}

WAVEHDR_ :: struct {
    lpData: *u8; dwBufferLength: u32; dwBytesRecorded: u32; dwUser: u64;
    dwFlags: u32; dwLoops: u32; lpNext: *void; reserved: u64;
}

MMTIME_ :: struct { wType: u32; value: u32; extra: [2] u32; }

lib_winmm :: #library,system "winmm";
wo_Open     :: (h: **void, device: u32, fmt: *WAVEFORMATEX_, cb: u64, inst: u64, flags: u32) -> u32 #foreign lib_winmm "waveOutOpen";
wo_Close    :: (h: *void) -> u32 #foreign lib_winmm "waveOutClose";
wo_Prepare  :: (h: *void, hdr: *WAVEHDR_, size: u32) -> u32 #foreign lib_winmm "waveOutPrepareHeader";
wo_Unprepare :: (h: *void, hdr: *WAVEHDR_, size: u32) -> u32 #foreign lib_winmm "waveOutUnprepareHeader";
wo_Write    :: (h: *void, hdr: *WAVEHDR_, size: u32) -> u32 #foreign lib_winmm "waveOutWrite";
wo_Reset    :: (h: *void) -> u32 #foreign lib_winmm "waveOutReset";
wo_Pause    :: (h: *void) -> u32 #foreign lib_winmm "waveOutPause";
wo_Restart  :: (h: *void) -> u32 #foreign lib_winmm "waveOutRestart";
wo_GetPos   :: (h: *void, t: *MMTIME_, size: u32) -> u32 #foreign lib_winmm "waveOutGetPosition";
lib_ole32 :: #library,system "ole32";
w_CoInitializeEx :: (reserved: *void, flags: u32) -> s32 #foreign lib_ole32 "CoInitializeEx";

WHDR_DONE     :: 1;
WHDR_PREPARED :: 2;

NBUF       :: 6;
BUF_FRAMES :: 1024;

close_device :: (hwo: *void, hdrs: *[NBUF] WAVEHDR_) {
    if hwo {
        wo_Reset(hwo);
        for 0..NBUF-1  if hdrs.*[it].dwFlags & WHDR_PREPARED  wo_Unprepare(hwo, *hdrs.*[it], size_of(WAVEHDR_));
        wo_Close(hwo);
    }
}

audio_thread_proc :: (thread: *Thread) -> s64 {
    w_CoInitializeEx(null, 0);
    SetThreadPriority(GetCurrentThread(), 1);   // ABOVE_NORMAL

    dec: Decoder;
    hwo: *void;
    hdrs: [NBUF] WAVEHDR_;
    queued: [NBUF] bool;
    storage: [NBUF] [] s16;
    for 0..NBUF-1  storage[it] = NewArray(BUF_FRAMES * 2, s16);

    open := false;          // decoder + device open
    paused := false;
    eof := false;
    ended_reported := false;
    have_base := false;
    base_frame: s64;
    serial: s64;
    quit := false;

    while !quit {
        // Take pending commands.
        cmds: [..] Audio_Cmd;
        cmds.allocator = temp;
        lock(*cmd_mutex);
        for cmd_queue array_add(*cmds, it);
        cmd_queue.count = 0;
        unlock(*cmd_mutex);

        for c: cmds {
            if c.kind == {
            case .QUIT;
                quit = true;

            case .PLAY;
                close_device(hwo, *hdrs); hwo = null;
                dec_close(*dec);
                open = false; paused = false; eof = false; have_base = false; ended_reported = false;
                for 0..NBUF-1 queued[it] = false;
                serial = c.serial;

                ok, err := dec_open(*dec, c.path);
                free(c.path.data);
                if !ok {
                    free(audio_error.data);
                    audio_error = copy_string(err);
                    audio_state = .ERROR;
                    continue;
                }

                fmt: WAVEFORMATEX_;
                fmt.wFormatTag = 1;
                fmt.nChannels = cast(u16) dec.channels;
                fmt.nSamplesPerSec = cast(u32) dec.rate;
                fmt.wBitsPerSample = 16;
                fmt.nBlockAlign = cast(u16) (dec.channels * 2);
                fmt.nAvgBytesPerSec = fmt.nSamplesPerSec * fmt.nBlockAlign;
                if wo_Open(*hwo, 0xFFFFFFFF, *fmt, 0, 0, 0) != 0 {
                    free(audio_error.data);
                    audio_error = copy_string("Could not open the audio device");
                    audio_state = .ERROR;
                    dec_close(*dec);
                    continue;
                }
                for 0..NBUF-1 {
                    hdrs[it] = .{};
                    hdrs[it].lpData = cast(*u8) storage[it].data;
                    hdrs[it].dwBufferLength = cast(u32) (BUF_FRAMES * dec.channels * 2);
                    wo_Prepare(hwo, *hdrs[it], size_of(WAVEHDR_));
                }

                audio_rate = dec.rate;
                audio_duration = dec.duration;
                if c.t > 0 dec_seek(*dec, c.t);
                audio_pos_frames = cast(s64) (c.t * dec.rate);
                audio_pos_stamp = seconds_since_init();
                audio_serial = serial;
                open = true;
                audio_state = .PLAYING;

            case .PAUSE;
                if open && !paused { wo_Pause(hwo); paused = true; }
            case .RESUME;
                if open && paused { wo_Restart(hwo); paused = false; }

            case .SEEK;
                if open {
                    wo_Reset(hwo);
                    for 0..NBUF-1 queued[it] = false;
                    dec_seek(*dec, c.t);
                    eof = false; ended_reported = false; have_base = false;
                    if audio_state == .ENDED audio_state = .PLAYING;
                    if paused { wo_Pause(hwo); }
                }

            case .STOP;
                close_device(hwo, *hdrs); hwo = null;
                dec_close(*dec);
                open = false; paused = false;
            }
        }
        if quit break;

        if open {
            // Refill any free buffers.
            if !paused {
                for i: 0..NBUF-1 {
                    if queued[i] && !(hdrs[i].dwFlags & WHDR_DONE) continue;   // still playing
                    queued[i] = false;
                    if eof continue;

                    n := dec_read(*dec, storage[i].data, BUF_FRAMES);
                    if n <= 0 { eof = true; continue; }
                    start_frame := dec.cursor_frame - n;
                    if !have_base { base_frame = start_frame; have_base = true; }

                    gain := audio_gain;
                    ch := dec.channels;
                    count := n * ch;
                    buf := storage[i].data;
                    if gain < 0.999 || gain > 1.001 {
                        for k: 0..count-1 {
                            v := cast(float) buf[k] * gain;
                            buf[k] = cast(s16) clamp(v, -32768, 32767);
                        }
                    }
                    for f: 0..n-1 {
                        m := cast(s32) buf[f * ch];
                        if ch == 2  m = (m + cast(s32) buf[f * 2 + 1]) / 2;
                        viz_ring[(start_frame + f) & (VIZ_N - 1)] = cast(s16) m;
                    }

                    hdrs[i].dwBufferLength = cast(u32) (n * ch * 2);
                    if wo_Write(hwo, *hdrs[i], size_of(WAVEHDR_)) == 0 queued[i] = true;
                }
            }

            // Position.
            if have_base {
                mt: MMTIME_;
                mt.wType = 2;   // TIME_SAMPLES
                if wo_GetPos(hwo, *mt, size_of(MMTIME_)) == 0 && mt.wType == 2 {
                    audio_pos_frames = base_frame + mt.value;
                    audio_pos_stamp = seconds_since_init();
                }
            }

            // End of track: decoder drained and every buffer finished playing.
            if eof && !ended_reported {
                all_done := true;
                for 0..NBUF-1  if queued[it] && !(hdrs[it].dwFlags & WHDR_DONE) all_done = false;
                if all_done {
                    ended_reported = true;
                    audio_state = .ENDED;
                }
            }
        }

        reset_temporary_storage();
        sleep_milliseconds(4);
    }

    close_device(hwo, *hdrs); hwo = null;
    dec_close(*dec);
    return 0;
}

//
// Spectrum for the visualizer: FFT of the samples around the playback position.
//
FFT_N    :: 1024;
VIZ_BARS :: 48;

fft_re: [FFT_N] float;
fft_im: [FFT_N] float;
fft_window: [FFT_N] float;
fft_window_ready := false;

fft_in_place :: () {
    // Bit reversal.
    j := 0;
    for i: 1..FFT_N-1 {
        bit := FFT_N >> 1;
        while j & bit { j ^= bit; bit >>= 1; }
        j ^= bit;
        if i < j {
            t := fft_re[i]; fft_re[i] = fft_re[j]; fft_re[j] = t;
            t = fft_im[i];  fft_im[i] = fft_im[j];  fft_im[j] = t;
        }
    }
    len := 2;
    while len <= FFT_N {
        ang := -TAU / cast(float) len;
        wr := cos(ang); wi := sin(ang);
        i := 0;
        while i < FFT_N {
            cr: float = 1; ci: float = 0;
            for k: 0..len/2-1 {
                a := i + k;
                b := i + k + len / 2;
                tr := fft_re[b] * cr - fft_im[b] * ci;
                ti := fft_re[b] * ci + fft_im[b] * cr;
                fft_re[b] = fft_re[a] - tr; fft_im[b] = fft_im[a] - ti;
                fft_re[a] += tr;            fft_im[a] += ti;
                ncr := cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = ncr;
            }
            i += len;
        }
        len <<= 1;
    }
}

// Fills `bars` (0..1) with the spectrum at the current playback position.
compute_spectrum :: (bars: *[VIZ_BARS] float) {
    if !fft_window_ready {
        for 0..FFT_N-1  fft_window[it] = 0.5 - 0.5 * cos(TAU * cast(float) it / (FFT_N - 1));
        fft_window_ready = true;
    }
    pos := audio_position_frames();
    for i: 0..FFT_N-1 {
        idx := pos - FFT_N + i;
        fft_re[i] = ifx idx >= 0 then cast(float) viz_ring[idx & (VIZ_N - 1)] / 32768.0 * fft_window[i] else 0.0;
        fft_im[i] = 0;
    }
    fft_in_place();

    rate := cast(float) audio_rate;
    lo_hz: float = 50;
    hi_hz: float = min(16000.0, rate * 0.45);
    for b: 0..VIZ_BARS-1 {
        f0 := lo_hz * pow(hi_hz / lo_hz, cast(float) b / VIZ_BARS);
        f1 := lo_hz * pow(hi_hz / lo_hz, cast(float) (b + 1) / VIZ_BARS);
        k0 := max(1, cast(int) (f0 * FFT_N / rate));
        k1 := max(k0 + 1, cast(int) (f1 * FFT_N / rate));
        peak: float = 0;
        for k: k0..min(k1, FFT_N / 2 - 1) {
            m := sqrt(fft_re[k] * fft_re[k] + fft_im[k] * fft_im[k]) / (FFT_N * 0.25);
            if m > peak peak = m;
        }
        db := 8.685889 * log(peak + 0.000001);   // 20*log10(x) = 8.6859*ln(x)
        bars.*[b] = clamp((db + 62.0) / 56.0, 0, 1);
    }
}
