`timescale 1ns/1ps

module status_osd_720p #(
    parameter integer H_ACTIVE = 1280,
    parameter integer V_ACTIVE = 720,
    parameter integer HUD_X = 24,
    parameter integer HUD_Y = 20
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        vs,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [2:0]  image_index,
    input  wire [3:0]  image_count,
    input  wire        auto_enabled,
    input  wire        loading,
    input  wire [3:0]  resident_mask,
    input  wire [3:0]  elapsed_seconds,
    input  wire [3:0]  elapsed_tenths,
    input  wire [3:0]  elapsed_hundredths,
    input  wire [7:0]  brightness,
    input  wire [7:0]  contrast,
    input  wire [7:0]  volume,
    input  wire [3:0]  ticker_speed,      // 1 slowest .. 10 fastest, 5 = 1 px/frame
    // Ticker glyph RAM write port (the kitchen streams the texts over the link).
    input  wire        ticker_wclk,
    input  wire        ticker_we,
    input  wire [9:0]  ticker_waddr,
    input  wire [27:0] ticker_wdata,
    output reg         vs_out,
    output reg         de_out,
    output reg  [23:0] rgb_out,
    output reg         osd_active
);
    localparam integer CELL_W = 16;
    localparam integer GLYPH_SCALE = 2;
    localparam integer HUD_TEXT_X = HUD_X + 8;
    localparam integer HUD_TEXT_Y = HUD_Y + 14;
    localparam integer HUD_CHARS = 34;
    localparam integer HUD_W = HUD_CHARS * CELL_W + 16;
    localparam integer HUD_H = 42;
    localparam integer TICKER_Y = V_ACTIVE - 30;
    localparam integer TICKER_TEXT_Y = TICKER_Y + 1;
    localparam integer TICKER_CHARS = 28;
    localparam integer TICKER_WIDTH = TICKER_CHARS * 32;
    localparam integer SCROLL_CYCLE = H_ACTIVE + TICKER_WIDTH;

    reg [10:0] pixel_x;
    reg [9:0]  line_y;
    reg        de_q;
    reg        vs_q;
    reg [2:0]  image_q;
    reg [3:0]  image_count_q;
    reg        auto_q;
    reg        loading_q;
    reg [3:0]  resident_q;
    reg [3:0]  elapsed_seconds_q;
    reg [3:0]  elapsed_tenths_q;
    reg [3:0]  elapsed_hundredths_q;
    reg [11:0] scroll_pos;
    reg [2:0]  scroll_frac;               // eighths of a pixel
    reg [3:0]  ticker_speed_q;
    reg [3:0]  speed_level;
    reg [4:0]  scroll_step;               // eighths of a pixel per frame
    wire [15:0] scroll_next = {1'b0, scroll_pos, scroll_frac} + scroll_step;
    wire       frame_start = !vs_q && vs;

    always @* begin
        case (speed_level)
            4'd1:  scroll_step = 5'd2;
            4'd2:  scroll_step = 5'd3;
            4'd3:  scroll_step = 5'd4;
            4'd4:  scroll_step = 5'd6;
            4'd6:  scroll_step = 5'd10;
            4'd7:  scroll_step = 5'd12;
            4'd8:  scroll_step = 5'd16;
            4'd9:  scroll_step = 5'd20;
            4'd10: scroll_step = 5'd24;
            default: scroll_step = 5'd8;
        endcase
    end
    wire [2:0] resident_count = resident_q[0] + resident_q[1] +
                                resident_q[2] + resident_q[3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_x <= 11'd0;
            line_y <= 10'd0;
            de_q <= 1'b0;
            vs_q <= 1'b0;
            image_q <= 3'd0;
            image_count_q <= 4'd0;
            auto_q <= 1'b0;
            loading_q <= 1'b0;
            resident_q <= 4'b0000;
            elapsed_seconds_q <= 4'd0;
            elapsed_tenths_q <= 4'd0;
            elapsed_hundredths_q <= 4'd0;
            scroll_pos <= 12'd0;
            scroll_frac <= 3'd0;
            ticker_speed_q <= 4'd5;
            speed_level <= 4'd5;
        end else begin
            de_q <= de;
            vs_q <= vs;
            ticker_speed_q <= ticker_speed;
            if (ticker_speed == ticker_speed_q && ticker_speed != 4'd0 && ticker_speed <= 4'd10)
                speed_level <= ticker_speed;

            if (!de)
                pixel_x <= 11'd0;
            else if (!de_q)
                pixel_x <= 11'd1;
            else
                pixel_x <= pixel_x + 1'b1;

            if (vs)
                line_y <= 10'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;

            if (frame_start) begin
                image_q <= image_index;
                image_count_q <= image_count;
                auto_q <= auto_enabled;
                loading_q <= loading;
                resident_q <= resident_mask;
                elapsed_seconds_q <= elapsed_seconds;
                elapsed_tenths_q <= elapsed_tenths;
                elapsed_hundredths_q <= elapsed_hundredths;
                if (scroll_next[15:3] >= SCROLL_CYCLE)
                    scroll_pos <= scroll_next[14:3] - SCROLL_CYCLE;
                else
                    scroll_pos <= scroll_next[14:3];
                scroll_frac <= scroll_next[2:0];
            end
        end
    end

    function [23:0] darken_half;
        input [23:0] color;
        begin
            darken_half = {1'b0, color[23:17],
                           1'b0, color[15:9],
                           1'b0, color[7:1]};
        end
    endfunction

    function [7:0] hud_char;
        input integer index;
        begin
            case (index)
                0: hud_char = "P";
                1: hud_char = "I";
                2: hud_char = "C";
                3: hud_char = " ";
                4: hud_char = "1" + image_q;
                5: hud_char = "/";
                6: hud_char = "0" + image_count_q;
                7: hud_char = " ";
                8: hud_char = "|";
                9: hud_char = " ";
                10: hud_char = loading_q ? "L" : (auto_q ? "A" : "M");
                11: hud_char = loading_q ? "O" : (auto_q ? "U" : "A");
                12: hud_char = loading_q ? "A" : (auto_q ? "T" : "N");
                13: hud_char = loading_q ? "D" : (auto_q ? "O" : "U");
                14: hud_char = loading_q ? "I" : (auto_q ? " " : "A");
                // AUTO shows the time on the picture, up to 15 s: " 8.00", "12.50".
                15: hud_char = loading_q ? "N" :
                               (auto_q ? (elapsed_seconds_q >= 4'd10 ? "1" : " ") : "L");
                16: hud_char = loading_q ? "G" :
                               (auto_q ? "0" + (elapsed_seconds_q >= 4'd10 ?
                                                elapsed_seconds_q - 4'd10 : elapsed_seconds_q) : " ");
                17: hud_char = auto_q && !loading_q ? "." : " ";
                18: hud_char = auto_q && !loading_q ? "0" + elapsed_tenths_q : " ";
                19: hud_char = auto_q && !loading_q ? "0" + elapsed_hundredths_q : " ";
                20: hud_char = " ";
                21: hud_char = "|";
                22: hud_char = " ";
                23: hud_char = "B";
                24: hud_char = "A";
                25: hud_char = "N";
                26: hud_char = "K";
                27: hud_char = " ";
                28: hud_char = "0" + resident_count;
                29: hud_char = "/";
                30: hud_char = "4";
                31: hud_char = " ";
                32: hud_char = "|";
                33: hud_char = " ";
                default: hud_char = " ";
            endcase
        end
    endfunction

    function [4:0] glyph_row;
        input [7:0] character;
        input [2:0] row;
        begin
            glyph_row = 5'b00000;
            case (character)
                "0": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10011;3:glyph_row=5'b10101;4:glyph_row=5'b11001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "1": case(row) 0:glyph_row=5'b00100;1:glyph_row=5'b01100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "2": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b00001;3:glyph_row=5'b00010;4:glyph_row=5'b00100;5:glyph_row=5'b01000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "3": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b00001;2:glyph_row=5'b00001;3:glyph_row=5'b01110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "4": case(row) 0:glyph_row=5'b00010;1:glyph_row=5'b00110;2:glyph_row=5'b01010;3:glyph_row=5'b10010;4:glyph_row=5'b11111;5:glyph_row=5'b00010;6:glyph_row=5'b00010;default:glyph_row=0;endcase
                "5": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "6": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "7": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b01000;6:glyph_row=5'b01000;default:glyph_row=0;endcase
                "8": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "9": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01111;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                ".": case(row) 0:glyph_row=5'b00000;1:glyph_row=5'b00000;2:glyph_row=5'b00000;3:glyph_row=5'b00000;4:glyph_row=5'b00000;5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "A": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "B": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "C": case(row) 0:glyph_row=5'b01111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b01111;default:glyph_row=0;endcase
                "D": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "E": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "F": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                "G": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10000;3:glyph_row=5'b10111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "H": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "I": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "K": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10010;2:glyph_row=5'b10100;3:glyph_row=5'b11000;4:glyph_row=5'b10100;5:glyph_row=5'b10010;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "L": case(row) 0:glyph_row=5'b10000;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "M": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b11011;2:glyph_row=5'b10101;3:glyph_row=5'b10101;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "N": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b11001;2:glyph_row=5'b10101;3:glyph_row=5'b10011;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "O": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "P": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                "R": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10100;5:glyph_row=5'b10010;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "S": case(row) 0:glyph_row=5'b01111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b01110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "T": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "U": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "Y": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b01010;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "/": case(row) 0:glyph_row=5'b00001;1:glyph_row=5'b00010;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b01000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                ":": case(row) 0:glyph_row=5'b00000;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00000;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00000;default:glyph_row=0;endcase
                "|": case(row) 0:glyph_row=5'b00100;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                default: glyph_row = 5'b00000;
            endcase
        end
    endfunction

    integer hud_local_x;
    integer hud_cell;
    integer hud_col;
    integer hud_row;
    integer ticker_stream_x;
    integer ticker_cell;
    integer ticker_col;
    integer ticker_row;
    reg [7:0] selected_char;
    reg [4:0] selected_row;
    reg [9:0] ticker_address;
    reg [4:0] ticker_col_value;
    reg ticker_visible;
    reg hud_pixel;
    reg hud_region;
    reg ticker_region;
    reg hud_border;
    reg [23:0] rgb_in_pipe;
    reg [7:0] selected_char_pipe;
    reg [2:0] hud_row_pipe;
    reg [2:0] hud_col_pipe;
    reg hud_text_visible_pipe;
    reg [4:0] ticker_col_pipe;
    reg ticker_visible_pipe;
    reg hud_region_pipe;
    reg ticker_region_pipe;
    reg hud_border_pipe;
    reg [5:0] hud_cell_pipe;
    reg loading_pipe;
    reg [2:0] resident_count_pipe;
    wire [27:0] ticker_bits;
    wire [4:0] hud_glyph_pipe = glyph_row(selected_char_pipe, hud_row_pipe);

    ticker_font_rom u_ticker_font_rom (
        .clk(clk), .address(ticker_address), .bits(ticker_bits),
        .wclk(ticker_wclk), .we(ticker_we), .waddr(ticker_waddr), .wdata(ticker_wdata)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_out <= 1'b0;
            de_out <= 1'b0;
            rgb_in_pipe <= 24'd0;
            selected_char_pipe <= " ";
            hud_row_pipe <= 3'd0;
            hud_col_pipe <= 3'd0;
            hud_text_visible_pipe <= 1'b0;
            ticker_col_pipe <= 5'd0;
            ticker_visible_pipe <= 1'b0;
            hud_region_pipe <= 1'b0;
            ticker_region_pipe <= 1'b0;
            hud_border_pipe <= 1'b0;
            hud_cell_pipe <= 6'd0;
            loading_pipe <= 1'b0;
            resident_count_pipe <= 3'd0;
        end else begin
            vs_out <= vs;
            de_out <= de;
            rgb_in_pipe <= rgb_in;
            selected_char_pipe <= selected_char;
            hud_row_pipe <= hud_row[2:0];
            hud_col_pipe <= hud_col[2:0];
            hud_text_visible_pipe <= hud_col < 5 && hud_row < 7;
            ticker_col_pipe <= ticker_col_value;
            ticker_visible_pipe <= ticker_visible;
            hud_region_pipe <= hud_region;
            ticker_region_pipe <= ticker_region;
            hud_border_pipe <= hud_border;
            hud_cell_pipe <= hud_cell;
            loading_pipe <= loading_q;
            resident_count_pipe <= resident_count;
        end
    end

    always @* begin
        hud_local_x = pixel_x - HUD_TEXT_X;
        hud_cell = 0;
        hud_col = 0;
        hud_row = 0;
        selected_char = " ";
        selected_row = 5'b00000;
        hud_pixel = 1'b0;
        hud_region = 1'b0;
        hud_border = 1'b0;

        if (enable && de && pixel_x >= HUD_X && pixel_x < HUD_X + HUD_W &&
            line_y >= HUD_Y && line_y < HUD_Y + HUD_H) begin
            hud_region = 1'b1;
            hud_border = pixel_x == HUD_X || pixel_x == HUD_X + HUD_W - 1 ||
                         line_y == HUD_Y || line_y == HUD_Y + HUD_H - 1;
        end

        if (enable && de && pixel_x >= HUD_TEXT_X &&
            pixel_x < HUD_TEXT_X + HUD_CHARS * CELL_W &&
            line_y >= HUD_TEXT_Y && line_y < HUD_TEXT_Y + 14) begin
            hud_cell = hud_local_x >> 4;
            hud_col = (hud_local_x & 15) >> 1;
            hud_row = (line_y - HUD_TEXT_Y) >> 1;
            if (hud_col < 5 && hud_row < 7) begin
                selected_char = hud_char(hud_cell);
                selected_row = glyph_row(selected_char, hud_row[2:0]);
                hud_pixel = selected_row[4-hud_col];
            end
        end

    end

    always @* begin
        ticker_stream_x = pixel_x + scroll_pos - H_ACTIVE;
        ticker_cell = 0;
        ticker_col = 0;
        ticker_row = 0;
        ticker_address = 10'd0;
        ticker_col_value = 5'd0;
        ticker_visible = 1'b0;
        ticker_region = 1'b0;

        if (enable && de && line_y >= TICKER_Y && line_y < V_ACTIVE)
            ticker_region = 1'b1;

        if (enable && de && ticker_stream_x >= 0 &&
            ticker_stream_x < TICKER_WIDTH &&
            line_y >= TICKER_TEXT_Y && line_y < TICKER_TEXT_Y + 28) begin
            ticker_cell = ticker_stream_x >> 5;
            ticker_col = ticker_stream_x & 31;
            ticker_row = line_y - TICKER_TEXT_Y;
            if (ticker_col < 28 && ticker_row < 28) begin
                ticker_address = ticker_cell * 32 + ticker_row;
                ticker_col_value = ticker_col[4:0];
                ticker_visible = 1'b1;
            end
        end
    end

    always @* begin
        rgb_out = rgb_in_pipe;
        osd_active = 1'b0;
        if (ticker_region_pipe) begin
            rgb_out = darken_half(rgb_in_pipe);
            osd_active = 1'b1;
        end
        if (hud_region_pipe) begin
            rgb_out = darken_half(rgb_in_pipe);
            osd_active = 1'b1;
        end
        if (hud_border_pipe)
            rgb_out = 24'h35d0d8;
        if (hud_text_visible_pipe && hud_glyph_pipe[4-hud_col_pipe]) begin
            if (hud_cell_pipe == 8 || hud_cell_pipe == 21 ||
                hud_cell_pipe == 32)
                rgb_out = 24'h8aa8b8;
            else if (hud_cell_pipe >= 23 && hud_cell_pipe <= 30)
                rgb_out = resident_count_pipe == 3'd4 ? 24'h72e09a : 24'hffc857;
            else if (hud_cell_pipe >= 10 && hud_cell_pipe <= 18)
                rgb_out = loading_pipe ? 24'hffc857 : 24'hf4f7fb;
            else if (hud_cell_pipe <= 6)
                rgb_out = 24'h5fd7ff;
            else
                rgb_out = 24'hf4f7fb;
        end
        if (ticker_visible_pipe && ticker_bits[27-ticker_col_pipe])
            rgb_out = 24'hd9f7ff;
    end
endmodule

// Ticker glyphs: 32 cells of 32 rows, 28-pixel rows. The built-in text is
// the power-on content; the kitchen overwrites it through port B.
module ticker_font_rom (
    input wire clk, input wire [9:0] address, output wire [27:0] bits,
    input wire wclk, input wire we, input wire [9:0] waddr, input wire [27:0] wdata
);
`ifdef ORDER_UI_SIMULATION
reg [27:0] simulation_rom [0:1023];
reg [27:0] simulation_bits;
initial $readmemh("../../project/rtl/display/ticker_font.dath", simulation_rom);
always @(posedge clk) simulation_bits <= simulation_rom[address];
always @(posedge wclk) if (we) simulation_rom[waddr] <= wdata;
assign bits = simulation_bits;
`else
EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(28), .ADDR_WIDTH_A(10), .DATA_DEPTH_A(1024),
    .DATA_WIDTH_B(28), .ADDR_WIDTH_B(10), .DATA_DEPTH_B(1024),
    .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
    .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"), .IMPLEMENT("32K"),
    .DEBUGGABLE("NO"), .PACKABLE("NO"),
    .INIT_FILE("ticker_font.mif"), .FILL_ALL("NONE")
) u_ticker_bram (
    .dia(28'd0), .dib(wdata), .addra(address), .addrb(waddr),
    .cea(1'b1), .ceb(1'b1), .ocea(1'b0), .oceb(1'b0),
    .clka(clk), .clkb(wclk), .wea(1'b0), .web(we),
    .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
    .doa(bits), .dob()
);
`endif
endmodule

