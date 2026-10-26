`timescale 1ns/1ps

module order_detail_ui_720p (
    input wire clk, input wire rst_n, input wire vs, input wire de,
    input wire [23:0] rgb_in, input wire [1:0] menu_state,
    input wire [1:0] dish_index, input wire [1:0] category_index,
    input wire photo_ready,
    input wire [3:0] cart_qty0, input wire [3:0] cart_qty1,
    input wire [3:0] cart_qty2, input wire [3:0] cart_qty3,
    input wire [5:0] cart_total_count, input wire [9:0] cart_total_price,
    input wire [3:0] cart_order0, input wire [3:0] cart_order1,
    input wire [3:0] cart_order2, input wire [3:0] cart_order3,
    input wire [2:0] cart_distinct_count,
    input wire parameter_popup_active, input wire [2:0] parameter_popup_kind,
    input wire [3:0] parameter_popup_ones, input wire [3:0] parameter_popup_tens,
    input wire [3:0] parameter_popup_hundreds,
    input wire [1:0] parameter_popup_digit_count,
    input wire [10:0] parameter_popup_fill_end,
    input wire [23:0] accent_rgb,                 // waveform colour, used by the bar
    // Dishes the kitchen marked sold out, bit {category, dish}; video clock.
    input wire [15:0] sold_out_mask,
    output wire vs_out, output wire de_out, output wire [23:0] rgb_out
);
localparam [1:0] MENU_CATEGORY = 2'd0;
localparam [1:0] MENU_DISH = 2'd1;
localparam [23:0] DEEP_GREEN = 24'h1a4d2e;
localparam [23:0] CREAM = 24'hf5f0e6;
localparam [23:0] CREAM_DEEP = 24'hebe5d7;
localparam [23:0] GOLD = 24'hc9a24e;
localparam [23:0] GOLD_LIGHT = 24'hd9b86a;
localparam [23:0] WHITE = 24'hffffff;
localparam [23:0] INK = 24'h1a1a1a;
localparam [23:0] MUTED = 24'h6f746f;
localparam [23:0] SOLD_OUT_RED = 24'hc0392b;

reg [10:0] pixel_x;
reg [9:0] pixel_y;
reg de_q, vs_q;
reg y_008_048, y_016_048, y_050_074, y_054_078;
reg y_116_156, y_174_198, y_208_240, y_256_288;
reg y_296_328, y_336_368, y_376_408, y_392_424;
reg y_416_448, y_450_482, y_480_512, y_596_628;
reg y_600_632, y_615_647, y_616_648, y_632_664, y_638_670;
reg y_496_540, y_502_534;
reg [23:0] base_rgb;
reg [23:0] text_rgb;
reg [5:0] hanzi_phrase;
reg [4:0] hanzi_character;
reg [4:0] hanzi_row;
reg [4:0] hanzi_col;
reg hanzi_active;
    wire [31:0] hanzi_bits;
reg [4:0] title_phrase;
reg [2:0] title_character;
reg [5:0] title_row;
reg [5:0] title_col;
reg title_active;
wire [39:0] title_bits;
reg [7:0] ascii_character;
reg [4:0] ascii_row;
reg [4:0] ascii_col;
reg ascii_active;
wire [15:0] ascii_bits;
reg [3:0] thumbnail_dish;
reg [4:0] thumbnail_row;
reg [4:0] thumbnail_col;
reg thumbnail_active;
wire [7:0] thumbnail_pixel;
reg [4:0] text_cell;
reg [10:0] text_offset;
reg cart_card_active;
reg [7:0] cart_local_x;
reg [3:0] cart_item;
reg [3:0] cart_quantity;
reg [23:0] base_stage;
reg [23:0] text_stage;
reg [5:0] hanzi_phrase_stage;
reg [4:0] hanzi_character_stage;
reg [4:0] hanzi_row_stage;
reg [4:0] hanzi_col_stage;
reg hanzi_active_stage;
reg [4:0] title_phrase_stage;
reg [2:0] title_character_stage;
reg [5:0] title_row_stage;
reg [5:0] title_col_stage;
reg title_active_stage;
reg [7:0] ascii_character_stage;
reg [4:0] ascii_row_stage;
reg [4:0] ascii_col_stage;
reg ascii_active_stage;
reg [3:0] thumbnail_dish_stage;
reg [4:0] thumbnail_row_stage;
reg [4:0] thumbnail_col_stage;
reg thumbnail_active_stage;
reg vs_stage, de_stage;
reg [23:0] base_font_stage;
reg [23:0] text_font_stage;
reg [4:0] hanzi_col_font_stage;
reg hanzi_active_font_stage;
reg [5:0] title_col_font_stage;
reg title_active_font_stage;
reg [4:0] ascii_col_font_stage;
reg ascii_active_font_stage;
reg thumbnail_active_font_stage;
reg vs_font_stage, de_font_stage;
reg [23:0] base_render_stage;
reg [23:0] text_render_stage;
reg [4:0] hanzi_col_render_stage;
reg hanzi_active_render_stage;
reg [5:0] title_col_render_stage;
reg title_active_render_stage;
reg [4:0] ascii_col_render_stage;
reg ascii_active_render_stage;
reg thumbnail_active_render_stage;
reg [31:0] hanzi_bits_render_stage;
reg [39:0] title_bits_render_stage;
reg [15:0] ascii_bits_render_stage;
reg [7:0] thumbnail_pixel_render_stage;
reg vs_render_stage, de_render_stage;
reg [23:0] rendered_rgb;
reg vs_pipe, de_pipe;
reg vs_output_stage /* synthesis dont_touch = true */;
reg de_output_stage /* synthesis dont_touch = true */;
reg [23:0] rgb_output_stage /* synthesis dont_touch = true */;
reg [9:0] price_binary_work;
reg [11:0] price_bcd_work;
reg [11:0] price_bcd;
reg [9:0] count_binary_work;
reg [7:0] count_bcd_work;
reg [7:0] count_bcd;
reg [9:0] bcd_price_source;
reg [5:0] bcd_count_source;
reg [3:0] bcd_step;
reg [4:0] popup_alpha;
reg [2:0] popup_kind_latched;
reg [3:0] popup_ones_latched;
reg [3:0] popup_tens_latched;
reg [3:0] popup_hundreds_latched;
reg [1:0] popup_digit_count_latched;
reg [10:0] popup_fill_end_latched;
// Colour number 1..10 of the colour popup (its value, one or two digits).
reg [10:0] popup_name_offset;
wire [3:0] popup_color_index = (popup_tens_latched != 4'd0) ? 4'd10 : popup_ones_latched;
reg [23:0] popup_base_rgb;
reg [23:0] popup_text_rgb;
reg [5:0] popup_hanzi_phrase;
reg [4:0] popup_hanzi_character;
reg [4:0] popup_hanzi_row;
reg [4:0] popup_hanzi_col;
reg popup_hanzi_active;
reg [7:0] popup_ascii_character;
reg [4:0] popup_ascii_row;
reg [4:0] popup_ascii_col;
reg popup_ascii_active;
wire [11:0] price_bcd_adjusted;
wire [7:0] count_bcd_adjusted;
wire popup_pixel_visible = popup_alpha >= 5'd13 ? 1'b1 :
                           popup_alpha >= 5'd9 ? ~(pixel_x[0] & pixel_y[0]) :
                           popup_alpha >= 5'd5 ? (pixel_x[0] == pixel_y[0]) :
                           popup_alpha != 0 ? ~(pixel_x[0] | pixel_y[0]) : 1'b0;
wire popup_overlay_active = de && menu_state == MENU_CATEGORY && popup_pixel_visible;

assign vs_out = vs_output_stage;
assign de_out = de_output_stage;
assign rgb_out = rgb_output_stage;

wire [3:0] item_index = {category_index, dish_index};
wire sold_out_now = sold_out_mask[item_index];
// Popup titles are centred: 2 characters (亮度, 音量, 音频), 3 (对比度),
// 4 (字幕速度, 轮播间隔, 波普颜色).
wire [10:0] popup_title_x = (popup_kind_latched == 3'd1) ? 11'd592 :
                            (popup_kind_latched >= 3'd3 && popup_kind_latched <= 3'd5) ?
                            11'd576 : 11'd608;

function [2:0] title_length;
input [3:0] index;
begin
    case (index)
        4'h0, 4'h1, 4'h2, 4'h8: title_length = 3'd5;
        4'h9: title_length = 3'd3;
        4'ha, 4'hb: title_length = 3'd2;
        default: title_length = 3'd4;
    endcase
end
endfunction

function [3:0] price_tens;
input [3:0] index;
begin
    case (index)
        4'h0, 4'h2: price_tens = 4'd1;
        4'h1, 4'h3: price_tens = 4'd1;
        4'h4, 4'h5, 4'h6: price_tens = 4'd1;
        4'hc, 4'hd, 4'he: price_tens = 4'd2;
        4'hf: price_tens = 4'd3;
        default: price_tens = 4'd0;
    endcase
end
endfunction

function [3:0] price_ones;
input [3:0] index;
begin
    case (index)
        4'h0: price_ones = 4'd8;
        4'h1: price_ones = 4'd5;
        4'h2: price_ones = 4'd7;
        4'h3: price_ones = 4'd6;
        4'h4: price_ones = 4'd2;
        4'h5: price_ones = 4'd4;
        4'h6: price_ones = 4'd0;
        4'h7: price_ones = 4'd9;
        4'h8: price_ones = 4'd8;
        4'h9: price_ones = 4'd7;
        4'ha: price_ones = 4'd6;
        4'hb: price_ones = 4'd8;
        4'hc: price_ones = 4'd5;
        4'hd: price_ones = 4'd3;
        4'he: price_ones = 4'd0;
        default: price_ones = 4'd8;
    endcase
end
endfunction

function [11:0] portion_weight_bcd;
input [3:0] index;
begin
    case (index)
        4'h0: portion_weight_bcd = 12'h550;
        4'h1: portion_weight_bcd = 12'h450;
        4'h2: portion_weight_bcd = 12'h500;
        4'h3: portion_weight_bcd = 12'h480;
        4'h4, 4'h5: portion_weight_bcd = 12'h220;
        4'h6, 4'h7: portion_weight_bcd = 12'h180;
        4'h8, 4'h9, 4'ha, 4'hb: portion_weight_bcd = 12'h350;
        4'hc, 4'hd, 4'he: portion_weight_bcd = 12'h700;
        default: portion_weight_bcd = 12'h900;
    endcase
end
endfunction

function [3:0] weight_digit;
input [3:0] index;
input [1:0] position;
reg [11:0] weight;
begin
    weight = portion_weight_bcd(index);
    case (position)
        2'd0: weight_digit = weight[11:8];
        2'd1: weight_digit = weight[7:4];
        default: weight_digit = weight[3:0];
    endcase
end
endfunction

function [23:0] category_panel_color;
input [1:0] index;
begin
    case (index)
        2'd1: category_panel_color = 24'hf5a34c;
        2'd2: category_panel_color = 24'h48a9c5;
        default: category_panel_color = 24'h53a381;
    endcase
end
endfunction

function [4:0] flavor_character;
input [3:0] index;
begin
    case (index)
        4'h1, 4'h3, 4'h6, 4'h7, 4'h8, 4'h9, 4'ha, 4'hb, 4'he:
            flavor_character = 5'd2;
        default: flavor_character = 5'd0;
    endcase
end
endfunction

function [4:0] allergen_character;
input [3:0] index;
begin
    case (index)
        4'h1, 4'h6: allergen_character = 5'd10;
        4'h3, 4'h5, 4'ha, 4'he: allergen_character = 5'd5;
        4'h4, 4'h7: allergen_character = 5'd8;
        4'h8, 4'h9, 4'hb: allergen_character = 5'd4;
        default: allergen_character = 5'd5;
    endcase
end
endfunction

function [2:0] allergen_length;
input [3:0] index;
begin
    case (index)
        4'h8, 4'h9, 4'hb: allergen_length = 3'd1;
        4'h1, 4'h3, 4'h4, 4'h5, 4'h6, 4'h7, 4'ha, 4'he:
            allergen_length = 3'd2;
        default: allergen_length = 3'd5;
    endcase
end
endfunction

function [4:0] cook_character;
input [3:0] index;
begin
    case (index)
        4'h0: cook_character = 5'd2;
        4'h2: cook_character = 5'd4;
        4'h3: cook_character = 5'd6;
        4'h4, 4'h5, 4'h6, 4'h7: cook_character = 5'd8;
        4'h8: cook_character = 5'd22;
        4'hc, 4'hd, 4'he, 4'hf: cook_character = 5'd10;
        default: cook_character = 5'd0;
    endcase
end
endfunction

function [4:0] taste_character;
input [3:0] index;
begin
    case (index)
        4'h1, 4'h6, 4'h9, 4'hb: taste_character = 5'd14;
        4'h2, 4'hd: taste_character = 5'd16;
        4'h3, 4'h7, 4'h8, 4'he: taste_character = 5'd18;
        default: taste_character = 5'd12;
    endcase
end
endfunction

function [2:0] cell48_index;
input [8:0] offset;
begin
    if (offset < 48) cell48_index = 3'd0;
    else if (offset < 96) cell48_index = 3'd1;
    else if (offset < 144) cell48_index = 3'd2;
    else if (offset < 192) cell48_index = 3'd3;
    else cell48_index = 3'd4;
end
endfunction

function [5:0] cell48_col;
input [8:0] offset;
begin
    if (offset < 48) cell48_col = offset[5:0];
    else if (offset < 96) cell48_col = offset - 48;
    else if (offset < 144) cell48_col = offset - 96;
    else if (offset < 192) cell48_col = offset - 144;
    else cell48_col = offset - 192;
end
endfunction

function [4:0] cell24_index;
input [7:0] offset;
begin
    if (offset < 24) cell24_index = 5'd0;
    else if (offset < 48) cell24_index = 5'd1;
    else if (offset < 72) cell24_index = 5'd2;
    else if (offset < 96) cell24_index = 5'd3;
    else cell24_index = 5'd4;
end
endfunction

function [4:0] cell24_col;
input [7:0] offset;
begin
    if (offset < 24) cell24_col = offset[4:0];
    else if (offset < 48) cell24_col = offset - 24;
    else if (offset < 72) cell24_col = offset - 48;
    else if (offset < 96) cell24_col = offset - 72;
    else cell24_col = offset - 96;
end
endfunction

function [23:0] rgb332_to_rgb888;
input [7:0] pixel;
begin
    rgb332_to_rgb888 = {
        pixel[7:5], pixel[7:5], pixel[7:6],
        pixel[4:2], pixel[4:2], pixel[4:3],
        pixel[1:0], pixel[1:0], pixel[1:0], pixel[1:0]
    };
end
endfunction

function [11:0] bcd_add3_3;
input [11:0] value;
begin
    bcd_add3_3[3:0] = value[3:0] >= 5 ? value[3:0] + 4'd3 : value[3:0];
    bcd_add3_3[7:4] = value[7:4] >= 5 ? value[7:4] + 4'd3 : value[7:4];
    bcd_add3_3[11:8] = value[11:8] >= 5 ? value[11:8] + 4'd3 : value[11:8];
end
endfunction

function [7:0] bcd_add3_2;
input [7:0] value;
begin
    bcd_add3_2[3:0] = value[3:0] >= 5 ? value[3:0] + 4'd3 : value[3:0];
    bcd_add3_2[7:4] = value[7:4] >= 5 ? value[7:4] + 4'd3 : value[7:4];
end
endfunction

assign price_bcd_adjusted = bcd_add3_3(price_bcd_work);
assign count_bcd_adjusted = bcd_add3_2(count_bcd_work);

order_hanzi_font_rom u_order_hanzi_font_rom (
    .clk(clk), .phrase(hanzi_phrase_stage), .character(hanzi_character_stage),
    .row(hanzi_row_stage), .bits(hanzi_bits)
);

order_title_font_rom u_order_title_font_rom (
    .clk(clk), .phrase(title_phrase_stage), .character(title_character_stage),
    .row(title_row_stage), .bits(title_bits)
);

order_ascii_font_rom u_order_ascii_font_rom (
    .clk(clk), .character(ascii_character_stage), .row(ascii_row_stage),
    .bits(ascii_bits)
);

order_thumbnail_rom u_order_thumbnail_rom (
    .clk(clk), .dish(thumbnail_dish_stage[1:0]), .row(thumbnail_row_stage),
    .col(thumbnail_col_stage), .pixel(thumbnail_pixel)
);

always @* begin
    base_rgb = rgb_in;
    text_rgb = INK;
    hanzi_phrase = 6'd0;
    hanzi_character = 5'd0;
    hanzi_row = 5'd0;
    hanzi_col = 5'd0;
    hanzi_active = 1'b0;
    title_phrase = 5'd0;
    title_character = 3'd0;
    title_row = 6'd0;
    title_col = 6'd0;
    title_active = 1'b0;
    ascii_character = " ";
    ascii_row = 5'd0;
    ascii_col = 5'd0;
    ascii_active = 1'b0;
    thumbnail_dish = 4'd0;
    thumbnail_row = 5'd0;
    thumbnail_col = 5'd0;
    thumbnail_active = 1'b0;
    text_cell = 5'd0;
    text_offset = 11'd0;
    cart_card_active = 1'b0;
    cart_local_x = 8'd0;
    cart_item = 4'd0;
    cart_quantity = 4'd0;
    if (cart_distinct_count > 0 && pixel_x >= 11'd190 && pixel_x < 11'd380) begin
        cart_card_active = 1'b1;
        cart_local_x = pixel_x - 11'd190;
        cart_item = cart_order0;
        cart_quantity = cart_qty0;
    end else if (cart_distinct_count > 1 && pixel_x >= 11'd390 && pixel_x < 11'd580) begin
        cart_card_active = 1'b1;
        cart_local_x = pixel_x - 11'd390;
        cart_item = cart_order1;
        cart_quantity = cart_qty1;
    end else if (cart_distinct_count > 2 && pixel_x >= 11'd590 && pixel_x < 11'd780) begin
        cart_card_active = 1'b1;
        cart_local_x = pixel_x - 11'd590;
        cart_item = cart_order2;
        cart_quantity = cart_qty2;
    end else if (cart_distinct_count > 3 && pixel_x >= 11'd790 && pixel_x < 11'd980) begin
        cart_card_active = 1'b1;
        cart_local_x = pixel_x - 11'd790;
        cart_item = cart_order3;
        cart_quantity = cart_qty3;
    end

    if (de && menu_state == MENU_DISH) begin
        base_rgb = CREAM;
        if (pixel_y < 10'd80)
            base_rgb = DEEP_GREEN;
        else if (pixel_y < 10'd83)
            base_rgb = GOLD;
        else if (pixel_y >= 10'd565)
            base_rgb = CREAM_DEEP;
        else if (pixel_x >= 11'd48 && pixel_x < 11'd480 &&
                 pixel_y >= 10'd106 && pixel_y < 10'd438)
            base_rgb = WHITE;

        if (pixel_x >= 11'd64 && pixel_x < 11'd464 &&
            pixel_y >= 10'd130 && pixel_y < 10'd422)
            base_rgb = photo_ready ? rgb_in : 24'hd8ddd8;

        if ((pixel_x >= 11'd48 && pixel_x < 11'd480 &&
             (pixel_y >= 10'd106 && pixel_y < 10'd110 ||
              pixel_y >= 10'd434 && pixel_y < 10'd438)) ||
            (pixel_y >= 10'd106 && pixel_y < 10'd438 &&
             (pixel_x >= 11'd48 && pixel_x < 11'd52 ||
              pixel_x >= 11'd476 && pixel_x < 11'd480)))
            base_rgb = DEEP_GREEN;
        if (pixel_x >= 11'd516 && pixel_x < 11'd1240 &&
            pixel_y >= 10'd104 && pixel_y < 10'd540)
            base_rgb = WHITE;
        if (pixel_x >= 11'd516 && pixel_x < 11'd522 &&
            pixel_y >= 10'd104 && pixel_y < 10'd540)
            base_rgb = GOLD;
        if (pixel_x >= 11'd540 && pixel_x < 11'd1216 &&
            (pixel_y >= 10'd248 && pixel_y < 10'd250 ||
             pixel_y >= 10'd288 && pixel_y < 10'd290 ||
             pixel_y >= 10'd328 && pixel_y < 10'd330 ||
             pixel_y >= 10'd368 && pixel_y < 10'd370 ||
             pixel_y >= 10'd408 && pixel_y < 10'd410 ||
             pixel_y >= 10'd448 && pixel_y < 10'd450))
            base_rgb = 24'hd9ded8;
        if (pixel_x >= 11'd540 && pixel_x < 11'd1216 &&
            pixel_y >= 10'd468 && pixel_y < 10'd524)
            base_rgb = 24'hfffdf8;
        if (pixel_x >= 11'd540 && pixel_x < 11'd544 &&
            pixel_y >= 10'd468 && pixel_y < 10'd524)
            base_rgb = DEEP_GREEN;

        if (pixel_y >= 10'd565 && pixel_y < 10'd568)
            base_rgb = DEEP_GREEN;
        if (cart_distinct_count > 0 && pixel_x >= 11'd190 && pixel_x < 11'd380 &&
            pixel_y >= 10'd596 && pixel_y < 10'd666)
            base_rgb = WHITE;
        if (cart_distinct_count > 1 && pixel_x >= 11'd390 && pixel_x < 11'd580 &&
            pixel_y >= 10'd596 && pixel_y < 10'd666)
            base_rgb = WHITE;
        if (cart_distinct_count > 2 && pixel_x >= 11'd590 && pixel_x < 11'd780 &&
            pixel_y >= 10'd596 && pixel_y < 10'd666)
            base_rgb = WHITE;
        if (cart_distinct_count > 3 && pixel_x >= 11'd790 && pixel_x < 11'd980 &&
            pixel_y >= 10'd596 && pixel_y < 10'd666)
            base_rgb = WHITE;
        if ((cart_distinct_count > 0 && pixel_x >= 11'd190 && pixel_x < 11'd194) ||
            (cart_distinct_count > 1 && pixel_x >= 11'd390 && pixel_x < 11'd394) ||
            (cart_distinct_count > 2 && pixel_x >= 11'd590 && pixel_x < 11'd594) ||
            (cart_distinct_count > 3 && pixel_x >= 11'd790 && pixel_x < 11'd794)) begin
            if (pixel_y >= 10'd596 && pixel_y < 10'd666)
                base_rgb = GOLD;
        end
        if (pixel_x >= 11'd1008 && pixel_x < 11'd1011 &&
            pixel_y >= 10'd586 && pixel_y < 10'd684)
            base_rgb = DEEP_GREEN;
        // Sold-out badge with cut corners.
        if (sold_out_now && pixel_x >= 11'd64 && pixel_x < 11'd248 && y_496_540 &&
            !((pixel_x < 11'd67 || pixel_x >= 11'd245) &&
              (pixel_y < 10'd499 || pixel_y >= 10'd537)))
            base_rgb = SOLD_OUT_RED;

        if (sold_out_now && pixel_x >= 11'd76 && pixel_x < 11'd236 && y_502_534) begin
            hanzi_phrase = 6'd12;
            hanzi_character = (pixel_x - 11'd76) >> 5;
            hanzi_col = (pixel_x - 11'd76) & 11'd31;
            hanzi_row = pixel_y - 10'd502;
            hanzi_active = 1'b1;
            text_rgb = WHITE;
        end else if (pixel_x >= 11'd40 && pixel_x < 11'd168 && y_016_048) begin
            hanzi_phrase = 6'd0;
            hanzi_character = (pixel_x - 11'd40) >> 5;
            hanzi_col = (pixel_x - 11'd40) & 11'd31;
            hanzi_row = pixel_y - 10'd16;
            hanzi_active = 1'b1;
            text_rgb = CREAM;
        end else if (pixel_x >= 11'd540 && pixel_x < 11'd780 && y_116_156) begin
            text_offset = pixel_x - 11'd540;
            title_phrase = 5'd1 + item_index;
            title_character = cell48_index(text_offset[8:0]);
            title_col = cell48_col(text_offset[8:0]);
            title_row = pixel_y - 10'd116;
            title_active = title_col < 6'd40 &&
                           title_character < title_length(item_index);
            text_rgb = DEEP_GREEN;
        end else if (pixel_x >= 11'd1064 && pixel_x < 11'd1192 && y_016_048) begin
            hanzi_phrase = 6'd1;
            hanzi_character = {category_index, 2'b00} +
                              ((pixel_x - 11'd1064) >> 5);
            hanzi_col = (pixel_x - 11'd1064) & 11'd31;
            hanzi_row = pixel_y - 10'd16;
            hanzi_active = 1'b1;
            text_rgb = CREAM;
        end else if (pixel_x >= 11'd64 && pixel_x < 11'd456 && y_450_482) begin
            hanzi_phrase = 6'd32 + item_index;
            hanzi_character = (pixel_x - 11'd64) >> 5;
            hanzi_col = (pixel_x - 11'd64) & 11'd31;
            hanzi_row = pixel_y - 10'd450;
            hanzi_active = 1'b1;
            text_rgb = MUTED;
        end else if (pixel_x >= 11'd552 && pixel_x < 11'd616 && y_208_240) begin
            hanzi_phrase = 6'd2;
            hanzi_character = (pixel_x - 11'd552) >> 5;
            hanzi_col = (pixel_x - 11'd552) & 11'd31;
            hanzi_row = pixel_y - 10'd208;
            hanzi_active = 1'b1;
            text_rgb = DEEP_GREEN;
        end else if (pixel_x >= 11'd704 && pixel_x < 11'd768 && y_208_240) begin
            hanzi_phrase = 6'd5;
            hanzi_character = flavor_character(item_index) +
                              ((pixel_x - 11'd704) >> 5);
            hanzi_col = (pixel_x - 11'd704) & 11'd31;
            hanzi_row = pixel_y - 10'd208;
            hanzi_active = 1'b1;
        end else if (pixel_x >= 11'd552 && pixel_x < 11'd648 && y_256_288) begin
            hanzi_phrase = 6'd2;
            hanzi_character = 5'd2 + ((pixel_x - 11'd552) >> 5);
            hanzi_col = (pixel_x - 11'd552) & 11'd31;
            hanzi_row = pixel_y - 10'd256;
            hanzi_active = 1'b1;
            text_rgb = DEEP_GREEN;
        end else if (pixel_x >= 11'd704 && pixel_x < 11'd864 && y_256_288) begin
            hanzi_phrase = 6'd5;
            hanzi_character = allergen_character(item_index) +
                              ((pixel_x - 11'd704) >> 5);
            hanzi_col = (pixel_x - 11'd704) & 11'd31;
            hanzi_row = pixel_y - 10'd256;
            hanzi_active = ((pixel_x - 11'd704) >> 5) < allergen_length(item_index);
        end else if (pixel_x >= 11'd552 && pixel_x < 11'd648 && y_296_328) begin
            hanzi_phrase = 6'd2;
            hanzi_character = 5'd5 + ((pixel_x - 11'd552) >> 5);
            hanzi_col = (pixel_x - 11'd552) & 11'd31;
            hanzi_row = pixel_y - 10'd296;
            hanzi_active = 1'b1;
            text_rgb = DEEP_GREEN;
        end else if (pixel_x >= 11'd704 && pixel_x < 11'd992 && y_296_328) begin
            hanzi_phrase = 6'd48 + item_index;
            hanzi_character = (pixel_x - 11'd704) >> 5;
            hanzi_col = (pixel_x - 11'd704) & 11'd31;
            hanzi_row = pixel_y - 10'd296;
            hanzi_active = 1'b1;
        end else if (pixel_x >= 11'd552 && pixel_x < 11'd680 && y_336_368) begin
            hanzi_phrase = 6'd2;
            hanzi_character = 5'd8 + ((pixel_x - 11'd552) >> 5);
            hanzi_col = (pixel_x - 11'd552) & 11'd31;
            hanzi_row = pixel_y - 10'd336;
            hanzi_active = 1'b1;
            text_rgb = DEEP_GREEN;
        end else if (pixel_x >= 11'd704 && pixel_x < 11'd768 && y_336_368) begin
            hanzi_phrase = 6'd6;
            hanzi_character = cook_character(item_index) +
                              ((pixel_x - 11'd704) >> 5);
            hanzi_col = (pixel_x - 11'd704) & 11'd31;
            hanzi_row = pixel_y - 10'd336;
            hanzi_active = 1'b1;
        end else if (pixel_x >= 11'd552 && pixel_x < 11'd680 && y_376_408) begin
            hanzi_phrase = 6'd2;
            hanzi_character = 5'd12 + ((pixel_x - 11'd552) >> 5);
            hanzi_col = (pixel_x - 11'd552) & 11'd31;
            hanzi_row = pixel_y - 10'd376;
            hanzi_active = 1'b1;
            text_rgb = DEEP_GREEN;
        end else if (pixel_x >= 11'd704 && pixel_x < 11'd768 && y_376_408) begin
            hanzi_phrase = 6'd6;
            hanzi_character = taste_character(item_index) +
                              ((pixel_x - 11'd704) >> 5);
            hanzi_col = (pixel_x - 11'd704) & 11'd31;
            hanzi_row = pixel_y - 10'd376;
            hanzi_active = 1'b1;
        end else if (pixel_x >= 11'd552 && pixel_x < 11'd680 && y_416_448) begin
            hanzi_phrase = 6'd2;
            hanzi_character = 5'd16 + ((pixel_x - 11'd552) >> 5);
            hanzi_col = (pixel_x - 11'd552) & 11'd31;
            hanzi_row = pixel_y - 10'd416;
            hanzi_active = 1'b1;
            text_rgb = DEEP_GREEN;
        end else if (pixel_x >= 11'd704 && pixel_x < 11'd736 && y_416_448) begin
            hanzi_phrase = 6'd4;
            hanzi_character = 5'd1;
            hanzi_col = (pixel_x - 11'd704) & 11'd31;
            hanzi_row = pixel_y - 10'd416;
            hanzi_active = 1'b1;
        end else if (pixel_x >= 11'd736 && pixel_x < 11'd864 && y_416_448) begin
            hanzi_phrase = 6'd4;
            hanzi_character = ((pixel_x - 11'd736) >> 5) < 3 ?
                              5'd2 + weight_digit(item_index,
                                  (pixel_x - 11'd736) >> 5) : 5'd12;
            hanzi_col = (pixel_x - 11'd736) & 11'd31;
            hanzi_row = pixel_y - 10'd416;
            hanzi_active = 1'b1;
        end else if (pixel_x >= 11'd880 && pixel_x < 11'd976 && y_416_448) begin
            hanzi_phrase = 6'd7;
            hanzi_character = (pixel_x - 11'd880) >> 5;
            hanzi_col = (pixel_x - 11'd880) & 11'd31;
            hanzi_row = pixel_y - 10'd416;
            hanzi_active = 1'b1;
        end else if (pixel_x >= 11'd556 && pixel_x < 11'd940 && y_480_512) begin
            hanzi_phrase = 6'd32 + item_index;
            hanzi_character = 5'd20 + ((pixel_x - 11'd556) >> 5);
            hanzi_col = (pixel_x - 11'd556) & 11'd31;
            hanzi_row = pixel_y - 10'd480;
            hanzi_active = 1'b1;
        end else if (pixel_x >= 11'd40 && pixel_x < 11'd168 && y_616_648) begin
            hanzi_phrase = 6'd3;
            hanzi_character = (pixel_x - 11'd40) >> 5;
            hanzi_col = (pixel_x - 11'd40) & 11'd31;
            hanzi_row = pixel_y - 10'd616;
            hanzi_active = 1'b1;
            text_rgb = DEEP_GREEN;
        end else if (cart_total_count == 0 && pixel_x >= 11'd198 && pixel_x < 11'd454 &&
                     y_616_648) begin
            hanzi_phrase = 6'd3;
            hanzi_character = 5'd4 + ((pixel_x - 11'd198) >> 5);
            hanzi_col = (pixel_x - 11'd198) & 11'd31;
            hanzi_row = pixel_y - 10'd616;
            hanzi_active = 1'b1;
            text_rgb = MUTED;
        end else if (cart_distinct_count > 0 && pixel_x >= 11'd238 && pixel_x < 11'd358 &&
                     y_600_632) begin
            text_offset = pixel_x - 11'd238;
            hanzi_phrase = 6'd16 + cart_order0;
            hanzi_character = text_offset[7:5];
            hanzi_col = text_offset[4:0];
            hanzi_row = pixel_y - 10'd600;
            hanzi_active = 1'b1;
        end else if (cart_distinct_count > 1 && pixel_x >= 11'd438 && pixel_x < 11'd558 &&
                     y_600_632) begin
            text_offset = pixel_x - 11'd438;
            hanzi_phrase = 6'd16 + cart_order1;
            hanzi_character = text_offset[7:5];
            hanzi_col = text_offset[4:0];
            hanzi_row = pixel_y - 10'd600;
            hanzi_active = 1'b1;
        end else if (cart_distinct_count > 2 && pixel_x >= 11'd638 && pixel_x < 11'd758 &&
                     y_600_632) begin
            text_offset = pixel_x - 11'd638;
            hanzi_phrase = 6'd16 + cart_order2;
            hanzi_character = text_offset[7:5];
            hanzi_col = text_offset[4:0];
            hanzi_row = pixel_y - 10'd600;
            hanzi_active = 1'b1;
        end else if (cart_distinct_count > 3 && pixel_x >= 11'd838 && pixel_x < 11'd958 &&
                     y_600_632) begin
            text_offset = pixel_x - 11'd838;
            hanzi_phrase = 6'd16 + cart_order3;
            hanzi_character = text_offset[7:5];
            hanzi_col = text_offset[4:0];
            hanzi_row = pixel_y - 10'd600;
            hanzi_active = 1'b1;
        end else if (cart_card_active && cart_local_x >= 8'd108 &&
                     cart_local_x < 8'd140 && y_632_664) begin
            hanzi_phrase = 6'd4;
            hanzi_character = 5'd0;
            hanzi_col = cart_local_x - 8'd108;
            hanzi_row = pixel_y - 10'd632;
            hanzi_active = 1'b1;
        end else if (pixel_x >= (cart_total_count >= 10 ? 11'd1080 : 11'd1096) &&
                     pixel_x < (cart_total_count >= 10 ? 11'd1144 : 11'd1160) &&
                     y_596_628) begin
            hanzi_phrase = 6'd3;
            hanzi_character = 5'd12 +
                              ((pixel_x - (cart_total_count >= 10 ? 11'd1080 : 11'd1096)) >> 5);
            hanzi_col = (pixel_x - (cart_total_count >= 10 ? 11'd1080 : 11'd1096)) & 11'd31;
            hanzi_row = pixel_y - 10'd596;
            hanzi_active = 1'b1;
        end else if (cart_total_count >= 10 &&
                     pixel_x >= 11'd1160 && pixel_x < 11'd1224 &&
                     y_596_628) begin
            hanzi_phrase = 6'd4;
            hanzi_character = pixel_x < 11'd1192 ? 5'd2 + count_bcd[7:4] :
                                                   5'd2 + count_bcd[3:0];
            hanzi_col = (pixel_x - 11'd1160) & 11'd31;
            hanzi_row = pixel_y - 10'd596;
            hanzi_active = 1'b1;
        end else if (cart_total_count < 10 &&
                     pixel_x >= 11'd1176 && pixel_x < 11'd1208 &&
                     y_596_628) begin
            hanzi_phrase = 6'd4;
            hanzi_character = 5'd2 + count_bcd[3:0];
            hanzi_col = pixel_x - 11'd1176;
            hanzi_row = pixel_y - 10'd596;
            hanzi_active = 1'b1;
        end else if (pixel_x >= (cart_total_price >= 100 ? 11'd1072 :
                                cart_total_price >= 10 ? 11'd1088 : 11'd1104) &&
                     pixel_x < (cart_total_price >= 100 ? 11'd1104 :
                               cart_total_price >= 10 ? 11'd1120 : 11'd1136) &&
                     y_638_670) begin
            hanzi_phrase = 6'd3;
            hanzi_character = 5'd10;
            hanzi_col = pixel_x - (cart_total_price >= 100 ? 11'd1072 :
                                   cart_total_price >= 10 ? 11'd1088 : 11'd1104);
            hanzi_row = pixel_y - 10'd638;
            hanzi_active = 1'b1;
        end else if (price_bcd[11:8] != 0 &&
                     pixel_x >= 11'd1104 && pixel_x < 11'd1200 &&
                     y_638_670) begin
            hanzi_phrase = 6'd4;
            hanzi_character = pixel_x < 11'd1136 ? 5'd2 + price_bcd[11:8] :
                              pixel_x < 11'd1168 ? 5'd2 + price_bcd[7:4] :
                                                   5'd2 + price_bcd[3:0];
            hanzi_col = (pixel_x - 11'd1104) & 11'd31;
            hanzi_row = pixel_y - 10'd638;
            hanzi_active = 1'b1;
            text_rgb = GOLD;
        end else if (price_bcd[11:8] == 0 && price_bcd[7:4] != 0 &&
                     pixel_x >= 11'd1120 && pixel_x < 11'd1184 &&
                     y_638_670) begin
            hanzi_phrase = 6'd4;
            hanzi_character = pixel_x < 11'd1152 ? 5'd2 + price_bcd[7:4] :
                                                   5'd2 + price_bcd[3:0];
            hanzi_col = (pixel_x - 11'd1120) & 11'd31;
            hanzi_row = pixel_y - 10'd638;
            hanzi_active = 1'b1;
            text_rgb = GOLD;
        end else if (price_bcd[11:8] == 0 && price_bcd[7:4] == 0 &&
                     pixel_x >= 11'd1136 && pixel_x < 11'd1168 &&
                     y_638_670) begin
            hanzi_phrase = 6'd4;
            hanzi_character = 5'd2 + price_bcd[3:0];
            hanzi_col = pixel_x - 11'd1136;
            hanzi_row = pixel_y - 10'd638;
            hanzi_active = 1'b1;
            text_rgb = GOLD;
        end else if (pixel_x >= (cart_total_price >= 100 ? 11'd1200 :
                                cart_total_price >= 10 ? 11'd1184 : 11'd1168) &&
                     pixel_x < (cart_total_price >= 100 ? 11'd1232 :
                               cart_total_price >= 10 ? 11'd1216 : 11'd1200) &&
                     y_638_670) begin
            hanzi_phrase = 6'd4;
            hanzi_character = 5'd0;
            hanzi_col = pixel_x - (cart_total_price >= 100 ? 11'd1200 :
                                   cart_total_price >= 10 ? 11'd1184 : 11'd1168);
            hanzi_row = pixel_y - 10'd638;
            hanzi_active = 1'b1;
            text_rgb = GOLD;
        end

        if ((cart_card_active && pixel_y >= 10'd636 && pixel_y < 10'd660 &&
             ((cart_local_x >= 8'd12 && cart_local_x < 8'd44) ||
              (cart_local_x >= 8'd76 && cart_local_x < 8'd108))) ||
            (pixel_x >= (cart_total_count >= 10 ? 11'd1144 : 11'd1160) &&
             pixel_x < (cart_total_count >= 10 ? 11'd1160 : 11'd1176) &&
             pixel_y >= 10'd600 && pixel_y < 10'd624)) begin
            if (!cart_card_active || cart_local_x >= 8'd172)
                ascii_character = "X";
            else if (cart_local_x < 8'd28)
                ascii_character = "X";
            else if (cart_local_x < 8'd44)
                ascii_character = "0" + cart_quantity;
            else if (cart_local_x < 8'd92)
                ascii_character = price_tens(cart_item) == 0 ?
                                  " " : "0" + price_tens(cart_item);
            else
                ascii_character = "0" + price_ones(cart_item);
            if (!cart_card_active || cart_local_x >= 8'd172)
                ascii_col = pixel_x - (cart_total_count >= 10 ? 11'd1144 : 11'd1160);
            else if (cart_local_x < 8'd28)
                ascii_col = cart_local_x - 8'd12;
            else if (cart_local_x < 8'd44)
                ascii_col = cart_local_x - 8'd28;
            else if (cart_local_x < 8'd92)
                ascii_col = cart_local_x - 8'd76;
            else
                ascii_col = cart_local_x - 8'd92;
            ascii_row = pixel_y - ((!cart_card_active || cart_local_x >= 8'd172) ? 10'd600 : 10'd636);
            ascii_active = 1'b1;
            text_rgb = INK;
        end else if (pixel_x >= 11'd42 && pixel_x < 11'd218 && y_054_078) begin
            text_cell = (pixel_x - 11'd42) >> 4;
            case (text_cell)
                0: ascii_character = "T";
                1: ascii_character = "A";
                2: ascii_character = "C";
                3: ascii_character = "I";
                4: ascii_character = "T";
                5: ascii_character = " ";
                6: ascii_character = "T";
                7: ascii_character = "A";
                8: ascii_character = "S";
                9: ascii_character = "T";
                default: ascii_character = "E";
            endcase
            ascii_col = (pixel_x - 11'd42) & 11'd15;
            ascii_row = pixel_y - 10'd54;
            ascii_active = 1'b1;
            text_rgb = GOLD_LIGHT;
        end else if (pixel_x >= 11'd1120 && pixel_x < 11'd1200 && y_050_074) begin
            text_cell = (pixel_x - 11'd1120) >> 4;
            case (text_cell)
                0: ascii_character = "0" + dish_index + 1'b1;
                1: ascii_character = "/";
                2: ascii_character = "4";
                default: ascii_character = " ";
            endcase
            ascii_col = (pixel_x - 11'd1120) & 11'd15;
            ascii_row = pixel_y - 10'd50;
            ascii_active = 1'b1;
            text_rgb = CREAM;
        end else if (pixel_x >= 11'd540 && pixel_x < 11'd600 && y_174_198) begin
            text_cell = (pixel_x - 11'd540) >> 4;
            case (text_cell)
                0: ascii_character = "Y";
                1: ascii_character = price_tens(item_index) == 0 ?
                                     " " : "0" + price_tens(item_index);
                2: ascii_character = "0" + price_ones(item_index);
                default: ascii_character = " ";
            endcase
            ascii_col = (pixel_x - 11'd540) & 11'd15;
            ascii_row = pixel_y - 10'd174;
            ascii_active = 1'b1;
            text_rgb = GOLD;
        end

        if (cart_distinct_count > 0 && pixel_x >= 11'd198 && pixel_x < 11'd230 &&
            y_600_632) begin
            thumbnail_dish = cart_order0;
            thumbnail_col = pixel_x - 11'd198;
            thumbnail_row = pixel_y - 10'd600;
            thumbnail_active = 1'b1;
        end else if (cart_distinct_count > 1 && pixel_x >= 11'd398 && pixel_x < 11'd430 &&
                     y_600_632) begin
            thumbnail_dish = cart_order1;
            thumbnail_col = pixel_x - 11'd398;
            thumbnail_row = pixel_y - 10'd600;
            thumbnail_active = 1'b1;
        end else if (cart_distinct_count > 2 && pixel_x >= 11'd598 && pixel_x < 11'd630 &&
                     y_600_632) begin
            thumbnail_dish = cart_order2;
            thumbnail_col = pixel_x - 11'd598;
            thumbnail_row = pixel_y - 10'd600;
            thumbnail_active = 1'b1;
        end else if (cart_distinct_count > 3 && pixel_x >= 11'd798 && pixel_x < 11'd830 &&
                     y_600_632) begin
            thumbnail_dish = cart_order3;
            thumbnail_col = pixel_x - 11'd798;
            thumbnail_row = pixel_y - 10'd600;
            thumbnail_active = 1'b1;
        end
    end
end

always @* begin
    popup_base_rgb = rgb_in;
    popup_text_rgb = WHITE;
    popup_hanzi_phrase = 6'd0;
    popup_hanzi_character = 5'd0;
    popup_hanzi_row = 5'd0;
    popup_hanzi_col = 5'd0;
    popup_hanzi_active = 1'b0;
    popup_ascii_character = " ";
    popup_ascii_row = 5'd0;
    popup_ascii_col = 5'd0;
    popup_ascii_active = 1'b0;
    popup_name_offset = 11'd0;

    if (pixel_x >= 11'd440 && pixel_x < popup_fill_end_latched &&
        pixel_y >= 10'd400 && pixel_y < 10'd424 &&
        pixel_x[0] == pixel_y[0])
        popup_base_rgb = accent_rgb;

    if (pixel_x >= popup_title_x && pixel_x < 11'd1280 - popup_title_x &&
        pixel_y >= 10'd280 && pixel_y < 10'd312) begin
        // Phrases 8-11, 13 for the interval, 14 for the colour and, from its
        // fifth character, the music (12 is the sold-out note).
        popup_hanzi_phrase = (popup_kind_latched >= 3'd5) ? 6'd14 :
                             (popup_kind_latched == 3'd4) ? 6'd13 : 6'd8 + popup_kind_latched;
        popup_hanzi_character = ((pixel_x - popup_title_x) >> 5) +
                                ((popup_kind_latched == 3'd6) ? 5'd4 : 5'd0);
        popup_hanzi_col = (pixel_x - popup_title_x) & 11'd31;
        popup_hanzi_row = pixel_y - 10'd280;
        popup_hanzi_active = 1'b1;
    end

    // Colour mode: the colour's two-character name from phrase 15 (青色 蓝色 ...),
    // drawn in that colour, instead of the number.
    if (popup_kind_latched == 3'd5 && pixel_y >= 10'd334 && pixel_y < 10'd366 &&
        pixel_x >= 11'd608 && pixel_x < 11'd672) begin
        popup_hanzi_phrase = 6'd15;
        popup_hanzi_character = {popup_color_index - 4'd1, pixel_x >= 11'd640};
        popup_hanzi_col = pixel_x[4:0];             // 608 and 640 are multiples of 32
        popup_hanzi_row = pixel_y - 10'd334;
        popup_hanzi_active = 1'b1;
        popup_text_rgb = accent_rgb;
    end

    // Music mode: the track's four-character name from phrase 13 (track n at
    // character 4n) instead of the number; track 0 is the music switched off
    // (已关闭, characters 6-8 of phrase 14).
    if (popup_kind_latched == 3'd6 && popup_ones_latched == 4'd0 &&
        pixel_y >= 10'd334 && pixel_y < 10'd366 &&
        pixel_x >= 11'd592 && pixel_x < 11'd688) begin
        popup_hanzi_phrase = 6'd14;
        popup_name_offset = pixel_x - 11'd592;
        popup_hanzi_character = 5'd6 + popup_name_offset[6:5];
        popup_hanzi_col = popup_name_offset[4:0];
        popup_hanzi_row = pixel_y - 10'd334;
        popup_hanzi_active = 1'b1;
    end
    if (popup_kind_latched == 3'd6 && popup_ones_latched != 4'd0 &&
        pixel_y >= 10'd334 && pixel_y < 10'd366 &&
        pixel_x >= 11'd576 && pixel_x < 11'd704) begin
        popup_hanzi_phrase = 6'd13;
        popup_name_offset = pixel_x - 11'd576;
        popup_hanzi_character = {popup_ones_latched[2:0], popup_name_offset[6:5]};
        popup_hanzi_col = pixel_x[4:0];             // 576 is a multiple of 32
        popup_hanzi_row = pixel_y - 10'd334;
        popup_hanzi_active = 1'b1;
    end

    if (popup_kind_latched < 3'd5 && pixel_y >= 10'd326 && pixel_y < 10'd374 &&
        ((popup_digit_count_latched == 2'd3 &&
          pixel_x >= 11'd592 && pixel_x < 11'd688) ||
         (popup_digit_count_latched == 2'd2 &&
          pixel_x >= 11'd608 && pixel_x < 11'd672) ||
         (popup_digit_count_latched == 2'd1 &&
          pixel_x >= 11'd624 && pixel_x < 11'd656))) begin
        popup_ascii_row = (pixel_y - 10'd326) >> 1;
        popup_ascii_active = 1'b1;
        if (popup_digit_count_latched == 2'd3) begin
            popup_ascii_col = ((pixel_x - 11'd592) & 11'd31) >> 1;
            if (pixel_x < 11'd624)
                popup_ascii_character = "0" + popup_hundreds_latched;
            else if (pixel_x < 11'd656)
                popup_ascii_character = "0" + popup_tens_latched;
            else
                popup_ascii_character = "0" + popup_ones_latched;
        end else if (popup_digit_count_latched == 2'd2) begin
            popup_ascii_col = ((pixel_x - 11'd608) & 11'd31) >> 1;
            popup_ascii_character = pixel_x < 11'd640 ?
                                    "0" + popup_tens_latched :
                                    "0" + popup_ones_latched;
        end else begin
            popup_ascii_col = ((pixel_x - 11'd624) & 11'd31) >> 1;
            popup_ascii_character = "0" + popup_ones_latched;
        end
    end
end

always @* begin
    if ((title_active_render_stage && title_col_render_stage < 6'd40 &&
         title_bits_render_stage[39-title_col_render_stage]) ||
        (hanzi_active_render_stage && hanzi_bits_render_stage[31-hanzi_col_render_stage]) ||
        (ascii_active_render_stage && ascii_col_render_stage < 5'd16 &&
         ascii_bits_render_stage[15-ascii_col_render_stage]))
        rendered_rgb = text_render_stage;
    else if (thumbnail_active_render_stage)
        rendered_rgb = rgb332_to_rgb888(thumbnail_pixel_render_stage);
    else
        rendered_rgb = base_render_stage;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        popup_alpha <= 5'd0;
        popup_kind_latched <= 3'd0;
        popup_ones_latched <= 4'd0;
        popup_tens_latched <= 4'd0;
        popup_hundreds_latched <= 4'd0;
        popup_digit_count_latched <= 2'd1;
        popup_fill_end_latched <= 11'd440;
    end else if (!vs_q && vs) begin
        if (menu_state != MENU_CATEGORY) begin
            popup_alpha <= 5'd0;
        end else if (parameter_popup_active) begin
            popup_alpha <= 5'd16;
            popup_kind_latched <= parameter_popup_kind;
            popup_ones_latched <= parameter_popup_ones;
            popup_tens_latched <= parameter_popup_tens;
            popup_hundreds_latched <= parameter_popup_hundreds;
            popup_digit_count_latched <= parameter_popup_digit_count;
            popup_fill_end_latched <= parameter_popup_fill_end;
        end else if (popup_alpha != 0) begin
            popup_alpha <= popup_alpha - 1'b1;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        price_binary_work <= 10'd0;
        price_bcd_work <= 12'd0;
        price_bcd <= 12'd0;
        count_binary_work <= 10'd0;
        count_bcd_work <= 8'd0;
        count_bcd <= 8'd0;
        bcd_price_source <= 10'd0;
        bcd_count_source <= 6'd0;
        bcd_step <= 4'd0;
    end else if (cart_total_price != bcd_price_source ||
                 cart_total_count != bcd_count_source) begin
        price_binary_work <= cart_total_price;
        price_bcd_work <= 12'd0;
        count_binary_work <= {4'd0, cart_total_count};
        count_bcd_work <= 8'd0;
        bcd_price_source <= cart_total_price;
        bcd_count_source <= cart_total_count;
        bcd_step <= 4'd10;
    end else if (bcd_step != 0) begin
        price_bcd_work <= {price_bcd_adjusted[10:0], price_binary_work[9]};
        price_binary_work <= {price_binary_work[8:0], 1'b0};
        count_bcd_work <= {count_bcd_adjusted[6:0], count_binary_work[9]};
        count_binary_work <= {count_binary_work[8:0], 1'b0};
        bcd_step <= bcd_step - 1'b1;
        if (bcd_step == 1) begin
            price_bcd <= {price_bcd_adjusted[10:0], price_binary_work[9]};
            count_bcd <= {count_bcd_adjusted[6:0], count_binary_work[9]};
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pixel_x <= 11'd0; pixel_y <= 10'd0; de_q <= 1'b0; vs_q <= 1'b0;
        y_008_048 <= 1'b0; y_016_048 <= 1'b0; y_050_074 <= 1'b0; y_054_078 <= 1'b0;
        y_116_156 <= 1'b0; y_174_198 <= 1'b0; y_208_240 <= 1'b0; y_256_288 <= 1'b0;
        y_296_328 <= 1'b0; y_336_368 <= 1'b0; y_376_408 <= 1'b0; y_392_424 <= 1'b0;
        y_416_448 <= 1'b0; y_450_482 <= 1'b0; y_480_512 <= 1'b0; y_596_628 <= 1'b0;
        y_496_540 <= 1'b0; y_502_534 <= 1'b0;
        y_600_632 <= 1'b0; y_615_647 <= 1'b0; y_616_648 <= 1'b0; y_632_664 <= 1'b0;
        y_638_670 <= 1'b0;
        base_stage <= 24'd0; text_stage <= INK;
        hanzi_phrase_stage <= 6'd0; hanzi_character_stage <= 5'd0;
        hanzi_row_stage <= 5'd0; hanzi_col_stage <= 5'd0; hanzi_active_stage <= 1'b0;
        title_phrase_stage <= 5'd0; title_character_stage <= 3'd0;
        title_row_stage <= 6'd0; title_col_stage <= 6'd0; title_active_stage <= 1'b0;
        ascii_character_stage <= " "; ascii_row_stage <= 5'd0;
        ascii_col_stage <= 5'd0; ascii_active_stage <= 1'b0;
        thumbnail_dish_stage <= 4'd0; thumbnail_row_stage <= 5'd0;
        thumbnail_col_stage <= 5'd0; thumbnail_active_stage <= 1'b0;
        vs_stage <= 1'b0; de_stage <= 1'b0;
        base_font_stage <= 24'd0; text_font_stage <= INK;
        hanzi_col_font_stage <= 5'd0; hanzi_active_font_stage <= 1'b0;
        title_col_font_stage <= 6'd0; title_active_font_stage <= 1'b0;
        ascii_col_font_stage <= 5'd0; ascii_active_font_stage <= 1'b0;
        thumbnail_active_font_stage <= 1'b0;
        vs_font_stage <= 1'b0; de_font_stage <= 1'b0;
        base_render_stage <= 24'd0; text_render_stage <= INK;
        hanzi_col_render_stage <= 5'd0; hanzi_active_render_stage <= 1'b0;
        title_col_render_stage <= 6'd0; title_active_render_stage <= 1'b0;
        ascii_col_render_stage <= 5'd0; ascii_active_render_stage <= 1'b0;
        thumbnail_active_render_stage <= 1'b0;
        hanzi_bits_render_stage <= 32'd0;
        title_bits_render_stage <= 40'd0; ascii_bits_render_stage <= 16'd0;
        thumbnail_pixel_render_stage <= 8'd0;
        vs_render_stage <= 1'b0; de_render_stage <= 1'b0;
        vs_pipe <= 1'b0; de_pipe <= 1'b0;
        vs_output_stage <= 1'b0; de_output_stage <= 1'b0;
        rgb_output_stage <= 24'd0;
    end else begin
        vs_q <= vs; de_q <= de;
        if (!vs_q && vs) begin pixel_x <= 11'd0; pixel_y <= 10'd0; end
        else if (de) pixel_x <= pixel_x + 1'b1;
        else begin pixel_x <= 11'd0; if (de_q) pixel_y <= pixel_y + 1'b1; end
        y_008_048 <= pixel_y >= 10'd8 && pixel_y < 10'd48;
        y_016_048 <= pixel_y >= 10'd16 && pixel_y < 10'd48;
        y_050_074 <= pixel_y >= 10'd50 && pixel_y < 10'd74;
        y_054_078 <= pixel_y >= 10'd54 && pixel_y < 10'd78;
        y_116_156 <= pixel_y >= 10'd116 && pixel_y < 10'd156;
        y_174_198 <= pixel_y >= 10'd174 && pixel_y < 10'd198;
        y_208_240 <= pixel_y >= 10'd208 && pixel_y < 10'd240;
        y_256_288 <= pixel_y >= 10'd256 && pixel_y < 10'd288;
        y_296_328 <= pixel_y >= 10'd296 && pixel_y < 10'd328;
        y_336_368 <= pixel_y >= 10'd336 && pixel_y < 10'd368;
        y_376_408 <= pixel_y >= 10'd376 && pixel_y < 10'd408;
        y_392_424 <= pixel_y >= 10'd392 && pixel_y < 10'd424;
        y_416_448 <= pixel_y >= 10'd416 && pixel_y < 10'd448;
        y_450_482 <= pixel_y >= 10'd450 && pixel_y < 10'd482;
        y_496_540 <= pixel_y >= 10'd496 && pixel_y < 10'd540;
        y_502_534 <= pixel_y >= 10'd502 && pixel_y < 10'd534;
        y_480_512 <= pixel_y >= 10'd480 && pixel_y < 10'd512;
        y_596_628 <= pixel_y >= 10'd596 && pixel_y < 10'd628;
        y_600_632 <= pixel_y >= 10'd600 && pixel_y < 10'd632;
        y_615_647 <= pixel_y >= 10'd615 && pixel_y < 10'd647;
        y_616_648 <= pixel_y >= 10'd616 && pixel_y < 10'd648;
        y_632_664 <= pixel_y >= 10'd632 && pixel_y < 10'd664;
        y_638_670 <= pixel_y >= 10'd638 && pixel_y < 10'd670;
        if (popup_overlay_active) begin
            base_stage <= popup_base_rgb; text_stage <= popup_text_rgb;
            hanzi_phrase_stage <= popup_hanzi_phrase;
            hanzi_character_stage <= popup_hanzi_character;
            hanzi_row_stage <= popup_hanzi_row; hanzi_col_stage <= popup_hanzi_col;
            hanzi_active_stage <= popup_hanzi_active;
            title_phrase_stage <= 5'd0; title_character_stage <= 3'd0;
            title_row_stage <= 6'd0; title_col_stage <= 6'd0;
            title_active_stage <= 1'b0;
            ascii_character_stage <= popup_ascii_character;
            ascii_row_stage <= popup_ascii_row; ascii_col_stage <= popup_ascii_col;
            ascii_active_stage <= popup_ascii_active;
            thumbnail_dish_stage <= 4'd0; thumbnail_row_stage <= 5'd0;
            thumbnail_col_stage <= 5'd0; thumbnail_active_stage <= 1'b0;
        end else begin
            base_stage <= base_rgb; text_stage <= text_rgb;
            hanzi_phrase_stage <= hanzi_phrase; hanzi_character_stage <= hanzi_character;
            hanzi_row_stage <= hanzi_row; hanzi_col_stage <= hanzi_col;
            hanzi_active_stage <= hanzi_active;
            title_phrase_stage <= title_phrase; title_character_stage <= title_character;
            title_row_stage <= title_row; title_col_stage <= title_col;
            title_active_stage <= title_active;
            ascii_character_stage <= ascii_character; ascii_row_stage <= ascii_row;
            ascii_col_stage <= ascii_col; ascii_active_stage <= ascii_active;
            thumbnail_dish_stage <= thumbnail_dish; thumbnail_row_stage <= thumbnail_row;
            thumbnail_col_stage <= thumbnail_col;
            thumbnail_active_stage <= thumbnail_active;
        end
        base_font_stage <= base_stage; text_font_stage <= text_stage;
        hanzi_col_font_stage <= hanzi_col_stage;
        hanzi_active_font_stage <= hanzi_active_stage;
        title_col_font_stage <= title_col_stage;
        title_active_font_stage <= title_active_stage;
        ascii_col_font_stage <= ascii_col_stage;
        ascii_active_font_stage <= ascii_active_stage;
        thumbnail_active_font_stage <= thumbnail_active_stage;
        vs_stage <= vs; de_stage <= de;
        vs_font_stage <= vs_stage; de_font_stage <= de_stage;
        base_render_stage <= base_font_stage; text_render_stage <= text_font_stage;
        hanzi_col_render_stage <= hanzi_col_font_stage;
        hanzi_active_render_stage <= hanzi_active_font_stage;
        title_col_render_stage <= title_col_font_stage;
        title_active_render_stage <= title_active_font_stage;
        ascii_col_render_stage <= ascii_col_font_stage;
        ascii_active_render_stage <= ascii_active_font_stage;
        thumbnail_active_render_stage <= thumbnail_active_font_stage;
        hanzi_bits_render_stage <= hanzi_bits;
        title_bits_render_stage <= title_bits;
        ascii_bits_render_stage <= ascii_bits;
        thumbnail_pixel_render_stage <= thumbnail_pixel;
        vs_render_stage <= vs_font_stage; de_render_stage <= de_font_stage;
        vs_pipe <= vs_render_stage; de_pipe <= de_render_stage;
        vs_output_stage <= vs_pipe; de_output_stage <= de_pipe;
        rgb_output_stage <= rendered_rgb;
    end
end
endmodule
