// library.jai: finds the user's Music folder, scans it in the background and reads
// ID3 tags. Every sub-folder of Music becomes an entry in the sidebar.

Track :: struct {
    path:   string;
    title:  string;
    artist: string;
    album:  string;
    ext:    string;
}

Source_Kind :: enum { ALL; FOLDER; CUSTOM; OPENED; }   // CUSTOM = a folder the user added

Source :: struct {
    name: string;
    path: string;
    kind: Source_Kind;
    tracks: [..] Track;
}

// Strings inside Track/Source are always heap copies, so they can all be freed uniformly.
free_str :: (s: string) { if s.count > 0 free(s.data); }

free_track :: (t: *Track) {
    free_str(t.path); free_str(t.title); free_str(t.artist); free_str(t.album); free_str(t.ext);
    t.* = .{};
}

copy_track :: (t: Track) -> Track {
    r: Track;
    r.path = copy_string(t.path); r.title = copy_string(t.title); r.artist = copy_string(t.artist);
    r.album = copy_string(t.album); r.ext = copy_string(t.ext);
    return r;
}

free_source :: (s: *Source) {
    for *s.tracks free_track(it);
    array_reset(*s.tracks);
    free_str(s.name);
    free_str(s.path);
    s.* = .{};
}

// lib_shell32 is declared in main.jai, lib_ole32 in audio.jai.
w_SHGetKnownFolderPath :: (id: *GUID, flags: u32, token: *void, out: **u16) -> s32 #foreign lib_shell32 "SHGetKnownFolderPath";
w_CoTaskMemFree :: (p: *void) #foreign lib_ole32 "CoTaskMemFree";

FOLDERID_MUSIC :: GUID.{0x4BD8D571, 0x6D19, 0x48D3, .[0xBE, 0x97, 0x42, 0x22, 0x20, 0x08, 0x0E, 0x43]};

is_audio_ext :: (ext: string) -> bool {
    e := to_lower_copy(ext,, temp);
    return e == "mp3" || e == "ogg" || e == "wav" || e == "flac" || e == "m4a" || e == "aac" || e == "wma";
}

is_audio_path :: (path: string) -> bool {
    ext, found := path_extension(path);
    return found && is_audio_ext(ext);
}

music_folder :: () -> string {
    id := FOLDERID_MUSIC;
    out: *u16;
    if w_SHGetKnownFolderPath(*id, 0, null, *out) >= 0 && out {
        s := wide_to_utf8(out,, temp);
        result := copy_string(s);
        w_CoTaskMemFree(out);
        return result;
    }
    return "";
}

//
// ID3v2 (title / artist / album). Anything unreadable just falls back to the file name.
//
syncsafe :: (b: [] u8, o: int) -> int {
    return ((cast(int) b[o]) << 21) | ((cast(int) b[o+1]) << 14) | ((cast(int) b[o+2]) << 7) | (cast(int) b[o+3]);
}

append_utf8 :: (sb: *[..] u8, cp: u32) {
    if cp < 0x80 { array_add(sb, cast(u8) cp); }
    else if cp < 0x800 { array_add(sb, cast(u8) (0xC0 | (cp >> 6))); array_add(sb, cast(u8) (0x80 | (cp & 0x3F))); }
    else if cp < 0x10000 { array_add(sb, cast(u8) (0xE0 | (cp >> 12))); array_add(sb, cast(u8) (0x80 | ((cp >> 6) & 0x3F))); array_add(sb, cast(u8) (0x80 | (cp & 0x3F))); }
    else { array_add(sb, cast(u8) (0xF0 | (cp >> 18))); array_add(sb, cast(u8) (0x80 | ((cp >> 12) & 0x3F))); array_add(sb, cast(u8) (0x80 | ((cp >> 6) & 0x3F))); array_add(sb, cast(u8) (0x80 | (cp & 0x3F))); }
}

