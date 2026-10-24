// art.jai: cover art. Takes the picture embedded in the file's tags (ID3v2 APIC, FLAC PICTURE,
// MP4 covr, Vorbis METADATA_BLOCK_PICTURE) or else a cover.jpg / folder.jpg next to it. Reading
// and decoding happen on a worker thread; the UI thread picks the pixels up with art_poll().

#import "stb_image";
#import "Base64";

MAX_ART_BYTES :: 32 * 1024 * 1024;   // largest tag / picture we are willing to read
MAX_ART_SIDE  :: 1024;               // bigger pictures are halved until they fit

Art :: struct {
    path:   string;   // the track it belongs to
    pixels: *u8;      // RGBA, w * h * 4 bytes; null when the track has no picture
    w, h:   s32;
}

art_free :: (a: *Art) {
    free_str(a.path);
    if a.pixels free(a.pixels);
    a.* = .{};
}

//
// Worker thread
//
art_lock:    Mutex;
art_wake:    Semaphore;
art_thread:  Thread;
art_running := false;
art_quit    := false;
art_wanted:  string;   // next path to load (guarded by art_lock)
art_done:    Art;      // finished result waiting for the UI (guarded by art_lock)
art_done_ready := false;

art_start :: () {
    init(*art_lock);
    init(*art_wake);
    thread_init(*art_thread, art_thread_proc);
    thread_start(*art_thread);
    art_running = true;
}

art_stop :: () {
    if !art_running return;
    art_quit = true;
    signal(*art_wake);
    thread_is_done(*art_thread, 2000);
}

// Asks for the cover of `path`; replaces any request that hasn't started yet.
art_request :: (path: string) {
    if !art_running return;
    lock(*art_lock);
    free_str(art_wanted);
    art_wanted = copy_string(path);
    unlock(*art_lock);
    signal(*art_wake);
}

// A finished load, if there is one. The caller owns it (art_free).
art_poll :: () -> Art, bool {
    if !art_running return .{}, false;
    lock(*art_lock);
    defer unlock(*art_lock);
    if !art_done_ready return .{}, false;
    result := art_done;
    art_done = .{};
    art_done_ready = false;
    return result, true;
}

art_thread_proc :: (thread: *Thread) -> s64 {
    while true {
        wait_for(*art_wake);
        if art_quit break;

        lock(*art_lock);
        path := art_wanted;
        art_wanted = "";
        unlock(*art_lock);
        if !path.count continue;

        result := load_art(path);   // takes ownership of path

        lock(*art_lock);
        art_free(*art_done);        // an older result nobody picked up
        art_done = result;
        art_done_ready = true;
        unlock(*art_lock);
        reset_temporary_storage();
    }
    return 0;
}

load_art :: (path: string) -> Art {
    a: Art;
    a.path = path;

    encoded := find_cover(path);
    if !encoded.count return a;

    w, h, channels: s32;
    decoded := stbi_load_from_memory(encoded.data, cast(s32) encoded.count, *w, *h, *channels, 4);
    if !decoded return a;
    defer stbi_image_free(decoded);
    if w <= 0 || h <= 0 || w > 16384 || h > 16384 return a;

    pixels := cast(*u8) alloc(w * h * 4);
    memcpy(pixels, decoded, w * h * 4);
    while w > MAX_ART_SIDE || h > MAX_ART_SIDE {
        smaller, sw, sh := halve(pixels, w, h);
        free(pixels);
        pixels = smaller;
        w = sw;
        h = sh;
    }
    a.pixels = pixels;
    a.w = w;
    a.h = h;
    return a;
}

// 2x2 box filter.
halve :: (src: *u8, w: s32, h: s32) -> *u8, s32, s32 {
    dw := max(w / 2, 1);
    dh := max(h / 2, 1);
    dst := cast(*u8) alloc(dw * dh * 4);
    for y: 0..dh-1 {
        y0 := min(y * 2, h - 1);
        y1 := min(y * 2 + 1, h - 1);
        for x: 0..dw-1 {
            x0 := min(x * 2, w - 1);
            x1 := min(x * 2 + 1, w - 1);
            for c: 0..3 {
                sum := cast(s32) src[(y0 * w + x0) * 4 + c];
                sum += src[(y0 * w + x1) * 4 + c];
                sum += src[(y1 * w + x0) * 4 + c];
                sum += src[(y1 * w + x1) * 4 + c];
                dst[(y * dw + x) * 4 + c] = cast(u8) ((sum + 2) / 4);
            }
        }
    }
    return dst, dw, dh;
}

