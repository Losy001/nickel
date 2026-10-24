// gfx.jai: a small D3D11 renderer for Nickel.
//
// Flip-model swap chain with DXGI_SCALING_NONE, and the buffers are resized
// synchronously from WM_SIZE (gfx_resize), so the window never shows a stretched
// or stale frame while it is being dragged. Shapes are drawn with 4x MSAA into an
// offscreen target that is resolved into the back buffer. Text comes from a
// FreeType glyph atlas; images (cover art) are RGBA textures drawn with their own pixel shader.

#import "d3d11"()(INCLUDE_DEBUG_BINDINGS = false);
#import "dxgi";
#import "freetype";
#import "Unicode";
#import "Hash_Table";

Gfx_Vertex :: struct {
    x, y, u, v: float;
    r, g, b, a: float;
}

Gfx_Glyph :: struct {
    x0, y0, w, h: s32;      // atlas pixels
    left, top: s32;         // bearing
    advance: s32;
}

GFX_MSAA    :: 4;
ATLAS_SIZE  :: 1024;
VBUF_VERTS  :: 65536;

gfx_device: *ID3D11Device;
gfx_ctx:    *ID3D11DeviceContext;
gfx_swap:   *IDXGISwapChain;
gfx_back_buffer: *ID3D11Texture2D;
gfx_msaa_tex:    *ID3D11Texture2D;
gfx_msaa_rtv:    *ID3D11RenderTargetView;
gfx_vs:      *ID3D11VertexShader;
gfx_ps:      *ID3D11PixelShader;
gfx_ps_image: *ID3D11PixelShader;
gfx_layout:  *ID3D11InputLayout;
gfx_vbuf:    *ID3D11Buffer;
gfx_cbuf:    *ID3D11Buffer;
gfx_blend:   *ID3D11BlendState;
gfx_raster:  *ID3D11RasterizerState;
gfx_sampler: *ID3D11SamplerState;
gfx_sampler_linear: *ID3D11SamplerState;
gfx_atlas:     *ID3D11Texture2D;
gfx_atlas_srv: *ID3D11ShaderResourceView;

gfx_w: s32;
gfx_h: s32;
gfx_resized_this_frame := false;
gfx_verts: [..] Gfx_Vertex;

// Atlas packing (simple shelves) and glyph cache.
atlas_x: s32;
atlas_y: s32;
atlas_row_h: s32;
glyph_cache: Table(u64, Gfx_Glyph);

ft_library: FT_Library;
ft_face: FT_Face;
ft_font_data: string;
ft_face_px: s32;