// Returns a string in temporary storage.
decode_id3_text :: (data: [] u8) -> string {
    if data.count < 2 return "";
    enc := data[0];
    out: [..] u8;
    out.allocator = temp;
    i := 1;
    if enc == 0 {
        while i < data.count { if data[i] == 0 break; append_utf8(*out, data[i]); i += 1; }
    } else if enc == 1 || enc == 2 {
        big := enc == 2;
        if enc == 1 && data.count >= 3 {
            if data[1] == 0xFE && data[2] == 0xFF { big = true; i = 3; }
            else if data[1] == 0xFF && data[2] == 0xFE { big = false; i = 3; }
        }
        while i + 1 < data.count {
            u := ifx big then ((cast(u32) data[i]) << 8) | data[i+1] else ((cast(u32) data[i+1]) << 8) | data[i];
            i += 2;
            if u == 0 break;
            if u >= 0xD800 && u < 0xDC00 && i + 1 < data.count {
                lo := ifx big then ((cast(u32) data[i]) << 8) | data[i+1] else ((cast(u32) data[i+1]) << 8) | data[i];
                i += 2;
                u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
            }
            append_utf8(*out, u);
        }
    } else {
        while i < data.count { if data[i] == 0 break; array_add(*out, data[i]); i += 1; }
    }
    return trim(string.{out.count, out.data});
}

be32 :: (b: [] u8, o: int) -> int {
    return ((cast(int) b[o]) << 24) | ((cast(int) b[o+1]) << 16) | ((cast(int) b[o+2]) << 8) | (cast(int) b[o+3]);
}

le32 :: (b: [] u8, o: int) -> int {
    return ((cast(int) b[o+3]) << 24) | ((cast(int) b[o+2]) << 16) | ((cast(int) b[o+1]) << 8) | (cast(int) b[o]);
}

// Reads the ID3v2.3/2.4 tag at the start of a file, at most `max_size` bytes of it, into temporary
// storage. Returns the frames area (after the extended header) and the major version.
read_id3_tag :: (path: string, max_size: int) -> frames: [] u8, version: u8 {
    f, ok := file_open(path);
    if !ok return .[], 0;
    defer file_close(*f);

    head: [10] u8;
    success, got := file_read(f, head.data, 10);
    if !success || got < 10 return .[], 0;
    if head[0] != #char "I" || head[1] != #char "D" || head[2] != #char "3" return .[], 0;
    ver := head[3];
    if ver < 3 return .[], 0;

    size := min(syncsafe(head, 6), max_size);
    tag := NewArray(size, u8,, temp);
    success, got = file_read(f, tag.data, size);
    if !success return .[], 0;
    tag.count = got;

    pos := 0;
    if head[5] & 0x40 {   // extended header
        if got < 4 return .[], 0;
        pos = ifx ver == 4 then syncsafe(tag, 0) else be32(tag, 0) + 4;
        if pos > got return .[], 0;
    }
    return array_view(tag, pos), ver;
}

// Steps through the frames of a tag from read_id3_tag; `pos` starts at 0.
next_id3_frame :: (tag: [] u8, ver: u8, pos: *int) -> id: string, body: [] u8, ok: bool {
    p := pos.*;
    if p + 10 > tag.count || tag[p] == 0 return "", .[], false;
    id := string.{4, *tag[p]};
    size := ifx ver == 4 then syncsafe(tag, p + 4) else be32(tag, p + 4);
    start := p + 10;
    if size <= 0 || start + size > tag.count return "", .[], false;
    pos.* = start + size;

    body := array_view(tag, start, size);
    if ver == 4 && (tag[p + 9] & 0x01) && body.count >= 4  body = array_view(body, 4);   // data length indicator
    return id, body, true;
}

read_id3 :: (path: string, t: *Track) {
    tag, ver := read_id3_tag(path, 4 * 1024 * 1024);
    pos := 0;
    while true {
        id, body, ok := next_id3_frame(tag, ver, *pos);
        if !ok break;
        if id != "TIT2" && id != "TPE1" && id != "TALB" continue;
        text := decode_id3_text(body);
        if !text.count continue;
        if id == "TIT2" { free_str(t.title);  t.title  = copy_string(text); }
        if id == "TPE1" { free_str(t.artist); t.artist = copy_string(text); }
        if id == "TALB" { free_str(t.album);  t.album  = copy_string(text); }
    }
}