module promax_audio_waveform #(
    parameter integer WAVE_X = 0,
    parameter integer WAVE_Y = 616,
    parameter integer WAVE_WIDTH = 1280,
    parameter integer WAVE_HEIGHT = 64,
    parameter integer SAMPLE_COUNT = 64,
    parameter integer DECIMATE = 12
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vs,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire        enable,
    input  wire        pcm_tap_valid,
    input  wire signed [15:0] pcm_tap_left,
    input  wire [23:0] accent_rgb,          // waveform colour (switch mode 110)
    input  wire        progress_on,         // auto-play running: show the bar
    input  wire [10:0] progress_px,         // bar length, 0..WAVE_WIDTH
    output reg         vs_out,
    output reg         de_out,
    output reg  [23:0] rgb_out,
    output reg         waveform_active
);
    localparam integer SAMPLE_SPACING = WAVE_WIDTH / SAMPLE_COUNT;
    localparam integer CENTER_Y = WAVE_Y + WAVE_HEIGHT / 2;
    localparam integer PEAK_X = WAVE_X + WAVE_WIDTH - 24;

    reg [10:0] pixel_x;
    reg [9:0] line_y;
    reg de_q;
    reg vs_q;
    wire frame_start = !vs_q && vs;

    reg signed [7:0] sample_bank0 [0:SAMPLE_COUNT-1];
    reg signed [7:0] sample_bank1 [0:SAMPLE_COUNT-1];
    reg write_bank;
    reg display_bank;
    reg display_valid;
    reg [6:0] capture_count;
    reg [7:0] decimate_count;
    reg [7:0] peak_bank0;
    reg [7:0] peak_bank1;
    reg [7:0] display_peak;
    reg [6:0] render_sample_index;
    reg [10:0] sample_span_count;
    reg signed [7:0] selected_sample_stage;
    reg [10:0] pixel_x_stage;
    reg [9:0] line_y_stage;
    reg [23:0] rgb_stage;
    reg [7:0] display_peak_stage;
    reg [10:0] progress_pixel_count_stage;
    reg progress_on_stage;
    reg display_valid_stage;
    reg enable_stage;
    reg vs_stage;
    reg de_stage;
    wire [7:0] sample_abs = pcm_tap_left[15] ?
                            (~pcm_tap_left[15:8] + 1'b1) : pcm_tap_left[15:8];

    integer sample_value;
    integer sample_y;
    integer peak_height;
    reg signed [7:0] selected_sample;
    reg panel_pixel;
    reg border_pixel;
    reg wave_pixel;
    reg axis_pixel;
    reg guide_pixel;
    reg peak_pixel;
    reg peak_track_pixel;
    reg progress_pixel;
    reg progress_track_pixel;

    function [23:0] darken_half_waveform;
        input [23:0] color;
        begin
            darken_half_waveform = {1'b0, color[23:17],
                                    1'b0, color[15:9],
                                    1'b0, color[7:1]};
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_x <= 11'd0;
            line_y <= 10'd0;
            de_q <= 1'b0;
            vs_q <= 1'b0;
            write_bank <= 1'b0;
            display_bank <= 1'b1;
            display_valid <= 1'b0;
            capture_count <= 7'd0;
            decimate_count <= 8'd0;
            peak_bank0 <= 8'd0;
            peak_bank1 <= 8'd0;
            display_peak <= 8'd0;
            render_sample_index <= 7'd0;
            sample_span_count <= 11'd0;
            selected_sample_stage <= 8'sd0;
            pixel_x_stage <= 11'd0;
            line_y_stage <= 10'd0;
            rgb_stage <= 24'd0;
            display_peak_stage <= 8'd0;
            progress_pixel_count_stage <= 11'd0;
            progress_on_stage <= 1'b0;
            display_valid_stage <= 1'b0;
            enable_stage <= 1'b0;
            vs_stage <= 1'b0;
            de_stage <= 1'b0;
        end else begin
            de_q <= de;
            vs_q <= vs;

            if (!de)
                pixel_x <= 11'd0;
            else if (!de_q)
                pixel_x <= 11'd1;
            else
                pixel_x <= pixel_x + 1'b1;

            if (vs)
                line_y <= 10'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;

            if (!de || pixel_x < WAVE_X) begin
                render_sample_index <= 7'd0;
                sample_span_count <= 11'd0;
            end else if (pixel_x < WAVE_X + WAVE_WIDTH - 1) begin
                if (sample_span_count == SAMPLE_SPACING - 1) begin
                    sample_span_count <= 11'd0;
                    render_sample_index <= render_sample_index + 1'b1;
                end else begin
                    sample_span_count <= sample_span_count + 1'b1;
                end
            end

            if (!enable) begin
                write_bank <= 1'b0;
                display_bank <= 1'b1;
                display_valid <= 1'b0;
                capture_count <= 7'd0;
                decimate_count <= 8'd0;
                peak_bank0 <= 8'd0;
                peak_bank1 <= 8'd0;
                display_peak <= 8'd0;
            end else if (frame_start) begin
                if (capture_count == SAMPLE_COUNT) begin
                    display_bank <= write_bank;
                    display_valid <= 1'b1;
                    display_peak <= write_bank ? peak_bank1 : peak_bank0;
                    write_bank <= ~write_bank;
                end
                capture_count <= 7'd0;
                decimate_count <= 8'd0;
                if (write_bank)
                    peak_bank0 <= 8'd0;
                else
                    peak_bank1 <= 8'd0;
            end else if (pcm_tap_valid && capture_count < SAMPLE_COUNT) begin
                if (decimate_count == 0) begin
                    if (write_bank)
                        sample_bank1[capture_count] <= pcm_tap_left[15:8];
                    else
                        sample_bank0[capture_count] <= pcm_tap_left[15:8];
                    capture_count <= capture_count + 1'b1;
                    decimate_count <= DECIMATE - 1;
                    if (write_bank) begin
                        if (sample_abs > peak_bank1)
                            peak_bank1 <= sample_abs;
                    end else begin
                        if (sample_abs > peak_bank0)
                            peak_bank0 <= sample_abs;
                    end
                end else begin
                    decimate_count <= decimate_count - 1'b1;
                end
            end

            selected_sample_stage <= display_bank ?
                                     sample_bank1[render_sample_index] :
                                     sample_bank0[render_sample_index];
            pixel_x_stage <= pixel_x;
            line_y_stage <= line_y;
            rgb_stage <= rgb_in;
            display_peak_stage <= display_peak;
            progress_pixel_count_stage <= progress_px;
            progress_on_stage <= progress_on;
            display_valid_stage <= display_valid;
            enable_stage <= enable;
            vs_stage <= vs;
            de_stage <= de;
        end
    end

    always @* begin
        selected_sample = 8'sd0;
        sample_value = 0;
        sample_y = CENTER_Y;
        peak_height = display_peak_stage >> 2;
        panel_pixel = 1'b0;
        border_pixel = 1'b0;
        wave_pixel = 1'b0;
        axis_pixel = 1'b0;
        guide_pixel = 1'b0;
        peak_pixel = 1'b0;
        peak_track_pixel = 1'b0;
        progress_pixel = 1'b0;
        progress_track_pixel = 1'b0;

        if (enable_stage && de_stage && pixel_x_stage >= WAVE_X &&
            pixel_x_stage < WAVE_X + WAVE_WIDTH &&
            line_y_stage >= WAVE_Y && line_y_stage < WAVE_Y + WAVE_HEIGHT) begin
            axis_pixel = line_y_stage == CENTER_Y;
            guide_pixel = line_y_stage == WAVE_Y + WAVE_HEIGHT / 4 ||
                          line_y_stage == WAVE_Y + (WAVE_HEIGHT * 3) / 4;
            if (display_valid_stage) begin
                selected_sample = selected_sample_stage;
                sample_value = $signed(selected_sample);
                sample_y = CENTER_Y - sample_value / 4;
                wave_pixel = line_y_stage >= sample_y - 1 && line_y_stage <= sample_y + 1;
            end
        end

        peak_height = (display_peak_stage >> 2) + (display_peak_stage >> 3);
        if (enable_stage && de_stage && pixel_x_stage >= PEAK_X &&
            pixel_x_stage < PEAK_X + 20 &&
            line_y_stage >= WAVE_Y && line_y_stage < WAVE_Y + WAVE_HEIGHT) begin
            if (pixel_x_stage >= PEAK_X + 4 &&
                pixel_x_stage < PEAK_X + 16 &&
                line_y_stage >= WAVE_Y + WAVE_HEIGHT - peak_height &&
                line_y_stage < WAVE_Y + WAVE_HEIGHT - 4)
                peak_pixel = 1'b1;
        end

        if (enable_stage && progress_on_stage && de_stage && pixel_x_stage >= WAVE_X &&
            pixel_x_stage < WAVE_X + WAVE_WIDTH &&
            line_y_stage >= WAVE_Y + WAVE_HEIGHT + 4 &&
            line_y_stage < WAVE_Y + WAVE_HEIGHT + 8) begin
            progress_track_pixel = 1'b1;
            if (pixel_x_stage < WAVE_X + progress_pixel_count_stage)
                progress_pixel = 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_out <= 1'b0;
            de_out <= 1'b0;
            rgb_out <= 24'd0;
            waveform_active <= 1'b0;
        end else begin
            vs_out <= vs_stage;
            de_out <= de_stage;
            waveform_active <= wave_pixel || peak_pixel || progress_pixel;
            if (peak_pixel || wave_pixel || progress_pixel)
                rgb_out <= accent_rgb;
            else
                rgb_out <= rgb_stage;
        end
    end
endmodule

module auto_elapsed_timer #(
    parameter integer CLOCK_HZ = 74_242_424
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       auto_enabled,
    input  wire [2:0] image_index,
    input  wire [3:0] max_seconds,      // the auto-play interval, 5..15
    output reg  [3:0] seconds_digit,    // 0..15 (binary)
    output reg  [3:0] tenths_digit,
    output reg  [3:0] hundredths_digit,
    // Elapsed part of the interval as a bar length of 0..1280 pixels.
    output wire [10:0] progress_px
);
    localparam integer TICKS_PER_SECOND = 100;

    // The bar grows by 1280 / (seconds * 100) pixels each hundredth (Q16).
    reg [27:0] progress_acc;          // room for an interval lengthened mid-way
    reg [17:0] progress_step;
    always @(posedge clk) begin
        case (max_seconds)
            4'd5:  progress_step <= 18'd167772;
            4'd6:  progress_step <= 18'd139810;
            4'd7:  progress_step <= 18'd119837;
            4'd8:  progress_step <= 18'd104858;
            4'd9:  progress_step <= 18'd93207;
            4'd10: progress_step <= 18'd83886;
            4'd11: progress_step <= 18'd76260;
            4'd12: progress_step <= 18'd69905;
            4'd13: progress_step <= 18'd64528;
            4'd14: progress_step <= 18'd59919;
            default: progress_step <= 18'd55924;
        endcase
    end
    assign progress_px = progress_acc[27:16] > 12'd1280 ? 11'd1280 : progress_acc[26:16];

    reg [31:0] tick_accumulator;
    reg [2:0] image_seen;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_accumulator <= 32'd0;
            image_seen <= 3'd0;
            seconds_digit <= 4'd0;
            tenths_digit <= 4'd0;
            hundredths_digit <= 4'd0;
            progress_acc <= 28'd0;
        end else if (!auto_enabled || image_index != image_seen) begin
            tick_accumulator <= 32'd0;
            image_seen <= image_index;
            seconds_digit <= 4'd0;
            tenths_digit <= 4'd0;
            hundredths_digit <= 4'd0;
            progress_acc <= 28'd0;
        end else if (tick_accumulator >= CLOCK_HZ - TICKS_PER_SECOND) begin
            tick_accumulator <= tick_accumulator + TICKS_PER_SECOND - CLOCK_HZ;
            if (seconds_digit >= max_seconds) begin
                progress_acc <= {12'd1280, 16'd0};
            end else begin
                progress_acc <= progress_acc + progress_step;
                if (hundredths_digit == 4'd9) begin
                    hundredths_digit <= 4'd0;
                    if (tenths_digit == 4'd9) begin
                        tenths_digit <= 4'd0;
                        seconds_digit <= seconds_digit + 1'b1;
                    end else begin
                        tenths_digit <= tenths_digit + 1'b1;
                    end
                end else begin
                    hundredths_digit <= hundredths_digit + 1'b1;
                end
            end
        end else begin
            tick_accumulator <= tick_accumulator + TICKS_PER_SECOND;
        end
    end
endmodule