//
// Finding the picture. Everything returned is an encoded image (JPEG/PNG) in temporary storage.
//
FRONT_COVER :: 3;   // ID3 / FLAC picture type

find_cover :: (path: string) -> [] u8 {
    ext, found := path_extension(path);
    ext = to_lower_copy(ext,, temp);
    data: [] u8;
    if      ext == "mp3" || ext == "aac" || ext == "wav"  data = id3_cover(path);
    else if ext == "flac"                                 data = flac_cover(path);
    else if ext == "m4a"                                  data = mp4_cover(path);
    else if ext == "ogg"                                  data = ogg_cover(path);
    if !data.count data = folder_cover(path);
    return data;
}

// APIC frames: encoding, MIME type, picture type, description, picture data.
id3_cover :: (path: string) -> [] u8 {
    tag, ver := read_id3_tag(path, MAX_ART_BYTES);
    best: [] u8;
    best_type := -1;
    pos := 0;
    while true {
        id, body, ok := next_id3_frame(tag, ver, *pos);
        if !ok break;
        if id != "APIC" || body.count < 4 continue;

        enc := body[0];
        i := 1;
        while i < body.count && body[i] != 0  i += 1;   // MIME type
        i += 1;
        if i >= body.count continue;
        picture_type := cast(int) body[i];
        i += 1;
        if enc == 1 || enc == 2 {   // UTF-16 description, ends with 00 00
            while i + 1 < body.count && (body[i] != 0 || body[i + 1] != 0)  i += 2;
            i += 2;
        } else {
            while i < body.count && body[i] != 0  i += 1;
            i += 1;
        }
        if i >= body.count continue;

        if !best.count || (picture_type == FRONT_COVER && best_type != FRONT_COVER) {
            best = array_view(body, i);
            best_type = picture_type;
        }
    }
    return best;
}

// A FLAC METADATA_BLOCK_PICTURE (also what Vorbis comments carry, base64 encoded).
parse_flac_picture :: (b: [] u8) -> picture_type: int, data: [] u8 {
    if b.count < 32 return -1, .[];
    picture_type := be32(b, 0);
    p := 8 + be32(b, 4);                      // MIME type
    if p + 4 > b.count return -1, .[];
    p += 4 + be32(b, p);                      // description
    p += 16;                                  // width, height, depth, colors
    if p + 4 > b.count return -1, .[];
    size := be32(b, p);
    p += 4;
    if size <= 0 || p + size > b.count return -1, .[];
    return picture_type, array_view(b, p, size);
}

flac_cover :: (path: string) -> [] u8 {
    f, ok := file_open(path);
    if !ok return .[];
    defer file_close(*f);

    head: [10] u8;
    success, got := file_read(f, head.data, 4);
    if !success || got < 4 return .[];
    pos := 4;
    if head[0] == #char "I" && head[1] == #char "D" && head[2] == #char "3" {   // some taggers put ID3 in front
        success, got = file_read(f, *head[4], 6);
        if !success || got < 6 return .[];
        pos = 10 + syncsafe(head, 6);
        file_set_position(f, pos);
        success, got = file_read(f, head.data, 4);
        if !success || got < 4 return .[];
        pos += 4;
    }
    if head[0] != #char "f" || head[1] != #char "L" || head[2] != #char "a" || head[3] != #char "C" return .[];

    best: [] u8;
    while true {
        success, got = file_read(f, head.data, 4);
        if !success || got < 4 break;
        pos += 4;
        last := (head[0] & 0x80) != 0;
        kind := head[0] & 0x7F;
        size := ((cast(int) head[1]) << 16) | ((cast(int) head[2]) << 8) | (cast(int) head[3]);

        if kind == 6 && size <= MAX_ART_BYTES {   // PICTURE
            block := NewArray(size, u8,, temp);
            success, got = file_read(f, block.data, size);
            if !success || got < size break;
            picture_type, data := parse_flac_picture(block);
            if data.count && (!best.count || picture_type == FRONT_COVER) best = data;
            if picture_type == FRONT_COVER break;
        } else {
            file_set_position(f, pos + size);
        }
        pos += size;
        if last break;
    }
    return best;
}

// MP4 boxes: moov > udta > meta > ilst > covr > data.
mp4_child :: (b: [] u8, kind: string) -> [] u8 {
    p := 0;
    while p + 8 <= b.count {
        size := be32(b, p);
        if size < 8 || p + size > b.count break;
        if string.{4, *b[p + 4]} == kind return array_view(b, p + 8, size - 8);
        p += size;
    }
    return .[];
}

