// shell.jai: file associations and the single running instance.
//
// Every launch registers Nickel for its audio types under HKEY_CURRENT_USER (no admin rights
// needed): a ProgID, an "Open with" entry per extension, and the Capabilities that make Nickel
// show up in Settings > Default apps. Windows doesn't let programs make themselves the default,
// so the "default player" button opens that settings page. `nickel.exe --unregister` removes it all.
//
// Opening files from Explorer starts a new process per file; those hand their paths to the
// window that is already open (WM_COPYDATA) and exit.

AUDIO_EXTENSIONS :: string.[".mp3", ".flac", ".ogg", ".wav", ".m4a", ".aac", ".wma"];

PROGID           :: "Nickel.AudioFile";
CAPABILITIES_KEY :: "Software\\Nickel\\Capabilities";
WINDOW_CLASS     :: "NickelWindow";

lib_advapi32 :: #library,system "advapi32";

HKEY_CURRENT_USER_ :: cast(HKEY) 0x80000001;
RRF_RT_REG_SZ_ :: 0x2;

w_RegCreateKeyExW    :: (key: HKEY, sub: *u16, reserved: u32, class: *u16, options: u32, sam: u32, security: *void, result: *HKEY, disposition: *u32) -> s32 #foreign lib_advapi32 "RegCreateKeyExW";
w_RegSetValueExW     :: (key: HKEY, name: *u16, reserved: u32, type: u32, data: *u8, size: u32) -> s32 #foreign lib_advapi32 "RegSetValueExW";
w_RegGetValueW       :: (key: HKEY, sub: *u16, name: *u16, flags: u32, type: *u32, data: *void, size: *u32) -> s32 #foreign lib_advapi32 "RegGetValueW";
w_RegDeleteTreeW     :: (key: HKEY, sub: *u16) -> s32 #foreign lib_advapi32 "RegDeleteTreeW";
w_RegDeleteKeyValueW :: (key: HKEY, sub: *u16, name: *u16) -> s32 #foreign lib_advapi32 "RegDeleteKeyValueW";
w_RegCloseKey        :: (key: HKEY) -> s32 #foreign lib_advapi32 "RegCloseKey";
w_SHChangeNotify     :: (event: s32, flags: u32, item1: *void, item2: *void) #foreign lib_shell32 "SHChangeNotify";
w_ShellExecuteW      :: (h: HWND, op: *u16, file: *u16, params: *u16, dir: *u16, show: s32) -> HINSTANCE #foreign lib_shell32 "ShellExecuteW";
w_CreateMutexW       :: (security: *void, initial_owner: s32, name: *u16) -> HANDLE #foreign lib_kernel32 "CreateMutexW";
w_FindWindowExW      :: (parent: HWND, after: HWND, class: *u16, title: *u16) -> HWND #foreign lib_user32 "FindWindowExW";
w_SetForegroundWindow :: (h: HWND) -> s32 #foreign lib_user32 "SetForegroundWindow";

COPYDATASTRUCT_ :: struct { dwData: u64; cbData: u32; lpData: *void; }
COPYDATA_OPEN_PATHS :: 0x4E49434B;   // "NICK": paths separated by "\n", UTF-8

exe_path :: () -> string {
    buf: [1024] u16;
    n := w_GetModuleFileNameW(null, buf.data, buf.count);
    if n == 0 || n >= buf.count return "";
    return wide_to_utf8(buf.data,, temp);
}

// Sets a string value; `name` "" is the key's default value.
reg_set :: (key: string, name: string, value: string, type: u32 = REG_SZ) -> bool {
    h: HKEY;
    if w_RegCreateKeyExW(HKEY_CURRENT_USER_, utf8_to_wide(key,, temp), 0, null, 0, KEY_WRITE_, null, *h, null) != 0 return false;
    defer w_RegCloseKey(h);
    empty: u16;
    data := *empty;
    bytes: u32 = 2;   // just the terminator
    if type == REG_NONE {
        bytes = 0;
    } else if value.count {
        wide, ok, len := utf8_to_wide(value,, temp);
        data = wide;
        bytes = cast(u32) len + 2;
    }
    return w_RegSetValueExW(h, ifx name.count then utf8_to_wide(name,, temp) else null, 0, type, cast(*u8) data, bytes) == 0;
}

reg_get :: (key: string, name: string) -> string {
    buf: [1024] u16;
    size: u32 = size_of(type_of(buf));
    if w_RegGetValueW(HKEY_CURRENT_USER_, utf8_to_wide(key,, temp), ifx name.count then utf8_to_wide(name,, temp) else null, RRF_RT_REG_SZ_, null, buf.data, *size) != 0 return "";
    return wide_to_utf8(buf.data,, temp);
}

KEY_WRITE_ :: 0x20006;

// "C:\...\nickel.exe" "%1" (built with join, since print would read %1 as an argument index).
open_command :: (exe: string) -> string { return join("\"", exe, "\" \"%1\"",, temp); }

