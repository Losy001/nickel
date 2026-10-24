// Build script:
//     jai build.jai              debug build   -> nickel.exe
//     jai build.jai - release    release build -> release/nickel.exe
//
// The only difference from `jai main.jai` is the link step: the Visual C++ runtime
// (vcruntime140.dll) is linked statically, so the exe does not need the redistributable. Together
// with the statically linked FreeType/stb_vorbis and the precompiled shaders embedded in the
// binary, the result is a single file that only depends on DLLs that ship with Windows itself.

#import "Basic";
#import "String";
#import "Process";
#import "File";
Compiler :: #import "Compiler";
Windows_Resources :: #import "Windows_Resources";

EXE_NAME :: "nickel";

build :: () {
    Compiler.set_build_options_dc(.{do_output = false});   // this script itself produces no executable

    release, ok := parse_args(Compiler.get_build_options().compile_time_command_line);
    if !ok return;

    opts := Compiler.get_build_options();
    opts.output_type            = .EXECUTABLE;
    opts.output_executable_name = EXE_NAME;
    opts.use_custom_link_command = true;

    if release {
        Compiler.set_optimization(*opts, .VERY_OPTIMIZED);   // keeps debug info, so a .pdb is still written
        opts.stack_trace       = false;
        opts.output_path       = "release/";
        opts.intermediate_path = tprint("%/.build/release", #filepath);
        make_directory_if_it_does_not_exist(opts.output_path);
    } else {
        opts.intermediate_path = tprint("%/.build/debug", #filepath);
    }

    w := Compiler.compiler_create_workspace(ifx release then "Nickel (release)" else "Nickel (debug)");
    Compiler.set_build_options(opts, w);
    Compiler.compiler_begin_intercept(w);
    Compiler.add_build_file("main.jai", w);

    link_ok := false;   // stays false if compilation fails before the link step
    while true {
        message := Compiler.compiler_wait_for_message();
        if message.kind == .COMPLETE break;
        if message.kind == .PHASE {
            phase := cast(*Compiler.Message_Phase) message;
            if phase.phase == .READY_FOR_CUSTOM_LINK_COMMAND  link_ok = link_static(w, phase, release);
        }
    }
    Compiler.compiler_end_intercept(w);

    if link_ok embed_icon(exe_path(opts));
}

parse_args :: (args: [] string) -> (release: bool, ok: bool) {
    release := false;
    for args {
        if it == {
            case "release"; release = true;
            case "debug";   release = false;
            case;
                print("Unknown build argument '%'. Usage: jai build.jai [- release|debug]\n", it);
                return false, false;
        }
    }
    return release, true;
}

exe_path :: (opts: Compiler.Build_Options) -> string {
    return tprint("%1%2.exe", opts.output_path, opts.output_executable_name);
}

// The application icon, shown in Explorer, the taskbar and Alt+Tab.
embed_icon :: (exe: string) {
    ico, ok := read_entire_file(tprint("%/nickel.ico", #filepath));
    if !ok {
        print("Warning: nickel.ico not found; the exe will have the default icon.\n");
        return;
    }
    Windows_Resources.set_icon_by_data(exe, ico);
    free(ico.data);
}

// vcruntime140.dll is the only runtime DLL that is not part of Windows 10/11 itself (it comes
// with the Visual C++ redistributable), so that part is linked statically. The Universal CRT
// (api-ms-win-crt-*.dll) ships with Windows; the prebuilt freetype.lib expects its dynamic form.
is_dynamic_vcruntime :: (lib: string) -> bool {
    return to_lower_copy(lib,, temp) == "vcruntime.lib";
}

link_static :: (w: Workspace, m: *Compiler.Message_Phase, release: bool) -> bool {
    defer Compiler.compiler_custom_link_command_is_complete(w);

    options := Compiler.get_build_options(w);

    vc_path, linker_path := Windows_Resources.find_visual_studio_in_a_ridiculous_garbage_way();
    kit_root := Windows_Resources.find_windows_kit_root();
    if !linker_path || !kit_root {
        Compiler.compiler_report("Could not find the Visual Studio linker / Windows SDK.", mode = .ERROR);
        return false;
    }

    arguments: [..] string;
    array_add(*arguments, tprint("%\\link.exe", linker_path), "/nologo");
    for m.compiler_generated_object_files array_add(*arguments, it);
    for m.support_object_files            array_add(*arguments, it);

    array_add(*arguments, tprint("/OUT:%", exe_path(options)), "/MACHINE:AMD64", "/INCREMENTAL:NO", "/DEBUG");
    if release  array_add(*arguments, "/OPT:REF", "/OPT:ICF");   // /DEBUG turns these off by default
    array_add(*arguments, tprint("/IMPLIB:%1/%2.lib", options.intermediate_path, options.output_executable_name));

    array_add(*arguments, tprint("/libpath:%", vc_path));
    array_add(*arguments, tprint("/libpath:%/um/x64", kit_root));
    array_add(*arguments, tprint("/libpath:%/ucrt/x64", kit_root));
    array_add(*arguments, "-nodefaultlib");
    array_add(*arguments, "/SUBSYSTEM:windows", "/ENTRY:mainCRTStartup");   // GUI app: no console window

    for m.system_libraries  if !is_dynamic_vcruntime(it) array_add(*arguments, it);
    for m.user_libraries    if !is_dynamic_vcruntime(it) array_add(*arguments, it);
    array_add(*arguments, "libvcruntime.lib");

    result := run_command(..arguments);
    if result.exit_code != 0 {
        print("Link failed (exit code %).\nLink line: %\n", result.exit_code, get_quoted_command_string(arguments));
        Compiler.compiler_report("Link step failed.", mode = .ERROR);
        return false;
    }
    return true;
}

#run build();