mp4_cover :: (path: string) -> [] u8 {
    f, ok := file_open(path);
    if !ok return .[];
    defer file_close(*f);
    length := file_length(f);

    // Walk the top-level boxes to moov, which may sit at the end of the file.
    pos := 0;
    moov: [] u8;
    while pos + 8 <= length {
        file_set_position(f, pos);
        head: [16] u8;
        success, got := file_read(f, head.data, 8);
        if !success || got < 8 break;
        size := be32(head, 0);
        header := 8;
        if size == 1 {   // 64-bit size
            success, got = file_read(f, *head[8], 8);
            if !success || got < 8 break;
            size = (be32(head, 8) << 32) | be32(head, 12);
            header = 16;
        } else if size == 0 {
            size = length - pos;
        }
        if size < header break;
        if string.{4, *head[4]} == "moov" {
            if size - header > MAX_ART_BYTES break;
            moov = NewArray(size - header, u8,, temp);
            success, got = file_read(f, moov.data, moov.count);
            if !success || got < moov.count return .[];
            break;
        }
        pos += size;
    }
    if !moov.count return .[];

    meta := mp4_child(mp4_child(moov, "udta"), "meta");
    if !meta.count meta = mp4_child(moov, "meta");
    if meta.count < 4 return .[];
    covr := mp4_child(mp4_child(array_view(meta, 4), "ilst"), "covr");   // meta has 4 bytes of version/flags
    data := mp4_child(covr, "data");
    if data.count <= 8 return .[];
    return array_view(data, 8);   // type indicator, locale
}

// The Vorbis comment header is the second Ogg packet; it may span many pages when a picture is in it.
ogg_cover :: (path: string) -> [] u8 {
    f, ok := file_open(path);
    if !ok return .[];
    defer file_close(*f);

    packet: [..] u8;
    packet.allocator = temp;
    packet_index := 0;
    total := 0;
    while total < MAX_ART_BYTES {
        head: [27] u8;
        success, got := file_read(f, head.data, 27);
        if !success || got < 27 return .[];
        if head[0] != #char "O" || head[1] != #char "g" || head[2] != #char "g" || head[3] != #char "S" return .[];
        segments: [255] u8;
        count := cast(int) head[26];
        success, got = file_read(f, segments.data, count);
        if !success || got < count return .[];
        body_size := 0;
        for 0..count-1 body_size += segments[it];
        body := NewArray(body_size, u8,, temp);
        success, got = file_read(f, body.data, body_size);
        if !success || got < body_size return .[];
        total += 27 + count + body_size;

        offset := 0;
        for 0..count-1 {
            len := cast(int) segments[it];
            if packet_index == 1 array_add_view(*packet, array_view(body, offset, len));
            offset += len;
            if len < 255 {   // end of a packet
                if packet_index == 1 return vorbis_comment_cover(packet);
                packet_index += 1;
            }
        }
    }
    return .[];
}

array_add_view :: (dst: *[..] u8, src: [] u8) {
    old := dst.count;
    array_resize(dst, old + src.count, initialize = false);
    memcpy(dst.data + old, src.data, src.count);
}

vorbis_comment_cover :: (b: [] u8) -> [] u8 {
    if b.count < 15 || b[0] != 3 return .[];   // 0x03 "vorbis"
    p := 7;
    p += 4 + le32(b, p);                       // vendor string
    if p + 4 > b.count return .[];
    count := le32(b, p);
    p += 4;
    for 1..count {
        if p + 4 > b.count break;
        len := le32(b, p);
        p += 4;
        if len < 0 || p + len > b.count break;
        comment := string.{len, *b[p]};
        p += len;

        eq := find_index_from_left(comment, #char "=");
        if eq < 0 continue;
        key := slice(comment, 0, eq);
        value := slice(comment, eq + 1, comment.count - eq - 1);
        if compare_nocase(key, "METADATA_BLOCK_PICTURE") == 0 {
            decoded, ok := base64_decode(value,, temp);
            if !ok continue;
            picture_type, data := parse_flac_picture(cast([] u8) decoded);
            if data.count return data;
        } else if compare_nocase(key, "COVERART") == 0 {   // older, just the base64 image
            decoded, ok := base64_decode(value,, temp);
            if ok && decoded.count return cast([] u8) decoded;
        }
    }
    return .[];
}

// cover.jpg, folder.png, ... next to the track.
folder_cover :: (path: string) -> [] u8 {
    dir := path_strip_filename(path);
    for name: string.["cover", "folder", "front", "album", "albumart"] {
        for ext: string.["jpg", "jpeg", "png"] {
            data, ok := read_entire_file(tprint("%1%2.%3", dir, name, ext), log_errors = false,, temp);
            if ok && data.count return cast([] u8) data;
        }
    }
    return .[];
}