register_file_types :: () {
    exe := exe_path();
    if !exe.count return;
    exe = replace(exe, "/", "\\",, temp);
    command := open_command(exe);

    // Nothing to do if this exe is already the one registered.
    if reg_get(tprint("Software\\Classes\\%\\shell\\open\\command", PROGID), "") == command return;

    classes :: "Software\\Classes";
    reg_set(tprint("%\\%", classes, PROGID), "", "Audio file");
    reg_set(tprint("%\\%\\DefaultIcon", classes, PROGID), "", tprint("\"%\",0", exe));
    reg_set(tprint("%\\%\\shell\\open\\command", classes, PROGID), "", command);

    app_key := tprint("%\\Applications\\%", classes, path_filename(exe));
    reg_set(app_key, "FriendlyAppName", APP_NAME);
    reg_set(tprint("%\\shell\\open\\command", app_key), "", command);

    reg_set(CAPABILITIES_KEY, "ApplicationName", APP_NAME);
    reg_set(CAPABILITIES_KEY, "ApplicationDescription", "A small native music player");
    reg_set("Software\\RegisteredApplications", APP_NAME, CAPABILITIES_KEY);

    for AUDIO_EXTENSIONS {
        reg_set(tprint("%\\%\\OpenWithProgids", classes, it), PROGID, "", REG_NONE);
        reg_set(tprint("%\\SupportedTypes", app_key), it, "");
        reg_set(tprint("%\\FileAssociations", CAPABILITIES_KEY), it, PROGID);
    }

    w_SHChangeNotify(0x08000000, 0, null, null);   // SHCNE_ASSOCCHANGED, SHCNF_IDLIST
}

unregister_file_types :: () {
    exe := exe_path();
    w_RegDeleteTreeW(HKEY_CURRENT_USER_, utf8_to_wide(tprint("Software\\Classes\\%", PROGID),, temp));
    if exe.count w_RegDeleteTreeW(HKEY_CURRENT_USER_, utf8_to_wide(tprint("Software\\Classes\\Applications\\%", path_filename(exe)),, temp));
    w_RegDeleteTreeW(HKEY_CURRENT_USER_, utf8_to_wide("Software\\Nickel",, temp));
    w_RegDeleteKeyValueW(HKEY_CURRENT_USER_, utf8_to_wide("Software\\RegisteredApplications",, temp), utf8_to_wide(APP_NAME,, temp));
    for AUDIO_EXTENSIONS {
        w_RegDeleteKeyValueW(HKEY_CURRENT_USER_, utf8_to_wide(tprint("Software\\Classes\\%\\OpenWithProgids", it),, temp), utf8_to_wide(PROGID,, temp));
    }
    w_SHChangeNotify(0x08000000, 0, null, null);
}

// Settings > Default apps, scrolled to Nickel (Windows 11; Windows 10 shows the general page).
open_default_apps_settings :: () {
    url := tprint("ms-settings:defaultapps?registeredAppUser=%", APP_NAME);
    w_ShellExecuteW(main_hwnd, utf8_to_wide("open",, temp), utf8_to_wide(url,, temp), null, null, 1);
}

//
// Single instance
//
instance_mutex: HANDLE;

// Returns true when another Nickel is running; `paths` (if any) were handed to it and this
// process should exit.
forward_to_running_instance :: (paths: [] string) -> bool {
    instance_mutex = w_CreateMutexW(null, 0, utf8_to_wide("Local\\NickelSingleInstance",, temp));
    if GetLastError() != ERROR_ALREADY_EXISTS return false;

    builder: String_Builder;
    builder.allocator = temp;
    for paths {
        full, ok := get_absolute_path(it);
        append(*builder, ifx ok then full else it);
        append(*builder, "\n");
    }
    payload := builder_to_string(*builder,, temp);
    cds: COPYDATASTRUCT_;
    cds.dwData = COPYDATA_OPEN_PATHS;
    cds.cbData = cast(u32) payload.count;
    cds.lpData = payload.data;

    // The other instance may still be starting up (Explorer launches one process per selected
    // file), so give its window a moment to appear. Every Nickel window is tried, because one from
    // an older build would not answer.
    class := utf8_to_wide(WINDOW_CLASS,, temp);
    for 1..50 {
        hwnd := w_FindWindowExW(null, null, class, null);
        while hwnd {
            if w_SendMessageW(hwnd, K_WM_COPYDATA, 0, cast(s64) *cds) == 1 {
                if w_IsIconic(hwnd) w_ShowWindow(hwnd, 9);   // SW_RESTORE
                w_SetForegroundWindow(hwnd);
                return true;
            }
            hwnd = w_FindWindowExW(null, hwnd, class, null);
        }
        sleep_milliseconds(100);
    }
    return false;
}

// WM_COPYDATA from another instance: queue its paths to be opened and played.
receive_paths :: (lp: LPARAM) -> bool {
    cds := cast(*COPYDATASTRUCT_) lp;
    if cds.dwData != COPYDATA_OPEN_PATHS return false;
    payload := string.{cds.cbData, cast(*u8) cds.lpData};
    for split(payload, "\n",, temp) if it.count array_add(*shell_opened, copy_string(it));
    dirty = true;
    return true;
}