// The shaders (shader.hlsl) are compiled ahead of time by tools/compile_shaders.jai into
// shaders/*.cso and embedded here, so the exe never loads d3dcompiler at run time.
load_cso :: (name: string) -> string {
    data, ok := read_entire_file(tprint("%/shaders/%", #filepath, name));
    assert(ok, "Missing precompiled shader % (run: jai tools/compile_shaders.jai)", name);
    return data;
}

VS_BYTECODE       :: #run load_cso("vs.cso");
PS_BYTECODE       :: #run load_cso("ps.cso");
PS_IMAGE_BYTECODE :: #run load_cso("ps_image.cso");

gfx_init :: (hwnd: HWND, width: s32, height: s32) -> bool {
    flags := D3D11_CREATE_DEVICE_FLAG.BGRA_SUPPORT;
    levels := D3D_FEATURE_LEVEL.[._11_0, ._10_1, ._10_0];
    fl: D3D_FEATURE_LEVEL;
    hr := D3D11CreateDevice(null, .HARDWARE, null, flags, levels.data, xx levels.count, D3D11_SDK_VERSION, *gfx_device, *fl, *gfx_ctx);
    if FAILED(hr) {
        hr = D3D11CreateDevice(null, .WARP, null, flags, levels.data, xx levels.count, D3D11_SDK_VERSION, *gfx_device, *fl, *gfx_ctx);
    }
    if FAILED(hr) { log_error("D3D11CreateDevice failed.\n"); return false; }

    // Factory from the device's adapter.
    factory: *IDXGIFactory2;
    {
        dxgi_device: *IDXGIDevice;
        hr = IUnknown_QueryInterface(gfx_device, *uid(IDXGIDevice_UUID), xx *dxgi_device);
        if FAILED(hr) return false;
        adapter: *IDXGIAdapter;
        hr = IDXGIDevice_GetAdapter(dxgi_device, *adapter);
        if SUCCEEDED(hr) {
            hr = IDXGIObject_GetParent(adapter, *uid(IDXGIFactory2_UUID), xx *factory);
            IUnknown_Release(adapter);
        }
        IUnknown_Release(dxgi_device);
        if FAILED(hr) return false;
    }

    gfx_w = max(width, 1);
    gfx_h = max(height, 1);

    sd: DXGI_SWAP_CHAIN_DESC1;
    sd.Width  = xx gfx_w;
    sd.Height = xx gfx_h;
    sd.Format = .B8G8R8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = .RENDER_TARGET_OUTPUT;
    sd.BufferCount = 2;
    sd.Scaling    = .NONE;          // never stretch the old frame while resizing
    sd.SwapEffect = .FLIP_DISCARD;  // flip model: DWM composes our buffers directly
    sd.AlphaMode  = .IGNORE;

    sc1: *IDXGISwapChain1;
    hr = IDXGIFactory2_CreateSwapChainForHwnd(factory, xx gfx_device, hwnd, *sd, null, null, *sc1);
    if SUCCEEDED(hr) {
        gfx_swap = cast(*IDXGISwapChain) sc1;
        IDXGIFactory_MakeWindowAssociation(xx factory, hwnd, cast(u32) DXGI_MWA.NO_ALT_ENTER);
    }
    IUnknown_Release(factory);
    if FAILED(hr) { log_error("CreateSwapChainForHwnd failed.\n"); return false; }

    if !gfx_create_targets() return false;

    // Shaders and input layout.
    vs_code := VS_BYTECODE;
    ps_code := PS_BYTECODE;

    hr = ID3D11Device_CreateVertexShader(gfx_device, vs_code.data, cast(u64) vs_code.count, null, *gfx_vs);
    if FAILED(hr) return false;
    hr = ID3D11Device_CreatePixelShader(gfx_device, ps_code.data, cast(u64) ps_code.count, null, *gfx_ps);
    if FAILED(hr) return false;
    ps_image_code := PS_IMAGE_BYTECODE;
    hr = ID3D11Device_CreatePixelShader(gfx_device, ps_image_code.data, cast(u64) ps_image_code.count, null, *gfx_ps_image);
    if FAILED(hr) return false;

    layout: [3] D3D11_INPUT_ELEMENT_DESC;
    layout[0].SemanticName = "POSITION"; layout[0].Format = .R32G32_FLOAT;       layout[0].AlignedByteOffset = 0;  layout[0].InputSlotClass = .VERTEX_DATA;
    layout[1].SemanticName = "TEXCOORD"; layout[1].Format = .R32G32_FLOAT;       layout[1].AlignedByteOffset = 8;  layout[1].InputSlotClass = .VERTEX_DATA;
    layout[2].SemanticName = "COLOR";    layout[2].Format = .R32G32B32A32_FLOAT; layout[2].AlignedByteOffset = 16; layout[2].InputSlotClass = .VERTEX_DATA;
    hr = ID3D11Device_CreateInputLayout(gfx_device, layout.data, 3, vs_code.data, cast(u64) vs_code.count, *gfx_layout);
    if FAILED(hr) return false;

    // Dynamic vertex buffer and constant buffer.
    bd: D3D11_BUFFER_DESC;
    bd.ByteWidth = VBUF_VERTS * size_of(Gfx_Vertex);
    bd.Usage = .DYNAMIC;
    bd.BindFlags = .VERTEX_BUFFER;
    bd.CPUAccessFlags = .WRITE;
    hr = ID3D11Device_CreateBuffer(gfx_device, *bd, null, *gfx_vbuf);
    if FAILED(hr) return false;

    cb: D3D11_BUFFER_DESC;
    cb.ByteWidth = 16;
    cb.Usage = .DEFAULT;
    cb.BindFlags = .CONSTANT_BUFFER;
    hr = ID3D11Device_CreateBuffer(gfx_device, *cb, null, *gfx_cbuf);
    if FAILED(hr) return false;

    // Fixed-function state.
    blend: D3D11_BLEND_DESC;
    blend.RenderTarget[0].BlendEnable = .TRUE;
    blend.RenderTarget[0].SrcBlend  = .SRC_ALPHA;
    blend.RenderTarget[0].DestBlend = .INV_SRC_ALPHA;
    blend.RenderTarget[0].BlendOp   = .ADD;
    blend.RenderTarget[0].SrcBlendAlpha  = .ONE;
    blend.RenderTarget[0].DestBlendAlpha = .INV_SRC_ALPHA;
    blend.RenderTarget[0].BlendOpAlpha   = .ADD;
    blend.RenderTarget[0].RenderTargetWriteMask = 15;
    hr = ID3D11Device_CreateBlendState(gfx_device, *blend, *gfx_blend);
    if FAILED(hr) return false;

    rs: D3D11_RASTERIZER_DESC;
    rs.FillMode = .SOLID;
    rs.CullMode = .NONE;
    rs.DepthClipEnable = .TRUE;
    rs.ScissorEnable = .TRUE;
    rs.MultisampleEnable = .TRUE;
    hr = ID3D11Device_CreateRasterizerState(gfx_device, *rs, *gfx_raster);
    if FAILED(hr) return false;

    ss: D3D11_SAMPLER_DESC;
    ss.Filter = .MIN_MAG_MIP_POINT;
    ss.AddressU = .CLAMP; ss.AddressV = .CLAMP; ss.AddressW = .CLAMP;
    ss.ComparisonFunc = .NEVER;
    ss.MaxLOD = 3.4e38;
    hr = ID3D11Device_CreateSamplerState(gfx_device, *ss, *gfx_sampler);
    if FAILED(hr) return false;
    ss.Filter = .MIN_MAG_MIP_LINEAR;   // for images, which have mipmaps
    hr = ID3D11Device_CreateSamplerState(gfx_device, *ss, *gfx_sampler_linear);
    if FAILED(hr) return false;

    // Glyph atlas (R8). The top-left 2x2 block is solid white, used for shapes.
    td: D3D11_TEXTURE2D_DESC;
    td.Width = ATLAS_SIZE; td.Height = ATLAS_SIZE;
    td.MipLevels = 1; td.ArraySize = 1;
    td.Format = .R8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = .DEFAULT;
    td.BindFlags = .SHADER_RESOURCE;
    hr = ID3D11Device_CreateTexture2D(gfx_device, *td, null, *gfx_atlas);
    if FAILED(hr) return false;
    hr = ID3D11Device_CreateShaderResourceView(gfx_device, xx gfx_atlas, null, *gfx_atlas_srv);
    if FAILED(hr) return false;
    gfx_reset_atlas();

    error := FT_Init_FreeType(*ft_library);
    if error return false;
    return true;
}

gfx_reset_atlas :: () {
    table_reset(*glyph_cache);
    atlas_x = 4; atlas_y = 0; atlas_row_h = 0;
    white: [4] u8 = .[255, 255, 255, 255];
    box: D3D11_BOX;
    box.left = 0; box.top = 0; box.front = 0; box.right = 2; box.bottom = 2; box.back = 1;
    ID3D11DeviceContext_UpdateSubresource(gfx_ctx, xx gfx_atlas, 0, *box, white.data, 2, 0);
}

gfx_create_targets :: () -> bool {
    hr := IDXGISwapChain_GetBuffer(gfx_swap, 0, *uid(ID3D11Texture2D_UUID), xx *gfx_back_buffer);
    if FAILED(hr) return false;

    td: D3D11_TEXTURE2D_DESC;
    td.Width = xx gfx_w; td.Height = xx gfx_h;
    td.MipLevels = 1; td.ArraySize = 1;
    td.Format = .B8G8R8A8_UNORM;
    td.SampleDesc.Count = GFX_MSAA;
    td.Usage = .DEFAULT;
    td.BindFlags = .RENDER_TARGET;
    hr = ID3D11Device_CreateTexture2D(gfx_device, *td, null, *gfx_msaa_tex);
    if FAILED(hr) return false;
    hr = ID3D11Device_CreateRenderTargetView(gfx_device, xx gfx_msaa_tex, null, *gfx_msaa_rtv);
    return SUCCEEDED(hr);
}

gfx_release :: (p: **$T) {
    if p.* { IUnknown_Release(p.*); p.* = null; }
}

// Call this straight from WM_SIZE, then render and present before returning.
gfx_resize :: (w: s32, h: s32) {
    if !gfx_swap return;
    w = max(w, 1); h = max(h, 1);
    if w == gfx_w && h == gfx_h return;
    gfx_w = w; gfx_h = h;
    gfx_resized_this_frame = true;

    ID3D11DeviceContext_OMSetRenderTargets(gfx_ctx, 0, null, null);
    gfx_release(*gfx_msaa_rtv);
    gfx_release(*gfx_msaa_tex);
    gfx_release(*gfx_back_buffer);
    ID3D11DeviceContext_Flush(gfx_ctx);

    hr := IDXGISwapChain_ResizeBuffers(gfx_swap, 0, xx w, xx h, .UNKNOWN, 0);
    if FAILED(hr) log_error("ResizeBuffers failed: %\n", hr);
    gfx_create_targets();
}

gfx_begin :: (r: float, g: float, b: float) {
    vp: D3D11_VIEWPORT;
    vp.Width = xx gfx_w; vp.Height = xx gfx_h; vp.MaxDepth = 1;
    ID3D11DeviceContext_RSSetViewports(gfx_ctx, 1, *vp);
    gfx_clear_scissor();

    consts: [4] float = .[1.0 / cast(float) gfx_w, 1.0 / cast(float) gfx_h, 0, 0];
    ID3D11DeviceContext_UpdateSubresource(gfx_ctx, xx gfx_cbuf, 0, null, consts.data, 0, 0);

    ID3D11DeviceContext_OMSetRenderTargets(gfx_ctx, 1, *gfx_msaa_rtv, null);
    blend_factor: [4] float;
    ID3D11DeviceContext_OMSetBlendState(gfx_ctx, gfx_blend, *blend_factor, 0xFFFFFFFF);
    ID3D11DeviceContext_RSSetState(gfx_ctx, gfx_raster);

    ID3D11DeviceContext_IASetInputLayout(gfx_ctx, gfx_layout);
    ID3D11DeviceContext_IASetPrimitiveTopology(gfx_ctx, .TRIANGLELIST);
    stride: u32 = size_of(Gfx_Vertex);
    offset: u32 = 0;
    ID3D11DeviceContext_IASetVertexBuffers(gfx_ctx, 0, 1, *gfx_vbuf, *stride, *offset);

    ID3D11DeviceContext_VSSetShader(gfx_ctx, gfx_vs, null, 0);
    ID3D11DeviceContext_VSSetConstantBuffers(gfx_ctx, 0, 1, *gfx_cbuf);
    ID3D11DeviceContext_PSSetShader(gfx_ctx, gfx_ps, null, 0);
    ID3D11DeviceContext_PSSetShaderResources(gfx_ctx, 0, 1, *gfx_atlas_srv);
    ID3D11DeviceContext_PSSetSamplers(gfx_ctx, 0, 1, *gfx_sampler);

    color: [4] float = .[r, g, b, 1];
    ID3D11DeviceContext_ClearRenderTargetView(gfx_ctx, gfx_msaa_rtv, *color);
}

gfx_end :: () {
    gfx_flush();
    ID3D11DeviceContext_ResolveSubresource(gfx_ctx, xx gfx_back_buffer, 0, xx gfx_msaa_tex, 0, .B8G8R8A8_UNORM);
    // While the window is being resized, present without waiting for vblank so the
    // frame for the new size reaches DWM immediately; otherwise stay vsynced.
    interval: u32 = 1;
    if gfx_resized_this_frame interval = 0;
    gfx_resized_this_frame = false;
    hr := IDXGISwapChain_Present(gfx_swap, interval, 0);
    if hr == xx DXGI_ERROR_DEVICE_REMOVED || hr == xx DXGI_ERROR_DEVICE_RESET {
        log_error("D3D11 device lost.\n");
    }
}

gfx_flush :: () {
    total := gfx_verts.count;
    if total == 0 return;

    first := 0;
    while first < total {
        n := min(total - first, VBUF_VERTS);
        n -= n % 3;
        mapped: D3D11_MAPPED_SUBRESOURCE;
        if FAILED(ID3D11DeviceContext_Map(gfx_ctx, xx gfx_vbuf, 0, .WRITE_DISCARD, 0, *mapped)) break;
        memcpy(mapped.pData, *gfx_verts[first], n * size_of(Gfx_Vertex));
        ID3D11DeviceContext_Unmap(gfx_ctx, xx gfx_vbuf, 0);
        ID3D11DeviceContext_Draw(gfx_ctx, xx n, 0);
        first += n;
    }
    gfx_verts.count = 0;
}

gfx_set_scissor :: (x0: s32, y0: s32, x1: s32, y1: s32) {
    gfx_flush();
    r: RECT;
    r.left = clamp(x0, 0, gfx_w); r.right  = clamp(x1, 0, gfx_w);
    r.top  = clamp(y0, 0, gfx_h); r.bottom = clamp(y1, 0, gfx_h);
    ID3D11DeviceContext_RSSetScissorRects(gfx_ctx, 1, xx *r);
}

gfx_clear_scissor :: () {
    gfx_set_scissor(0, 0, gfx_w, gfx_h);
}

gfx_vertex :: (x: float, y: float, u: float, v: float, c: Vector4) {
    array_add(*gfx_verts, .{x, y, u, v, c.x, c.y, c.z, c.w});
}

// Shapes sample the white block in the atlas.
WHITE_UV :: 1.0 / cast(float) ATLAS_SIZE;

// Between gfx_image_begin and gfx_image_end, shapes are textured instead: uv follows position.
gfx_uv_mapped := false;
gfx_uv_x0, gfx_uv_y0, gfx_uv_u0, gfx_uv_v0, gfx_uv_su, gfx_uv_sv: float;

gfx_shape_vertex :: (x: float, y: float, c: Vector4) {
    if gfx_uv_mapped gfx_vertex(x, y, gfx_uv_u0 + (x - gfx_uv_x0) * gfx_uv_su, gfx_uv_v0 + (y - gfx_uv_y0) * gfx_uv_sv, c);
    else             gfx_vertex(x, y, WHITE_UV, WHITE_UV, c);
}

gfx_tri :: (ax: float, ay: float, bx: float, by: float, cx: float, cy: float, c: Vector4) {
    gfx_shape_vertex(ax, ay, c);
    gfx_shape_vertex(bx, by, c);
    gfx_shape_vertex(cx, cy, c);
}

//
// Images
//
Gfx_Image :: struct {
    tex: *ID3D11Texture2D;
    srv: *ID3D11ShaderResourceView;
    w, h: s32;
}

// RGBA pixels, w * h * 4 bytes. Mipmaps are generated so the image stays smooth when drawn small.
gfx_create_image :: (pixels: *u8, w: s32, h: s32) -> Gfx_Image {
    img: Gfx_Image;
    td: D3D11_TEXTURE2D_DESC;
    td.Width = xx w; td.Height = xx h;
    td.MipLevels = 0; td.ArraySize = 1;   // 0 = full mip chain
    td.Format = .R8G8B8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = .DEFAULT;
    td.BindFlags = .SHADER_RESOURCE | .RENDER_TARGET;   // GenerateMips needs both
    td.MiscFlags = .GENERATE_MIPS;
    if FAILED(ID3D11Device_CreateTexture2D(gfx_device, *td, null, *img.tex)) return .{};
    if FAILED(ID3D11Device_CreateShaderResourceView(gfx_device, xx img.tex, null, *img.srv)) {
        gfx_release(*img.tex);
        return .{};
    }
    ID3D11DeviceContext_UpdateSubresource(gfx_ctx, xx img.tex, 0, null, pixels, xx (w * 4), 0);
    ID3D11DeviceContext_GenerateMips(gfx_ctx, img.srv);
    img.w = w; img.h = h;
    return img;
}

gfx_destroy_image :: (img: *Gfx_Image) {
    gfx_release(*img.srv);
    gfx_release(*img.tex);
    img.* = .{};
}

// Shapes drawn until gfx_image_end show `img` stretched over the rectangle, cropped to keep its
// aspect ratio (like CSS object-fit: cover). Their color multiplies the image.
gfx_image_begin :: (img: Gfx_Image, x0: float, y0: float, x1: float, y1: float) {
    gfx_flush();
    ID3D11DeviceContext_PSSetShader(gfx_ctx, gfx_ps_image, null, 0);
    ID3D11DeviceContext_PSSetShaderResources(gfx_ctx, 0, 1, *img.srv);
    ID3D11DeviceContext_PSSetSamplers(gfx_ctx, 0, 1, *gfx_sampler_linear);

    box_aspect := (x1 - x0) / max(y1 - y0, 1);
    img_aspect := cast(float) img.w / cast(float) max(img.h, 1);
    du: float = 1; dv: float = 1;
    if img_aspect > box_aspect du = box_aspect / img_aspect;
    else                       dv = img_aspect / box_aspect;
    gfx_uv_mapped = true;
    gfx_uv_x0 = x0; gfx_uv_y0 = y0;
    gfx_uv_u0 = (1 - du) * 0.5;
    gfx_uv_v0 = (1 - dv) * 0.5;
    gfx_uv_su = du / max(x1 - x0, 1);
    gfx_uv_sv = dv / max(y1 - y0, 1);
}

gfx_image_end :: () {
    gfx_flush();
    gfx_uv_mapped = false;
    ID3D11DeviceContext_PSSetShader(gfx_ctx, gfx_ps, null, 0);
    ID3D11DeviceContext_PSSetShaderResources(gfx_ctx, 0, 1, *gfx_atlas_srv);
    ID3D11DeviceContext_PSSetSamplers(gfx_ctx, 0, 1, *gfx_sampler);
}

//
// Text
//
gfx_load_font :: (path: string) -> bool {
    data, ok := read_entire_file(path);
    if !ok return false;
    ft_font_data = data;
    error := FT_New_Memory_Face(ft_library, ft_font_data.data, cast(s32) ft_font_data.count, 0, *ft_face);
    return error == 0;
}

gfx_set_px :: (px: s32) {
    if ft_face_px != px {
        FT_Set_Pixel_Sizes(ft_face, 0, xx px);
        ft_face_px = px;
    }
}

gfx_glyph :: (px: s32, cp: u32) -> *Gfx_Glyph {
    px64 := cast(u64) px;
    cp64 := cast(u64) cp;
    key  := (px64 << 32) | cp64;
    found := table_find_pointer(*glyph_cache, key);
    if found return found;

    gfx_set_px(px);
    index := FT_Get_Char_Index(ft_face, cp);
    FT_Load_Glyph(ft_face, index, FT_LOAD_RENDER);
    slot := ft_face.glyph;
    bm := *slot.bitmap;

    g: Gfx_Glyph;
    g.w = cast(s32) bm.width;
    g.h = cast(s32) bm.rows;
    g.left = slot.bitmap_left;
    g.top  = slot.bitmap_top;
    g.advance = cast(s32) (slot.advance.x >> 6);

    if g.w > 0 && g.h > 0 {
        if atlas_x + g.w + 1 > ATLAS_SIZE {
            atlas_x = 0;
            atlas_y += atlas_row_h + 1;
            atlas_row_h = 0;
        }
        if atlas_y + g.h + 1 > ATLAS_SIZE {
            // Atlas full: flush what refers to it and start over.
            gfx_flush();
            gfx_reset_atlas();
            return gfx_glyph(px, cp);
        }
        g.x0 = atlas_x;
        g.y0 = atlas_y;
        atlas_x += g.w + 1;
        atlas_row_h = max(atlas_row_h, g.h);

        box: D3D11_BOX;
        box.left = xx g.x0; box.top = xx g.y0; box.front = 0;
        box.right = xx (g.x0 + g.w); box.bottom = xx (g.y0 + g.h); box.back = 1;
        ID3D11DeviceContext_UpdateSubresource(gfx_ctx, xx gfx_atlas, 0, *box, bm.buffer, xx bm.pitch, 0);
    }

    return table_add(*glyph_cache, key, g);
}

gfx_text_width :: (px: s32, s: string) -> float {
    w: s32 = 0;
    str := s;
    while str.count > 0 {
        cp := utf8_next_character(*str);
        w += gfx_glyph(px, cp).advance;
    }
    return cast(float) w;
}

// Height of a lowercase letter; used to center text vertically.
gfx_ascender :: (px: s32) -> float {
    return cast(float) gfx_glyph(px, #char "m").top;
}

gfx_text :: (px: s32, x: float, baseline: float, s: string, c: Vector4) -> float {
    inv := 1.0 / cast(float) ATLAS_SIZE;
    pen := cast(float) cast(s32) x;
    by  := cast(float) cast(s32) baseline;
    str := s;
    while str.count > 0 {
        cp := utf8_next_character(*str);
        g := gfx_glyph(px, cp);
        if g.w > 0 {
            gx := pen + cast(float) g.left;
            gy := by  - cast(float) g.top;
            u0 := cast(float) g.x0 * inv;           v0 := cast(float) g.y0 * inv;
            u1 := cast(float) (g.x0 + g.w) * inv;   v1 := cast(float) (g.y0 + g.h) * inv;
            x1 := gx + cast(float) g.w;             y1 := gy + cast(float) g.h;
            gfx_vertex(gx, gy, u0, v0, c); gfx_vertex(x1, gy, u1, v0, c); gfx_vertex(x1, y1, u1, v1, c);
            gfx_vertex(gx, gy, u0, v0, c); gfx_vertex(x1, y1, u1, v1, c); gfx_vertex(gx, y1, u0, v1, c);
        }
        pen += cast(float) g.advance;
    }
    return pen - cast(float) cast(s32) x;
}
