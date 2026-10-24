// Compiles shader.hlsl into shaders/vs.cso, ps.cso and ps_image.cso:
//     jai tools/compile_shaders.jai
// The outputs are checked in, so a normal build does not need this step or d3dcompiler.

#import "Basic";
#import "File";
#import "Windows";
#import "d3d_compiler";
#import "Compiler";

compile_one :: (source: string, entry: string, target: string, out_path: string) {
    defines: [] string;
    bytecode, errors, hr := D3DCompile(source, "shader.hlsl", defines, null, entry, target, xx D3DCOMPILE.ENABLE_STRICTNESS, 0);
    if FAILED(hr) {
        print("Shader compile error (%): %\n", entry, errors);
        exit(1);
    }
    write_entire_file(out_path, bytecode);
    print("Wrote % (% bytes)\n", out_path, bytecode.count);
}

#run {
    set_build_options_dc(.{do_output = false});
    root := tprint("%/..", #filepath);
    source, ok := read_entire_file(tprint("%/shader.hlsl", root));
    if !ok { print("shader.hlsl not found.\n"); exit(1); }
    make_directory_if_it_does_not_exist(tprint("%/shaders", root));
    compile_one(source, "VS", "vs_4_0", tprint("%/shaders/vs.cso", root));
    compile_one(source, "PS", "ps_4_0", tprint("%/shaders/ps.cso", root));
    compile_one(source, "PS_IMAGE", "ps_4_0", tprint("%/shaders/ps_image.cso", root));
}