make_track :: (path: string) -> Track {
    auto_release_temp();   // the ID3 tag buffer can be megabytes (cover art); don't let a scan pile them up
    t: Track;
    t.path = copy_string(path);
    ext, found := path_extension(path);
    if found t.ext = to_upper_copy(ext);
    base := path_strip_extension(path_filename(path));
    t.title = copy_string(base);
    for 0..t.title.count-1  if t.title[it] == #char "_" then t.title[it] = #char " ";

    if t.ext == "MP3" {
        tags: Track;
        read_id3(path, *tags);
        if tags.title.count { free_str(t.title); t.title = tags.title; }
        t.artist = tags.artist;
        t.album  = tags.album;
    }
    return t;
}

//
// Scanning
//
Scan_Collect :: struct { paths: [..] string; }

collect_visit :: (info: *File_Visit_Info, c: *Scan_Collect) {
    if is_audio_path(info.full_name) array_add(*c.paths, copy_string(info.full_name));
}

path_less :: (a: string, b: string) -> s64 { return compare_nocase(a, b); }

scan_folder_tracks :: (dir: string, recursive := true) -> [..] Track {
    c: Scan_Collect;
    visit_files(dir, recursive, *c, collect_visit);
    quick_sort(c.paths, path_less);
    result: [..] Track;
    for c.paths {
        array_add(*result, make_track(it));
        free(it.data);
    }
    array_reset(*c.paths);
    return result;
}

// Builds the library: "All music", one source per sub-folder of the Music folder, and one per
// folder the user added.
scan_library :: (extra: [] string) -> [..] Source {
    sources: [..] Source;
    root := music_folder();

    all: Source;
    all.name = copy_string("All music");
    all.path = copy_string(root);
    all.kind = .ALL;

    if root.count {
        folders: [..] string;
        defer { for folders free_str(it); array_reset(*folders); }
        folder_visit :: (info: *File_Visit_Info, list: *[..] string) {
            if info.is_directory {
                array_add(list, copy_string(info.full_name));
                info.descend_into_directory = false;
            }
        }
        visit_files(root, false, *folders, folder_visit, visit_files = false, visit_directories = true);
        quick_sort(folders, path_less);

        // Files sitting directly in the Music folder.
        loose: Source;
        loose.name = copy_string("Music");
        loose.path = copy_string(root);
        loose.kind = .FOLDER;
        loose.tracks = scan_folder_tracks(root, recursive = false);

        for folders {
            s: Source;
            s.name = copy_string(path_filename(it));
            s.path = copy_string(it);
            s.kind = .FOLDER;
            s.tracks = scan_folder_tracks(it);
            if s.tracks.count == 0 { free_source(*s); continue; }
            array_add(*sources, s);
        }
        if loose.tracks.count array_insert_at(*sources, loose, 0);
        else free_source(*loose);
    }

    // Folders added by the user (kept in settings.txt).
    for ex: extra {
        if root.count && compare_nocase(ex, root) == 0 continue;
        duplicate := false;
        for sources if compare_nocase(it.path, ex) == 0 duplicate = true;
        if duplicate continue;
        s: Source;
        s.name = copy_string(path_filename(ex));
        if !s.name.count s.name = copy_string(ex);
        s.path = copy_string(ex);
        s.kind = .CUSTOM;
        s.tracks = scan_folder_tracks(ex);
        array_add(*sources, s);   // kept even when empty so the user can see and remove it
    }

    for sources for t: it.tracks array_add(*all.tracks, copy_track(t));
    if all.tracks.count array_insert_at(*sources, all, 0);
    return sources;
}

// Background scan job.
Scan_Job :: struct {
    thread: Thread;
    sources: [..] Source;
    extra: [..] string;      // folders to scan besides the Music folder (copied when the scan starts)
    done: bool;
    running: bool;
}

scan_job: Scan_Job;

scan_thread_proc :: (thread: *Thread) -> s64 {
    scan_job.sources = scan_library(scan_job.extra);
    for scan_job.extra free_str(it);
    array_reset(*scan_job.extra);
    scan_job.done = true;
    return 0;
}

start_scan :: (extra: [] string) {
    if scan_job.running return;
    for extra array_add(*scan_job.extra, copy_string(it));
    scan_job.done = false;
    scan_job.running = true;
    thread_init(*scan_job.thread, scan_thread_proc);
    thread_start(*scan_job.thread);
}
