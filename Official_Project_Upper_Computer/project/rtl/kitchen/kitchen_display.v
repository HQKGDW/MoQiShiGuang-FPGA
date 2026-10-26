`timescale 1ns/1ps

// 1280x720@60 timing and the pixel pipeline of the kitchen console:
//
//   s1  tile address from the counters
//   s2  tile word (RAM port B) -> font addresses
//   s3  font ROMs
//   s4  glyph bit, background with the highlight pulse, decoration
//   s5  tile colour, popup fade
//   s6-s7  delay (the boot layer needs seven stages)
//   s8  ticker, boot layer and page transition, then the output register
//
// vs / de are delayed to stay aligned with the pixel.
module kitchen_display (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        front,            // tile buffer to show
    output reg  [11:0] tile_addr,        // tile RAM port B
    input  wire [31:0] tile_data,
    input  wire [6:0]  hi_elem,          // element whose tiles pulse
    input  wire [3:0]  pulse,
    input  wire [4:0]  popup_alpha,      // 0..16
    input  wire [23:0] accent,           // popup text and bars (mode 0110)
    input  wire        ticker_enable,
    input  wire [1:0]  ticker_line,
    input  wire [3:0]  ticker_speed,     // 1..10
    input  wire [1:0]  trans_kind,       // 0 none, 1 next, 2 previous, 3 centre
    input  wire [1:0]  trans_phase,      // 0 idle, 1 out, 2 hold, 3 in
    input  wire [4:0]  trans_level,      // 0..16
    input  wire [9:0]  boot_t,           // boot animation frame
    input  wire        boot_layer_on,    // scene A / shutter owns the screen
    output wire        frame_start,      // one clock at the start of vertical sync
    output reg         vs_out,
    output reg         de_out,
    output reg  [23:0] rgb_out
);
`include "kitchen_ui_defs.vh"

    localparam integer H_TOTAL = 1650, H_START = 370;
    localparam integer V_TOTAL = 750, V_START = 30;
    localparam [23:0] LINE_RGB   = 24'h2a3441;
    localparam [23:0] LEADER_RGB = 24'h3a4552;
    localparam [23:0] GRID_RGB   = 24'h1a212b;

    function [23:0] palette;
        input [3:0] index;
        begin
            palette = (index == COL_POPUP_FG) ? accent : palette_base(index);
        end
    endfunction

    function [7:0] mix8;              // a + (b - a) * w / 16
        input [7:0] a;
        input [7:0] b;
        input [4:0] w;
        reg signed [9:0] diff;
        reg signed [15:0] scaled;
        begin
            diff = $signed({2'b00, b}) - $signed({2'b00, a});
            scaled = diff * $signed({1'b0, w});
            mix8 = a + scaled[11:4];
        end
    endfunction

    function [23:0] mix24;
        input [23:0] a;
        input [23:0] b;
        input [4:0] w;
        begin
            mix24 = {mix8(a[23:16], b[23:16], w), mix8(a[15:8], b[15:8], w), mix8(a[7:0], b[7:0], w)};
        end
    endfunction

    function [7:0] add8;
        input [7:0] a;
        input [5:0] b;
        reg [8:0] s;
        begin
            s = a + b;
            add8 = s[8] ? 8'hff : s[7:0];
        end
    endfunction

    // ------------------------------------------------------------ timing
    reg [10:0] h;
    reg [9:0]  v;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h <= 11'd0;
            v <= 10'd0;
        end else if (h == H_TOTAL - 1) begin
            h <= 11'd0;
            v <= (v == V_TOTAL - 1) ? 10'd0 : v + 1'b1;
        end else begin
            h <= h + 1'b1;
        end
    end
    wire        de0 = h >= H_START && v >= V_START;
    wire        vs0 = v >= 10'd5 && v < 10'd10;
    wire [10:0] x0 = h - H_START;
    wire [9:0]  y0 = v - V_START;
    assign frame_start = h == 11'd0 && v == 10'd5;

    // ------------------------------------------------------------ s1
    reg [10:0] x1; reg [9:0] y1; reg de1, vs1;
    wire [4:0] row0 = y0[9:5];
    wire [6:0] col0 = x0[10:4];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x1 <= 11'd0; y1 <= 10'd0; de1 <= 1'b0; vs1 <= 1'b0; tile_addr <= 12'd0;
        end else begin
            x1 <= x0; y1 <= y0; de1 <= de0; vs1 <= vs0;
            tile_addr <= {front, {row0, 6'd0} + {2'd0, row0, 4'd0} + {4'd0, col0}};
        end
    end

    // ------------------------------------------------------------ s2: tile word
    reg [10:0] x2; reg [9:0] y2; reg de2, vs2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x2 <= 11'd0; y2 <= 10'd0; de2 <= 1'b0; vs2 <= 1'b0;
        end else begin
            x2 <= x1; y2 <= y1; de2 <= de1; vs2 <= vs1;
        end
    end
    wire       t_glyph = tile_data[31];
    wire       t_cjk   = tile_data[30];
    wire       t_half  = tile_data[29];
    wire [1:0] t_vpos  = tile_data[28:27];
    wire [7:0] t_code  = tile_data[26:19];
    wire [4:0] sub_y2  = y2[4:0];
    wire [4:0] glyph_row = (t_vpos == 2'd0) ? sub_y2 : {~sub_y2[4], sub_y2[3:0]};
    wire       glyph_vis = t_glyph && (t_vpos == 2'd0 || (t_vpos == 2'd1 && sub_y2[4]) ||
                                       (t_vpos == 2'd2 && !sub_y2[4]));

    // ------------------------------------------------------------ s3: fonts
    reg [13:0] cjk_addr;
    reg [11:0] ascii_addr;
    reg [10:0] x3; reg [9:0] y3; reg de3, vs3;
    reg        vis3, cjk3;
    reg [1:0]  vpos3, vpos4;
    reg [3:0]  fg3, bg3, deco3;
    reg [6:0]  elem3;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cjk_addr <= 14'd0; ascii_addr <= 12'd0;
            x3 <= 11'd0; y3 <= 10'd0; de3 <= 1'b0; vs3 <= 1'b0;
            vis3 <= 1'b0; cjk3 <= 1'b0; vpos3 <= 2'd0; fg3 <= 4'd0; bg3 <= 4'd0; deco3 <= 4'd0; elem3 <= 7'd0;
        end else begin
            cjk_addr <= {t_code, glyph_row, t_half};
            ascii_addr <= {t_code[6:0], glyph_row};
            x3 <= x2; y3 <= y2; de3 <= de2; vs3 <= vs2;
            vis3 <= glyph_vis; cjk3 <= t_cjk; vpos3 <= t_vpos;
            fg3 <= tile_data[18:15]; bg3 <= tile_data[14:11];
            deco3 <= tile_data[10:7]; elem3 <= tile_data[6:0];
        end
    end
    wire [15:0] cjk_bits, ascii_bits;
    kitchen_rom #(.WIDTH(16), .DEPTH(CJK_FONT_DEPTH), .ADDR_W(14), .FILE("kitchen_font_cjk"),
                  .IMPLEMENT("32K")) u_cjk_font (.clk(clk), .addr(cjk_addr), .data(cjk_bits));
    kitchen_rom #(.WIDTH(16), .DEPTH(4096), .ADDR_W(12), .FILE("kitchen_font_ascii"),
                  .IMPLEMENT("9K")) u_ascii_font (.clk(clk), .addr(ascii_addr), .data(ascii_bits));

    // ------------------------------------------------------------ s4
    reg [10:0] x4; reg [9:0] y4; reg de4, vs4;
    reg        vis4, cjk4;
    reg [3:0]  fg4, bg4, deco4;
    reg [6:0]  elem4;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x4 <= 11'd0; y4 <= 10'd0; de4 <= 1'b0; vs4 <= 1'b0;
            vis4 <= 1'b0; cjk4 <= 1'b0; vpos4 <= 2'd0; fg4 <= 4'd0; bg4 <= 4'd0; deco4 <= 4'd0; elem4 <= 7'd0;
        end else begin
            x4 <= x3; y4 <= y3; de4 <= de3; vs4 <= vs3;
            vis4 <= vis3; cjk4 <= cjk3; vpos4 <= vpos3; fg4 <= fg3; bg4 <= bg3; deco4 <= deco3; elem4 <= elem3;
        end
    end
    wire [3:0] sx4 = x4[3:0];
    wire [4:0] sy4 = y4[4:0];
    wire       glyph_bit = vis4 && (cjk4 ? cjk_bits[4'd15 - sx4] : ascii_bits[4'd15 - sx4]);

    // Rounded corner, radius 8: first inside column for each of the 8 rows.
    function [3:0] corner_min_x;
        input [2:0] r;
        begin
            case (r)
                3'd0: corner_min_x = 4'd5;
                3'd1: corner_min_x = 4'd3;
                3'd2: corner_min_x = 4'd2;
                3'd3, 3'd4: corner_min_x = 4'd1;
                default: corner_min_x = 4'd0;
            endcase
        end
    endfunction
    // Status dot, radius 5 around (8, 16): half width for each |dy|.
    function [3:0] dot_half;
        input [4:0] ady;
        begin
            case (ady)
                5'd0: dot_half = 4'd5;
                5'd1, 5'd2, 5'd3: dot_half = 4'd4;
                5'd4: dot_half = 4'd3;
                default: dot_half = 4'd0;
            endcase
        end
    endfunction

    reg [23:0] bg_rgb, deco_rgb;
    reg        deco_hit, corner_out, corner_deco;
    // Bar segment rows: 8..23, or 24..31 / 0..7 for the halves of a lowered bar.
    wire       seg_rows = (vpos4 == 2'd1) ? sy4 >= 5'd24 :
                          (vpos4 == 2'd2) ? sy4 < 5'd8 : (sy4 >= 5'd8 && sy4 < 5'd24);
    reg [3:0]  csx;
    reg [2:0]  csy;
    reg [3:0]  adx;
    reg [4:0]  ady;
    always @* begin
        bg_rgb = palette(bg4);
        if (bg4 == COL_BG_MAIN && x4[4:0] == 5'd0 && y4[4:0] == 5'd0)
            bg_rgb = GRID_RGB;
        if (hi_elem != 7'd0 && elem4 == hi_elem)
            bg_rgb = {add8(bg_rgb[23:16], {pulse, 1'b0}), add8(bg_rgb[15:8], {pulse, 1'b0}),
                      add8(bg_rgb[7:0], {pulse, 1'b0})};

        // Corner geometry (mirrored per corner).
        corner_deco = deco4 == DECO_CORNER_TL || deco4 == DECO_CORNER_TR ||
                      deco4 == DECO_CORNER_BL || deco4 == DECO_CORNER_BR;
        csx = (deco4 == DECO_CORNER_TR || deco4 == DECO_CORNER_BR) ? 4'd15 - sx4 : sx4;
        csy = (deco4 == DECO_CORNER_BL || deco4 == DECO_CORNER_BR) ? 3'd7 - sy4[2:0] : sy4[2:0];
        corner_out = csx < 4'd8 && csx < corner_min_x(csy) &&
                     ((deco4 == DECO_CORNER_TL || deco4 == DECO_CORNER_TR) ? sy4 < 5'd8 : sy4 >= 5'd24);
        adx = (sx4 >= 4'd8) ? sx4 - 4'd8 : 4'd8 - sx4;
        ady = (sy4 >= 5'd16) ? sy4 - 5'd16 : 5'd16 - sy4;

        deco_hit = 1'b0;
        deco_rgb = palette(COL_AMBER);
        case (deco4)
            DECO_LBAR:          deco_hit = sx4 < 4'd4;
            DECO_BOTTOM:        begin deco_hit = sy4 >= 5'd30; deco_rgb = LINE_RGB; end
            DECO_TOP:           begin deco_hit = sy4 < 5'd2;   deco_rgb = LINE_RGB; end
            DECO_RIGHT:         begin deco_hit = sx4 >= 4'd14; deco_rgb = LINE_RGB; end
            DECO_LEFT:          begin deco_hit = sx4 < 4'd2;   deco_rgb = LINE_RGB; end
            DECO_SEG_ON:        begin deco_hit = sx4 >= 4'd2 && sx4 <= 4'd13 && seg_rows;
                                      deco_rgb = palette(fg4); end
            DECO_SEG_OFF:       begin deco_hit = sx4 >= 4'd2 && sx4 <= 4'd13 && seg_rows;
                                      deco_rgb = LINE_RGB; end
            DECO_DOT:           begin deco_hit = ady < 5'd5 && adx <= dot_half(ady);
                                      deco_rgb = palette(fg4); end
            DECO_CORNER_TL, DECO_CORNER_TR, DECO_CORNER_BL, DECO_CORNER_BR:
                                begin deco_hit = corner_out; deco_rgb = palette(COL_BG_MAIN); end
            DECO_TOP_ACCENT:    deco_hit = sy4 < 5'd3;
            DECO_BOTTOM_ACCENT: deco_hit = sy4 >= 5'd29;
            DECO_LEADER:        begin deco_hit = (sy4 == 5'd20 || sy4 == 5'd21) && sx4[2:0] == 3'd0;
                                      deco_rgb = LEADER_RGB; end
            default: ;
        endcase
    end

    // ------------------------------------------------------------ s5: tile colour
    reg [10:0] x5; reg [9:0] y5; reg de5, vs5;
    reg        glyph5, deco_hit5, corner5, popup5;
    reg [23:0] fg_rgb5, bg_rgb5, deco_rgb5;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x5 <= 11'd0; y5 <= 10'd0; de5 <= 1'b0; vs5 <= 1'b0;
            glyph5 <= 1'b0; deco_hit5 <= 1'b0; corner5 <= 1'b0; popup5 <= 1'b0;
            fg_rgb5 <= 24'd0; bg_rgb5 <= 24'd0; deco_rgb5 <= 24'd0;
        end else begin
            x5 <= x4; y5 <= y4; de5 <= de4; vs5 <= vs4;
            glyph5 <= glyph_bit; deco_hit5 <= deco_hit; corner5 <= corner_deco && deco_hit;
            popup5 <= bg4 == COL_POPUP_BG;
            fg_rgb5 <= palette(fg4); bg_rgb5 <= bg_rgb; deco_rgb5 <= deco_rgb;
        end
    end
    reg [23:0] tile_rgb;
    always @* begin
        if (corner5)
            tile_rgb = deco_rgb5;
        else if (glyph5)
            tile_rgb = fg_rgb5;
        else if (deco_hit5)
            tile_rgb = deco_rgb5;
        else
            tile_rgb = bg_rgb5;
        // The popup fades as a whole towards the page background.
        if (popup5)
            tile_rgb = mix24(palette(COL_BG_MAIN), tile_rgb, popup_alpha);
    end

    // ------------------------------------------------------------ ticker
    // Text repeats every 640 px; 16 glyph cells then 4 blank ones.
    reg [12:0] scroll;            // 1/8 px, wraps at 640 px
    reg [3:0]  speed_q;
    reg [5:0]  scroll_step;
    always @* begin
        case (speed_q)
            4'd1: scroll_step = 6'd4;   4'd2: scroll_step = 6'd6;   4'd3: scroll_step = 6'd8;
            4'd4: scroll_step = 6'd12;  4'd6: scroll_step = 6'd20;  4'd7: scroll_step = 6'd24;
            4'd8: scroll_step = 6'd32;  4'd9: scroll_step = 6'd40;  4'd10: scroll_step = 6'd48;
            default: scroll_step = 6'd16;
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scroll <= 13'd0;
            speed_q <= 4'd5;
        end else begin
            if (ticker_speed >= 4'd1 && ticker_speed <= 4'd10)
                speed_q <= ticker_speed;
            if (frame_start)
                scroll <= (scroll + scroll_step >= 13'd5120) ? scroll + scroll_step - 13'd5120 :
                                                               scroll + scroll_step;
        end
    end
    wire [11:0] stream1 = x1 + scroll[12:3];
    wire [10:0] wrap1 = (stream1 >= 12'd1280) ? stream1 - 12'd1280 :
                        (stream1 >= 12'd640) ? stream1 - 12'd640 : stream1[10:0];
    wire [4:0]  cell1 = wrap1[9:5];
    wire [31:0] tk_bits;
    reg  [9:0]  tk_addr;
    reg  [4:0]  tk_bitx2, tk_bitx3;
    reg         tk_row2, tk_row3, tk_row4;
    reg         tk_bit4;
    wire [4:0]  tk_glyph1 = (cell1 < 5'd16) ? ticker_glyph(ticker_line, cell1[3:0]) : 5'd0;
    wire [4:0]  tk_y1 = y1 - 10'd680;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tk_addr <= 10'd0; tk_bitx2 <= 5'd0; tk_bitx3 <= 5'd0;
            tk_row2 <= 1'b0; tk_row3 <= 1'b0; tk_row4 <= 1'b0; tk_bit4 <= 1'b0;
        end else begin
            tk_addr <= {tk_glyph1, tk_y1};
            tk_bitx2 <= wrap1[4:0];
            tk_row2 <= ticker_enable && y1 >= 10'd680 && y1 < 10'd712;
            tk_bitx3 <= tk_bitx2;
            tk_row3 <= tk_row2;
            tk_row4 <= tk_row3;
            tk_bit4 <= tk_row3 && tk_bits[5'd31 - tk_bitx3];
        end
    end
    kitchen_rom #(.WIDTH(32), .DEPTH(TICKER_FONT_DEPTH), .ADDR_W(10), .FILE("kitchen_ticker_font"),
                  .IMPLEMENT("9K")) u_ticker_font (.clk(clk), .addr(tk_addr), .data(tk_bits));

    // ------------------------------------------------------------ boot layer
    wire        boot_on8;
    wire [23:0] boot_rgb8;
    kitchen_boot_layer u_boot_layer (
        .clk(clk), .rst_n(rst_n), .boot_t(boot_t), .layer_on(boot_layer_on),
        .x(x1), .y(y1), .on(boot_on8), .rgb(boot_rgb8));

    // ------------------------------------------------------------ s6..s8
    reg [10:0] x6, x7, x8; reg [9:0] y6, y7, y8;
    reg        de6, de7, de8, vs6, vs7, vs8;
    reg [23:0] rgb6, rgb7, rgb8;
    reg        tk_bit5, tk_bit6, tk_bit7, tk_bit8;
    wire [23:0] ticker7 = !tk_bit7 ? rgb7 :
                          (ticker_line == 2'd1) ? palette(COL_AMBER) :
                          (ticker_line == 2'd2) ? palette(COL_GREEN) : palette(COL_CYAN);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x6 <= 11'd0; x7 <= 11'd0; x8 <= 11'd0; y6 <= 10'd0; y7 <= 10'd0; y8 <= 10'd0;
            de6 <= 1'b0; de7 <= 1'b0; de8 <= 1'b0; vs6 <= 1'b0; vs7 <= 1'b0; vs8 <= 1'b0;
            rgb6 <= 24'd0; rgb7 <= 24'd0; rgb8 <= 24'd0;
            tk_bit5 <= 1'b0; tk_bit6 <= 1'b0; tk_bit7 <= 1'b0; tk_bit8 <= 1'b0;
        end else begin
            x6 <= x5; x7 <= x6; x8 <= x7; y6 <= y5; y7 <= y6; y8 <= y7;
            de6 <= de5; de7 <= de6; de8 <= de7; vs6 <= vs5; vs7 <= vs6; vs8 <= vs7;
            rgb6 <= tile_rgb; rgb7 <= rgb6;
            // Ticker text, then the centre transition's fade-out.
            if (trans_kind == 2'd3 && trans_phase == 2'd1)
                rgb8 <= mix24(ticker7, palette(COL_BG_MAIN), trans_level);
            else
                rgb8 <= ticker7;
            tk_bit5 <= tk_bit4; tk_bit6 <= tk_bit5; tk_bit7 <= tk_bit6; tk_bit8 <= tk_bit7;
        end
    end

    wire [10:0] wipe_x = {trans_level, 6'd0} + {2'd0, trans_level, 4'd0};      // level * 80
    wire [9:0]  iris_w = {trans_level, 5'd0} + {2'd0, trans_level, 3'd0};      // level * 40
    wire [9:0]  iris_h = {1'b0, trans_level, 4'd0} + {3'd0, trans_level, 2'd0} +
                         {4'd0, trans_level, 1'b0} + {5'd0, trans_level};        // level * 23
    wire [10:0] adx8 = (x8 >= 11'd640) ? x8 - 11'd640 : 11'd640 - x8;
    wire [9:0]  ady8 = (y8 >= 10'd360) ? y8 - 10'd360 : 10'd360 - y8;
    reg [23:0]  final_rgb;
    reg         covered, edge_glow;
    reg [10:0]  bound;
    always @* begin
        final_rgb = rgb8;
        if (boot_on8)
            final_rgb = boot_rgb8;

        covered = 1'b0;
        edge_glow = 1'b0;
        bound = 11'd0;
        case (trans_kind)
            2'd1: begin                        // next page: moves right to left
                bound = 11'd1280 - wipe_x;
                if (trans_phase == 2'd1) begin
                    covered = x8 >= bound;
                    edge_glow = covered && x8 < bound + 11'd4;
                end else if (trans_phase == 2'd3) begin
                    covered = x8 < bound;
                    edge_glow = covered && x8 + 11'd4 >= bound;
                end
            end
            2'd2: begin                        // previous page: left to right
                bound = wipe_x;
                if (trans_phase == 2'd1) begin
                    covered = x8 < bound;
                    edge_glow = covered && x8 + 11'd4 >= bound;
                end else if (trans_phase == 2'd3) begin
                    covered = x8 >= bound;
                    edge_glow = covered && x8 < bound + 11'd4;
                end
            end
            2'd3: begin                        // centre: fade out, open from the middle
                if (trans_phase == 2'd3) begin
                    covered = adx8 >= {1'b0, iris_w} || ady8 >= iris_h;
                    edge_glow = covered && adx8 < {1'b0, iris_w} + 11'd3 && ady8 < iris_h + 10'd3;
                end
            end
            default: ;
        endcase
        if (trans_kind != 2'd0 && trans_phase == 2'd2)
            covered = 1'b1;
        if (covered)
            final_rgb = edge_glow ? palette(COL_AMBER) : palette(COL_BG_MAIN);
        if (!de8)
            final_rgb = 24'd0;
    end

    // ------------------------------------------------------------ output
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_out <= 1'b0; de_out <= 1'b0; rgb_out <= 24'd0;
        end else begin
            vs_out <= vs8; de_out <= de8; rgb_out <= final_rgb;
        end
    end
endmodule
