
// Legacy K1 reset input retained for reference; physical K1 is now next-image.
// input                       rst_n,
module top(
    input                       clk,
    input                       key1,           // Physical KEY1: next image
    input                       key2,           // Physical KEY2: previous image
    input                       key3,           // Physical KEY3: parameter adjust
    input                       key4,           // Physical KEY4: auto/manual mode
    input                       sw1,            // Physical SW1: mode bit 0
    input                       sw2,            // Physical SW2: mode bit 1
    input                       sw3,            // Physical SW3: mode bit 2
    input                       sw4,            // Physical SW4: mode bit 3

	output [7:0]                seg_sel,
	output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso,

    // Gigabit Ethernet (RTL8211E, RGMII) to the kitchen board
    output [3:0]                phy1_rgmii_tx_data,
    output                      phy1_rgmii_tx_ctl,
    output                      phy1_rgmii_tx_clk,
    input  [3:0]                phy1_rgmii_rx_data,
    input                       phy1_rgmii_rx_ctl,
    input                       phy1_rgmii_rx_clk,
    output [3:0]                led             // LED0 link, LED1 receive, LED2 send, LED3 order pending
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter [ADDR_BITS-1:0] FRAME_PIXELS  = 21'd921600;   // 1280*720
parameter [ADDR_BITS-1:0] FRAME_WORDS   = FRAME_PIXELS / 2; // two RGB565 pixels per SDRAM word
parameter [ADDR_BITS-1:0] BUF0_ADDR     = 21'd0;
parameter [ADDR_BITS-1:0] BUF1_ADDR     = FRAME_WORDS;
parameter [ADDR_BITS-1:0] BUF2_ADDR     = FRAME_WORDS * 2;
parameter [ADDR_BITS-1:0] BUF3_ADDR     = FRAME_WORDS * 3;
parameter [ADDR_BITS-1:0] PHOTO_BASE_ADDR = FRAME_WORDS * 4;
parameter [ADDR_BITS-1:0] PHOTO_WORDS     = 21'd58400;
parameter [ADDR_BITS-1:0] PHOTO_STRIDE_WORDS = 21'd59200;
parameter [ADDR_BITS-1:0] PHOTO_ASSET_WORDS = PHOTO_STRIDE_WORDS * 4;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data_base;
wire [23:0] transition_data;
wire [23:0] vout_data;
wire [23:0] adjusted_data;
wire        transition_vs;
wire        transition_de;
wire        transition_busy;
wire [4:0]  transition_level;
wire        osd_vs;
wire        osd_de;
wire        waveform_vs;
wire        waveform_de;
wire [23:0] waveform_data;
wire        order_menu_vs;
wire        order_menu_de;
wire [23:0] order_menu_data;
wire        order_transition_vs;
wire        order_transition_de;
wire [23:0] order_transition_data;
wire [1:0]  order_active_menu_state;
wire [1:0]  order_active_dish_index;
wire        welcome_vs;
wire        welcome_de;
wire [23:0] welcome_data;
wire        welcome_active;
wire        welcome_done;
wire        welcome_chime_start;
wire        welcome_chime_exit;
wire        welcome_done_sd;
wire        thumbnail_vs;
wire        thumbnail_de;
wire [23:0] thumbnail_data;
wire        display_valid;
wire [2:0]  image_index_status;
wire [3:0]  image_count_status;
wire        auto_play_enabled;
wire [3:0]  resident_status;
wire [2:0]  bank_owner0_status;
wire [2:0]  bank_owner1_status;
wire [2:0]  bank_owner2_status;
wire [2:0]  bank_owner3_status;
wire [7:0]  category_cache_status;
wire [7:0]  startup_progress;
wire        preload_settled;
wire        preload_settled_video;
wire        thumbnail_mode;
wire [1:0]  menu_state;
wire [1:0]  dish_index;
wire [1:0]  category_index;
wire        photo_asset_ready;
wire        photo_asset_boot_done;
wire        photo_asset_write_mode;
wire        photo_asset_ready_video;
wire        photo_asset_boot_done_video;
wire [3:0]  cart_qty0;
wire [3:0]  cart_qty1;
wire [3:0]  cart_qty2;
wire [3:0]  cart_qty3;
wire [5:0]  cart_total_count;
wire [9:0]  cart_total_price;
wire [3:0]  cart_order0;
wire [3:0]  cart_order1;
wire [3:0]  cart_order2;
wire [3:0]  cart_order3;
wire [2:0]  cart_distinct_count;
wire        adjusted_vs;
wire        adjusted_de;
wire [3:0]  auto_elapsed_seconds;
wire [3:0]  auto_elapsed_tenths;
wire [3:0]  auto_elapsed_hundredths;

wire [3:0]  state_code;
wire [6:0]  seg_data_0;
wire [6:0]  seg_parameter_ones;
wire [6:0]  seg_parameter_tens;
wire [6:0]  seg_parameter_hundreds;
wire [6:0]  seg_switch_msb;
wire [6:0]  seg_switch_lsb;
wire [7:0]  seg_startup_dash = {1'b1, 7'b011_1111};
wire        loading;
wire [3:0]  state_code_seg_sync;
wire        loading_seg_sync;
wire [7:0]  brightness_cfg;
wire [7:0]  contrast_cfg;
wire [7:0]  volume_cfg;
wire        parameter_display_active;
wire [2:0]  selected_parameter;
wire [3:0]  ticker_speed_cfg;
wire [3:0]  auto_interval_cfg;      // level 1..11
wire [3:0]  wave_color_cfg;         // colour 1..10 (switch mode 0110)
wire        music_on_cfg;           // K3 in mode 0111 switches the music on / off
// Track of the current screen (video clock) back in the control clock, for
// the popup and the seven segments.
(* async_reg = "true" *) reg [2:0] music_target_ctrl_sync0;
(* async_reg = "true" *) reg [2:0] music_target_ctrl_sync1;
wire [2:0]  music_shown_track = music_on_cfg ? music_target_ctrl_sync1 : 3'd0;
reg  [3:0]  auto_interval_seconds;  // 5..15 s, registered: other clock domains sample it
wire        control_rst_n;
// Mode {SW4, SW3, SW2, SW1}: 0000 pictures, 0001-0111 parameters, 1111 submit.
wire [3:0]  selected_switch = {~sw4, ~sw3, ~sw2, ~sw1};
wire        parameter_mode_active = selected_switch != 4'b0000;
// Dishes sold out, bit {category, dish}, from the kitchen over the link.
wire [15:0] sold_out_mask;
// Switch mode 111: K4 submits the cart to the kitchen instead of going back.
wire        submit_mode = selected_switch == 4'b1111;
(* async_reg = "true" *) reg [15:0] sold_out_video_sync0;
(* async_reg = "true" *) reg [15:0] sold_out_video_sync1;
(* async_reg = "true" *) reg [3:0]  ticker_speed_video_sync0;
(* async_reg = "true" *) reg [3:0]  ticker_speed_video_sync1;
(* async_reg = "true" *) reg [3:0]  interval_video_sync0;
(* async_reg = "true" *) reg [3:0]  interval_video_sync1;
reg  [3:0]  interval_video;
(* async_reg = "true" *) reg [3:0] wave_color_video_sync0;
(* async_reg = "true" *) reg [3:0] wave_color_video_sync1;
reg  [23:0] accent_rgb;             // waveform, its progress bar, popup bars
wire [10:0] auto_progress_px;
wire        auto_progress_on;       // auto-play running (assigned below)
// Advert player (sd_card_clk domain): while a poster is up the keys belong to it.
wire [3:0]  ad_bank_mask;
wire [2:0]  ad_zoom_level;
wire        ad_key_mask;
wire        parameter_navigation_lock = parameter_mode_active && menu_state == 2'd0;
wire        image_key_next = !welcome_done_sd || parameter_navigation_lock || ad_key_mask ? 1'b1 : key1;
wire        image_key_prev = !welcome_done_sd || parameter_navigation_lock || ad_key_mask ? 1'b1 : key2;
wire        image_key_auto = ad_key_mask ? 1'b1 :
                             !welcome_done_sd || parameter_navigation_lock || submit_mode ?
                              (auto_play_enabled ? 1'b0 : 1'b1) : key4;
// In mode 0111 on the main screen K3 switches the music, it does not open a dish.
wire        music_key_lock = selected_switch == 4'b0111 && menu_state == 2'd0;
wire        image_key_confirm = !welcome_done_sd || ad_key_mask || music_key_lock ? 1'b1 : key3;
wire        image_key_back = !welcome_done_sd || parameter_navigation_lock || submit_mode ||
                             ad_key_mask ? 1'b1 : key4;
wire        image_key_submit = !welcome_done_sd || !submit_mode || ad_key_mask ? 1'b1 : key4;
wire [7:0]  brightness_video;
wire [7:0]  contrast_video;
wire [7:0]  volume_video;
wire [7:0]  selected_value;
wire [7:0]  selected_display_value;
wire [3:0]  selected_display_ones;
wire [3:0]  selected_display_tens;
wire [3:0]  selected_display_hundreds;
wire [1:0]  selected_display_digit_count;
wire [10:0] selected_popup_fill_end;
(* async_reg = "true" *) reg parameter_popup_active_sync0;
(* async_reg = "true" *) reg parameter_popup_active_sync1;
(* async_reg = "true" *) reg [2:0] parameter_popup_kind_sync0;
(* async_reg = "true" *) reg [2:0] parameter_popup_kind_sync1;
(* async_reg = "true" *) reg [3:0] parameter_popup_ones_sync0;
(* async_reg = "true" *) reg [3:0] parameter_popup_ones_sync1;
(* async_reg = "true" *) reg [3:0] parameter_popup_tens_sync0;
(* async_reg = "true" *) reg [3:0] parameter_popup_tens_sync1;
(* async_reg = "true" *) reg [3:0] parameter_popup_hundreds_sync0;
(* async_reg = "true" *) reg [3:0] parameter_popup_hundreds_sync1;
(* async_reg = "true" *) reg [1:0] parameter_popup_digit_count_sync0;
(* async_reg = "true" *) reg [1:0] parameter_popup_digit_count_sync1;
(* async_reg = "true" *) reg [10:0] parameter_popup_fill_end_sync0;
(* async_reg = "true" *) reg [10:0] parameter_popup_fill_end_sync1;
reg  [7:0]  brightness_scaled;
reg  [7:0]  contrast_scaled;
reg  [7:0]  volume_scaled;
wire [7:0]  brightness_sync1;
wire [7:0]  contrast_sync1;
wire [7:0]  volume_sync1;
reg  [7:0]  brightness_frame;
reg  [7:0]  contrast_frame;
wire [1:0]  menu_state_control;
(* async_reg = "true" *) reg ad_key_mask_sync0;
(* async_reg = "true" *) reg ad_key_mask_sync1;
wire welcome_done_control;
wire        parameter_adjust_enabled = welcome_done_control && menu_state_control == 2'd0 &&
                                       !ad_key_mask_sync1;

// Auto-play interval levels 1..11 are 5..15 s, one second apart (default 4 = 8 s).
always @(posedge clk or negedge control_rst_n)
    if (!control_rst_n) auto_interval_seconds <= 4'd8;
    else auto_interval_seconds <= auto_interval_cfg + 4'd4;

function [7:0] selected_parameter_value;
    input [2:0] selected;
    begin
        case (selected)
            3'd0: selected_parameter_value = brightness_cfg;
            3'd1: selected_parameter_value = contrast_cfg;
            3'd2: selected_parameter_value = volume_cfg;
            3'd3: selected_parameter_value = {4'd0, ticker_speed_cfg};
            3'd4: selected_parameter_value = {4'd0, auto_interval_seconds};
            3'd5: selected_parameter_value = {4'd0, wave_color_cfg};
            default: selected_parameter_value = {5'd0, music_shown_track};
        endcase
    end
endfunction

function [3:0] decimal_digit;
    input [7:0] value;
    input [1:0] position;
    begin
        case (position)
            2'd0: decimal_digit = value % 10;
            2'd1: decimal_digit = (value / 10) % 10;
            default: decimal_digit = value / 100;
        endcase
    end
endfunction

assign selected_value = selected_parameter_value(selected_parameter);

function [7:0] percent_to_u8;
    input [7:0] value;
    begin
        percent_to_u8 = (value >= 8'd100) ? 8'd255 :
                        ((value * 16'd653 + 16'd128) >> 8);
    end
endfunction

function signed [23:0] saturate_audio;
    input signed [24:0] sample;
    begin
        if (sample > 25'sd8_388_607)
            saturate_audio = 24'sh7f_ffff;
        else if (sample < -25'sd8_388_608)
            saturate_audio = -24'sd8_388_608;
        else
            saturate_audio = sample[23:0];
    end
endfunction

assign selected_display_value = selected_value;
assign selected_display_ones = decimal_digit(selected_display_value, 2'd0);
assign selected_display_tens = decimal_digit(selected_display_value, 2'd1);
assign selected_display_hundreds = decimal_digit(selected_display_value, 2'd2);
assign selected_display_digit_count = selected_display_value >= 8'd100 ? 2'd3 :
                                      selected_display_value >= 8'd10 ? 2'd2 : 2'd1;
// 0-100 % fills 4 px per step; ticker levels and colours 1-10 fill 40 px per
// step; the eleven interval levels fill 400 px in 36-37 px steps.
function [10:0] interval_fill;
    input [3:0] level;
    begin
        case (level)
            4'd1: interval_fill = 11'd36;
            4'd2: interval_fill = 11'd73;
            4'd3: interval_fill = 11'd109;
            4'd4: interval_fill = 11'd145;
            4'd5: interval_fill = 11'd182;
            4'd6: interval_fill = 11'd218;
            4'd7: interval_fill = 11'd255;
            4'd8: interval_fill = 11'd291;
            4'd9: interval_fill = 11'd327;
            4'd10: interval_fill = 11'd364;
            default: interval_fill = 11'd400;
        endcase
    end
endfunction
// The six music tracks fill 400 px in 66-67 px steps.
function [10:0] music_fill;
    input [2:0] track;
    begin
        case (track)
            3'd0: music_fill = 11'd0;      // music off
            3'd1: music_fill = 11'd67;
            3'd2: music_fill = 11'd133;
            3'd3: music_fill = 11'd200;
            3'd4: music_fill = 11'd267;
            3'd5: music_fill = 11'd333;
            default: music_fill = 11'd400;
        endcase
    end
endfunction
assign selected_popup_fill_end = (selected_parameter == 3'd3 || selected_parameter == 3'd5) ?
                                 11'd440 + selected_display_value * 11'd40 :
                                 (selected_parameter == 3'd4) ?
                                 11'd440 + interval_fill(auto_interval_cfg) :
                                 (selected_parameter == 3'd6) ?
                                 11'd440 + music_fill(music_shown_track) :
                                 11'd440 + {1'b0, selected_display_value, 2'b00};


wire [6:0] seg_switch_ones;
seg_decoder seg_mode_decoder (
    .bin_data          (selected_switch >= 4'd10 ? selected_switch - 4'd10 : selected_switch),
    .seg_data          (seg_switch_ones)
);
assign seg_switch_msb = selected_switch >= 4'd10 ? 7'b111_1001 : seg_switch_ones;   // "1"
assign seg_switch_lsb = selected_switch >= 4'd10 ? seg_switch_ones : 7'b111_1111;

wire        video_read_req;
wire        video_read_req_raw;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;
wire        video_read_underflow;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;
wire [2:0]  thumbnail_focus_idx;
wire        thumbnail_exit_toggle;
(* async_reg = "true" *) reg [1:0] disp_buf_idx_sync0;
(* async_reg = "true" *) reg [1:0] disp_buf_idx_sync1;
wire [1:0]  disp_buf_idx_frame;
(* async_reg = "true" *) reg [2:0] image_index_sync0;
(* async_reg = "true" *) reg [2:0] image_index_sync1;
reg [2:0] image_index_frame;
(* async_reg = "true" *) reg [3:0] image_count_sync0;
(* async_reg = "true" *) reg [3:0] image_count_sync1;
(* async_reg = "true" *) reg [2:0] thumbnail_focus_sync0;
(* async_reg = "true" *) reg [2:0] thumbnail_focus_sync1;
reg [2:0]   thumbnail_focus_frame;
(* async_reg = "true" *) reg [1:0] menu_state_sync0;
(* async_reg = "true" *) reg [1:0] menu_state_sync1;
(* async_reg = "true" *) reg [1:0] dish_index_sync0;
(* async_reg = "true" *) reg [1:0] dish_index_sync1;
reg [1:0]   menu_state_frame;
reg [1:0]   dish_index_frame;
(* async_reg = "true" *) reg [1:0] category_index_sync0;
(* async_reg = "true" *) reg [1:0] category_index_sync1;
reg [1:0]   category_index_frame;
(* async_reg = "true" *) reg [15:0] cart_qty_sync0;
(* async_reg = "true" *) reg [15:0] cart_qty_sync1;
(* async_reg = "true" *) reg [5:0] cart_total_count_sync0;
(* async_reg = "true" *) reg [5:0] cart_total_count_sync1;
(* async_reg = "true" *) reg [9:0] cart_total_price_sync0;
(* async_reg = "true" *) reg [9:0] cart_total_price_sync1;
(* async_reg = "true" *) reg [15:0] cart_order_sync0;
(* async_reg = "true" *) reg [15:0] cart_order_sync1;
(* async_reg = "true" *) reg [2:0] cart_distinct_count_sync0;
(* async_reg = "true" *) reg [2:0] cart_distinct_count_sync1;
reg [15:0] cart_order_frame;
reg [2:0] cart_distinct_count_frame;
wire        thumbnail_fade_pending;
wire        thumbnail_direct_pending;
(* async_reg = "true" *) reg display_valid_sync0;
(* async_reg = "true" *) reg display_valid_sync1;
reg         display_valid_frame;
(* async_reg = "true" *) reg auto_play_sync0;
(* async_reg = "true" *) reg auto_play_sync1;
(* async_reg = "true" *) reg loading_video_sync0;
(* async_reg = "true" *) reg loading_video_sync1;
(* async_reg = "true" *) reg [3:0] resident_sync0;
(* async_reg = "true" *) reg [3:0] resident_sync1;
(* async_reg = "true" *) reg [2:0] bank_owner0_sync0;
(* async_reg = "true" *) reg [2:0] bank_owner0_sync1;
(* async_reg = "true" *) reg [2:0] bank_owner1_sync0;
(* async_reg = "true" *) reg [2:0] bank_owner1_sync1;
(* async_reg = "true" *) reg [2:0] bank_owner2_sync0;
(* async_reg = "true" *) reg [2:0] bank_owner2_sync1;
(* async_reg = "true" *) reg [2:0] bank_owner3_sync0;
(* async_reg = "true" *) reg [2:0] bank_owner3_sync1;
(* async_reg = "true" *) reg [7:0] category_cache_sync0;
(* async_reg = "true" *) reg [7:0] category_cache_sync1;
(* async_reg = "true" *) reg [7:0] startup_progress_sync0;
(* async_reg = "true" *) reg [7:0] startup_progress_sync1;
wire        thumbnail_mode_frame;
wire        photo_mode_frame = order_active_menu_state != 2'd0 && photo_asset_ready_video;
wire [ADDR_BITS-1:0] photo_read_addr = PHOTO_BASE_ADDR +
                                      order_active_dish_index * PHOTO_STRIDE_WORDS;
reg         vs_0_d;
wire        frame_start_video;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 相关
wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

reg         audio_valid;
reg  [23:0] audio_left_data;
reg  [23:0] audio_right_data;
wire        transition_chime_active;
wire signed [23:0] transition_chime_left;
wire signed [23:0] transition_chime_right;
wire        key1_click_pulse;
wire        key2_click_pulse;
wire        key3_click_pulse;
wire        key4_click_pulse;
wire        key_click_trigger;
wire [1:0]  key_click_code;
wire        key_click_active;
wire signed [23:0] key_click_left;
wire signed [23:0] key_click_right;
(* async_reg = "true" *) reg key1_video_sync0;
(* async_reg = "true" *) reg key1_video_sync1;
(* async_reg = "true" *) reg key2_video_sync0;
(* async_reg = "true" *) reg key2_video_sync1;
(* async_reg = "true" *) reg key3_video_sync0;
(* async_reg = "true" *) reg key3_video_sync1;
(* async_reg = "true" *) reg key4_video_sync0;
(* async_reg = "true" *) reg key4_video_sync1;
wire        audio_sd_req;
wire [31:0] audio_sd_lba;
wire        audio_sd_busy;
wire        audio_sd_valid;
wire [7:0]  audio_sd_byte;
wire [8:0]  audio_sd_byte_index;
wire        audio_sd_done;
wire [7:0]  audio_sd_error;
wire        audio_file_available;
wire [31:0] audio_file_start_lba;
wire [31:0] audio_file_total_sectors;
wire        wav_sample_valid;
wire signed [15:0] wav_sample_out;
wire        wav_stream_active;
wire        wav_stream_end;
wire        wav_buffer_low;
wire        audio_play_enable;
wire [31:0] audio_track_start_lba;
wire [31:0] audio_track_total_sectors;
wire [2:0]  audio_track_active;
reg  [31:0] audio_track_start_lba_reg;
reg  [31:0] audio_track_total_sectors_reg;
// The music follows the screen (video clock), see music_scene_fader.
(* async_reg = "true" *) reg       music_want_sync0;
(* async_reg = "true" *) reg       music_want_sync1;
reg  [2:0]  music_target_track;
wire        music_play_on;
wire [2:0]  music_play_track;
wire [7:0]  music_gain;
wire signed [15:0] music_faded_sample;
reg         wav_sample_valid_d1;
reg         wav_sample_valid_d2;
(* async_reg = "true" *) reg [3:0] audio_track_sync0;    // {music on, track - 1}
(* async_reg = "true" *) reg [3:0] audio_track_sync1;
reg  [2:0]  audio_track_request;
reg         audio_music_on;
reg         audio_music_started;
wire [7:0]  audio_effective_gain;
reg  [7:0]  audio_effective_gain_q;
wire signed [23:0] audio_source_left;
wire signed [23:0] audio_source_right;
wire signed [23:0] audio_base_left;
wire signed [23:0] audio_base_right;
wire signed [24:0] audio_mix_left;
wire signed [24:0] audio_mix_right;
reg  signed [24:0] audio_mix_left_q;
reg  signed [24:0] audio_mix_right_q;
wire signed [33:0] audio_left_scaled;
wire signed [33:0] audio_right_scaled;
reg  signed [15:0] waveform_pcm_sample;
reg                waveform_pcm_valid;
reg [31:0]  audio_sample_accumulator;
reg         audio_sample_tick;
reg signed [23:0] audio_source_left_q;
reg signed [23:0] audio_source_right_q;
reg               audio_mix_valid_q;
reg               audio_valid_raw_q;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 统一复位：TF 图像链路 + HDMI 链路
wire sys_pll_lock;
wire video_pll_lock;
wire rst_all;
wire pll_ready_n;
wire reset_release_n;
wire sdcard_rst_n;
wire mem_rst_n;
wire video_rst_n;
wire sdram_init_done_sd;
wire sdcard_app_rst;

reg [19:0] rst_cnt = 20'd0;
reg rst_all_reg = 1'b1;

// Legacy external K1 reset is intentionally disabled. Configuration and
// the PLL lock sequence now provide the reset source.
wire rst_n = 1'b1;
assign pll_ready_n = sys_pll_lock & video_pll_lock;

always @(posedge clk or negedge pll_ready_n) begin
    if (!pll_ready_n) begin
        rst_cnt <= 20'd0;
        rst_all_reg <= 1'b1;
    end else if (!rst_all_reg) begin
        // 一旦复位释放，忽略后续微小的 PLL 抖动，防止系统在使用时随机复位
        rst_all_reg <= 1'b0;
    end else if (sys_pll_lock && video_pll_lock) begin
        // 等待 PLL 连续稳定 20ms @ 50MHz
        if (rst_cnt < 20'd1_000_000) begin
            rst_cnt <= rst_cnt + 1'b1;
            rst_all_reg <= 1'b1;
        end else begin
            rst_all_reg <= 1'b0;
        end
    end else begin
        rst_cnt <= 20'd0;
        rst_all_reg <= 1'b1;
    end
end

assign rst_all = rst_all_reg;
assign reset_release_n = ~rst_all;
assign sdcard_app_rst = ~sdcard_rst_n | ~sdram_init_done_sd;

parameter_adjust_controller u_parameter_adjust_controller (
    .clk               (clk),
    .rst               (~control_rst_n),
    .key_increase      (parameter_adjust_enabled ? key1 : 1'b1),
    .key_decrease      (parameter_adjust_enabled ? key2 : 1'b1),
    .key_toggle        (parameter_adjust_enabled ? key3 : 1'b1),
    .popup_on_switch   (parameter_adjust_enabled),
    .sw1               (sw1),
    .sw2               (sw2),
    .sw3               (sw3),
    .sw4               (sw4),
    .brightness        (brightness_cfg),
    .contrast          (contrast_cfg),
    .volume            (volume_cfg),
    .ticker_speed      (ticker_speed_cfg),
    .auto_interval     (auto_interval_cfg),
    .wave_color        (wave_color_cfg),
    .music_on          (music_on_cfg),
    .display_active    (parameter_display_active),
    .selected_parameter(selected_parameter)
);

always @(posedge clk or negedge control_rst_n)
    if (!control_rst_n) begin
        music_target_ctrl_sync0 <= 3'd1;
        music_target_ctrl_sync1 <= 3'd1;
    end else begin
        music_target_ctrl_sync0 <= music_target_track;
        music_target_ctrl_sync1 <= music_target_ctrl_sync0;
    end

always @(posedge clk or negedge control_rst_n)
    if (!control_rst_n) begin
        ad_key_mask_sync0 <= 1'b0;
        ad_key_mask_sync1 <= 1'b0;
    end else begin
        ad_key_mask_sync0 <= ad_key_mask;
        ad_key_mask_sync1 <= ad_key_mask_sync0;
    end

always @(posedge clk or negedge control_rst_n) begin
    if (!control_rst_n) begin
        brightness_scaled <= 8'd255;
        contrast_scaled   <= 8'd128;
        volume_scaled     <= 8'd255;
    end else begin
        brightness_scaled <= percent_to_u8(brightness_cfg);
        contrast_scaled   <= percent_to_u8(contrast_cfg);
        volume_scaled     <= percent_to_u8(volume_cfg);
    end
end

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (sys_pll_lock),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft)
);

video_pll_720p_formal video_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (video_pll_lock),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk)
);

reset_sync u_control_reset (
    .clk        (clk),
    .ext_rst_n  (reset_release_n),
    .rst_n_sync (control_rst_n)
);

reset_sync u_sdcard_reset (
    .clk        (sd_card_clk),
    .ext_rst_n  (reset_release_n),
    .rst_n_sync (sdcard_rst_n)
);

reset_sync u_mem_reset (
    .clk        (ext_mem_clk),
    .ext_rst_n  (reset_release_n),
    .rst_n_sync (mem_rst_n)
);

reset_sync u_video_reset (
    .clk        (video_clk),
    .ext_rst_n  (reset_release_n),
    .rst_n_sync (video_rst_n)
);

sync_2ff u_sdram_init_sync (
    .clk        (sd_card_clk),
    .rst_n      (sdcard_rst_n),
    .async_in   (Sdr_init_done),
    .sync_out   (sdram_init_done_sd)
);

sync_2ff u_welcome_done_control_sync (
    .clk        (clk),
    .rst_n      (control_rst_n),
    .async_in   (welcome_done),
    .sync_out   (welcome_done_control)
);

sync_2ff u_welcome_done_sd_sync (
    .clk        (sd_card_clk),
    .rst_n      (sdcard_rst_n),
    .async_in   (welcome_done),
    .sync_out   (welcome_done_sd)
);

sync_2ff u_menu_state_control_sync0 (
    .clk        (clk),
    .rst_n      (control_rst_n),
    .async_in   (menu_state[0]),
    .sync_out   (menu_state_control[0])
);

sync_2ff u_menu_state_control_sync1 (
    .clk        (clk),
    .rst_n      (control_rst_n),
    .async_in   (menu_state[1]),
    .sync_out   (menu_state_control[1])
);

sync_2ff u_photo_asset_ready_video_sync (
    .clk        (video_clk),
    .rst_n      (video_rst_n),
    .async_in   (photo_asset_ready),
    .sync_out   (photo_asset_ready_video)
);

sync_2ff u_preload_settled_video_sync (
    .clk        (video_clk),
    .rst_n      (video_rst_n),
    .async_in   (preload_settled),
    .sync_out   (preload_settled_video)
);

sync_2ff u_photo_asset_boot_done_video_sync (
    .clk        (video_clk),
    .rst_n      (video_rst_n),
    .async_in   (photo_asset_boot_done),
    .sync_out   (photo_asset_boot_done_video)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or negedge mem_rst_n) begin
    if (!mem_rst_n)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

wire        submit_toggle;
wire [2:0]  submit_count;
wire [31:0] submit_items;
wire        link_order_pending, link_up_eth, link_led_rx, link_led_tx;
wire [2:0]  link_ad_index;
wire [10:0] link_kitchen_event;     // {front ticker line, order no}, link receive clock
wire        card_we;                // weather card RAM write (ticker clock, ticker address / data)
wire        card_vs, card_de;
wire [23:0] card_data;
wire        link_kitchen_seen;
// Kitchen events in the video clock: accepted (line 6) / ready (line 7).
(* async_reg = "true" *) reg [11:0] kitchen_event_video_sync0;
(* async_reg = "true" *) reg [11:0] kitchen_event_video_sync1;
reg  [10:0] kitchen_event_video;
reg         kitchen_event_armed;
reg         kitchen_chime;
reg  [1:0]  kitchen_chime_melody;
wire        ticker_wclk, ticker_we;
wire [9:0]  ticker_waddr;
wire [27:0] ticker_wdata;
// ===================== TF 多图扫描与缓存（双缓冲） =====================
sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (4'd8),
    .MAX_LOAD_RETRIES  (3),
    .AD_IDLE_MS        (20000)                // adverts after 20 s without a key
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (sdcard_app_rst),
    .key_next          (image_key_next),
    .key_prev          (image_key_prev),
    .key_auto          (image_key_auto),
    .key_confirm       (image_key_confirm),
    .key_back          (image_key_back),
    .auto_interval     (auto_interval_seconds),
    .state_code        (state_code),
    .bmp_width         (16'd1280),
    .bmp_height        (16'd720),
    .sold_out_mask     (sold_out_mask),
    .key_submit        (image_key_submit),
    .link_busy         (link_order_pending),
    .submit_toggle     (submit_toggle),
    .submit_count      (submit_count),
    .submit_items      (submit_items),
    .ad_enable         (welcome_done_sd),
    .idle_keys         ({key4, key3, key2, key1}),
    .ad_select         (link_ad_index),
    .ad_bank_mask      (ad_bank_mask),
    .ad_zoom_level     (ad_zoom_level),
    .ad_key_mask       (ad_key_mask),
    .display_valid     (display_valid),
    .image_index_status(image_index_status),
    .image_count_status(image_count_status),
    .loading           (loading),
    .auto_play_enabled (auto_play_enabled),
    .resident_status   (resident_status),
    .bank_owner0_status(bank_owner0_status),
    .bank_owner1_status(bank_owner1_status),
    .bank_owner2_status(bank_owner2_status),
    .bank_owner3_status(bank_owner3_status),
    .category_cache_status(category_cache_status),
    .startup_progress  (startup_progress),
    .preload_settled   (preload_settled),
    .debug_status      (),
    .thumbnail_mode    (thumbnail_mode),
    .thumbnail_focus_idx(thumbnail_focus_idx),
    .thumbnail_exit_toggle(thumbnail_exit_toggle),
    .menu_state        (menu_state),
    .dish_index        (dish_index),
    .category_index    (category_index),
    .photo_asset_ready (photo_asset_ready),
    .photo_asset_boot_done(photo_asset_boot_done),
    .photo_asset_write_mode(photo_asset_write_mode),
    .cart_qty0         (cart_qty0),
    .cart_qty1         (cart_qty1),
    .cart_qty2         (cart_qty2),
    .cart_qty3         (cart_qty3),
    .cart_total_count  (cart_total_count),
    .cart_total_price  (cart_total_price),
    .cart_order0       (cart_order0),
    .cart_order1       (cart_order1),
    .cart_order2       (cart_order2),
    .cart_order3       (cart_order3),
    .cart_distinct_count(cart_distinct_count),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso),
    .audio_sd_req      (audio_sd_req),
    .audio_sd_lba      (audio_sd_lba),
    .audio_sd_busy     (audio_sd_busy),
    .audio_sd_valid    (audio_sd_valid),
    .audio_sd_byte     (audio_sd_byte),
    .audio_sd_byte_index(audio_sd_byte_index),
    .audio_sd_done     (audio_sd_done),
    .audio_sd_error    (audio_sd_error),
    .audio_available   (audio_file_available),
    .audio_start_lba   (audio_file_start_lba),
    .audio_total_sectors(audio_file_total_sectors)
);

genvar seg_sync_index;
generate
    for (seg_sync_index = 0; seg_sync_index < 4; seg_sync_index = seg_sync_index + 1) begin : g_state_code_seg_sync
        sync_2ff u_state_code_seg_sync (
            .clk        (clk),
            .rst_n      (control_rst_n),
            .async_in   (state_code[seg_sync_index]),
            .sync_out   (state_code_seg_sync[seg_sync_index])
        );
    end
endgenerate

genvar parameter_sync_index;
generate
    for (parameter_sync_index = 0; parameter_sync_index < 8; parameter_sync_index = parameter_sync_index + 1) begin : g_parameter_video_sync
        sync_2ff u_brightness_sync (
            .clk        (video_clk),
            .rst_n      (video_rst_n),
            .async_in   (brightness_scaled[parameter_sync_index]),
            .sync_out   (brightness_sync1[parameter_sync_index])
        );
        sync_2ff u_contrast_sync (
            .clk        (video_clk),
            .rst_n      (video_rst_n),
            .async_in   (contrast_scaled[parameter_sync_index]),
            .sync_out   (contrast_sync1[parameter_sync_index])
        );
        sync_2ff u_volume_sync (
            .clk        (video_clk),
            .rst_n      (video_rst_n),
            .async_in   (volume_scaled[parameter_sync_index]),
            .sync_out   (volume_sync1[parameter_sync_index])
        );
    end
endgenerate

sync_2ff u_loading_seg_sync (
    .clk        (clk),
    .rst_n      (control_rst_n),
    .async_in   (loading),
    .sync_out   (loading_seg_sync)
);

seg_decoder seg_decoder_m0(
    .bin_data          (state_code_seg_sync),
    .seg_data          (seg_data_0)
);

seg_decoder seg_parameter_ones_decoder (
    .bin_data          (selected_display_ones),
    .seg_data          (seg_parameter_ones)
);

seg_decoder seg_parameter_tens_decoder (
    .bin_data          (selected_display_tens),
    .seg_data          (seg_parameter_tens)
);

seg_decoder seg_parameter_hundreds_decoder (
    .bin_data          (selected_display_hundreds),
    .seg_data          (seg_parameter_hundreds)
);

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (control_rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    // Digit 0: switch mode, or while adjusting the parameter letter
    // (B brightness, C contrast, S volume, t ticker, A auto-play interval,
    // P waveform colour, U music); otherwise the mode number on digits 0-1;
    // digits 5-7: the value being adjusted; digit 7 otherwise the picture
    // number. Digits 1-4 stay dark.
    .seg_data_0        (!welcome_done_control ? seg_startup_dash :
                        parameter_display_active ?
                        {1'b1, (selected_parameter == 3'd0) ? 7'b000_0000 :
                               (selected_parameter == 3'd1) ? 7'b100_0110 :
                               (selected_parameter == 3'd2) ? 7'b001_0010 :
                               (selected_parameter == 3'd3) ? 7'b000_0111 :
                               (selected_parameter == 3'd4) ? 7'b000_1000 :
                               (selected_parameter == 3'd5) ? 7'b000_1100 :
                               7'b100_0001} :
                        {1'b1,seg_switch_msb}),
    .seg_data_1        (!welcome_done_control ? seg_startup_dash :
                        parameter_display_active ?
                        {1'b1,7'b1111_111} : {1'b1,seg_switch_lsb}),
    .seg_data_2        (!welcome_done_control ? seg_startup_dash : {1'b1,7'b1111_111}),
    .seg_data_3        (!welcome_done_control ? seg_startup_dash : {1'b1,7'b1111_111}),
    .seg_data_4        (!welcome_done_control ? seg_startup_dash : {1'b1,7'b1111_111}),
    .seg_data_5        (!welcome_done_control ? seg_startup_dash :
                        parameter_display_active && selected_display_value >= 8'd100 ?
                        {1'b1,seg_parameter_hundreds} : {1'b1,7'b1111_111}),
    .seg_data_6        (!welcome_done_control ? seg_startup_dash :
                        parameter_display_active && selected_display_value >= 8'd10 ?
                        {1'b1,seg_parameter_tens} : {1'b1,7'b1111_111}),
    .seg_data_7        (!welcome_done_control ? seg_startup_dash :
                        parameter_display_active ?
                        {1'b1,seg_parameter_ones} : {1'b1,seg_data_0})
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_720p video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (~video_rst_n),
    .read_req          (video_read_req_raw),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

// Startup keeps the video reader off SDRAM so TF preload writes get the full
// bandwidth. Release it with the same condition that lets the welcome screen
// leave: a complete preload, or a settled preload with a displayable image.
// It stays released afterwards so later detail/reload writes cannot black out
// the main screen.
reg video_read_released;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n)
        video_read_released <= 1'b0;
    else if ((resident_sync1 == 4'hf && photo_asset_boot_done_video) ||
             (preload_settled_video && resident_sync1 != 4'h0))
        video_read_released <= 1'b1;
end

assign video_read_req = video_read_req_raw && video_read_released;

// Commit display selection only at the frame boundary in the video clock domain.
assign frame_start_video = vs_0_d && !vs_0;

// ===================== Advert player =====================
// A poster bank on screen is an advert: the status OSD and the waveform are
// hidden. Entering, leaving or changing a poster (a new selection or a new
// size, rendered into the other poster bank) fades in from the centre.
(* async_reg = "true" *) reg [3:0] ad_bank_sync0;
(* async_reg = "true" *) reg [3:0] ad_bank_sync1;
wire       ad_view_frame = ad_bank_sync1[disp_buf_idx_frame];
wire       ad_fade_request = disp_buf_idx_sync1 != disp_buf_idx_frame &&
                             (ad_bank_sync1[disp_buf_idx_sync1] || ad_bank_sync1[disp_buf_idx_frame]);

always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        ad_bank_sync0 <= 4'd0;
        ad_bank_sync1 <= 4'd0;
    end else begin
        ad_bank_sync0 <= ad_bank_mask;
        ad_bank_sync1 <= ad_bank_sync0;
    end
end

thumbnail_transition_control u_thumbnail_transition_control (
    .clk                    (video_clk),
    .rst_n                  (video_rst_n),
    .frame_start            (frame_start_video),
    .thumbnail_mode         (thumbnail_mode),
    .thumbnail_exit_toggle  (thumbnail_exit_toggle),
    .transition_busy        (transition_busy),
    .transition_level       (transition_level),
    .thumbnail_mode_frame   (thumbnail_mode_frame),
    .fade_request           (thumbnail_fade_pending),
    .direct_request         (thumbnail_direct_pending)
);

always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        vs_0_d              <= 1'b0;
        disp_buf_idx_sync0  <= 2'd0;
        disp_buf_idx_sync1  <= 2'd0;
        image_index_sync0   <= 3'd0;
        image_index_sync1   <= 3'd0;
        image_index_frame   <= 3'd0;
        image_count_sync0   <= 4'd0;
        image_count_sync1   <= 4'd0;
        thumbnail_focus_sync0 <= 3'd0;
        thumbnail_focus_sync1 <= 3'd0;
        thumbnail_focus_frame <= 3'd0;
        menu_state_sync0     <= 2'd0;
        menu_state_sync1     <= 2'd0;
        dish_index_sync0     <= 2'd0;
        dish_index_sync1     <= 2'd0;
        menu_state_frame     <= 2'd0;
        dish_index_frame     <= 2'd0;
        category_index_sync0 <= 2'd0;
        category_index_sync1 <= 2'd0;
        category_index_frame <= 2'd0;
        cart_qty_sync0       <= 16'd0;
        cart_qty_sync1       <= 16'd0;
        cart_total_count_sync0 <= 6'd0;
        cart_total_count_sync1 <= 6'd0;
        cart_total_price_sync0 <= 10'd0;
        cart_total_price_sync1 <= 10'd0;
        cart_order_sync0       <= 16'd0;
        cart_order_sync1       <= 16'd0;
        cart_distinct_count_sync0 <= 3'd0;
        cart_distinct_count_sync1 <= 3'd0;
        cart_order_frame       <= 16'd0;
        cart_distinct_count_frame <= 3'd0;
        display_valid_sync0 <= 1'b0;
        display_valid_sync1 <= 1'b0;
        display_valid_frame <= 1'b0;
        auto_play_sync0     <= 1'b0;
        auto_play_sync1     <= 1'b0;
        loading_video_sync0 <= 1'b0;
        loading_video_sync1 <= 1'b0;
        resident_sync0      <= 4'b0000;
        resident_sync1      <= 4'b0000;
        bank_owner0_sync0   <= 3'd0;
        bank_owner0_sync1   <= 3'd0;
        bank_owner1_sync0   <= 3'd0;
        bank_owner1_sync1   <= 3'd0;
        bank_owner2_sync0   <= 3'd0;
        bank_owner2_sync1   <= 3'd0;
        bank_owner3_sync0   <= 3'd0;
        bank_owner3_sync1   <= 3'd0;
        category_cache_sync0 <= 8'd0;
        category_cache_sync1 <= 8'd0;
        startup_progress_sync0 <= 8'd0;
        startup_progress_sync1 <= 8'd0;
        parameter_popup_active_sync0 <= 1'b0;
        parameter_popup_active_sync1 <= 1'b0;
        parameter_popup_kind_sync0 <= 3'd0;
        parameter_popup_kind_sync1 <= 3'd0;
        parameter_popup_ones_sync0 <= 4'd0;
        parameter_popup_ones_sync1 <= 4'd0;
        parameter_popup_tens_sync0 <= 4'd0;
        parameter_popup_tens_sync1 <= 4'd0;
        parameter_popup_hundreds_sync0 <= 4'd0;
        parameter_popup_hundreds_sync1 <= 4'd0;
        parameter_popup_digit_count_sync0 <= 2'd1;
        parameter_popup_digit_count_sync1 <= 2'd1;
        parameter_popup_fill_end_sync0 <= 11'd440;
        parameter_popup_fill_end_sync1 <= 11'd440;
        brightness_frame     <= 8'd255;
        contrast_frame       <= 8'd128;
    end else begin
        vs_0_d              <= vs_0;
        disp_buf_idx_sync0  <= disp_buf_idx;
        disp_buf_idx_sync1  <= disp_buf_idx_sync0;
        image_index_sync0   <= image_index_status;
        image_index_sync1   <= image_index_sync0;
        image_count_sync0   <= image_count_status;
        image_count_sync1   <= image_count_sync0;
        thumbnail_focus_sync0 <= thumbnail_focus_idx;
        thumbnail_focus_sync1 <= thumbnail_focus_sync0;
        menu_state_sync0     <= menu_state;
        menu_state_sync1     <= menu_state_sync0;
        dish_index_sync0     <= dish_index;
        dish_index_sync1     <= dish_index_sync0;
        category_index_sync0 <= category_index;
        category_index_sync1 <= category_index_sync0;
        cart_qty_sync0       <= {cart_qty3, cart_qty2, cart_qty1, cart_qty0};
        cart_qty_sync1       <= cart_qty_sync0;
        cart_total_count_sync0 <= cart_total_count;
        cart_total_count_sync1 <= cart_total_count_sync0;
        cart_total_price_sync0 <= cart_total_price;
        cart_total_price_sync1 <= cart_total_price_sync0;
        cart_order_sync0       <= {cart_order3, cart_order2, cart_order1, cart_order0};
        cart_order_sync1       <= cart_order_sync0;
        cart_distinct_count_sync0 <= cart_distinct_count;
        cart_distinct_count_sync1 <= cart_distinct_count_sync0;
        display_valid_sync0 <= display_valid;
        display_valid_sync1 <= display_valid_sync0;
        auto_play_sync0     <= auto_play_enabled;
        auto_play_sync1     <= auto_play_sync0;
        loading_video_sync0 <= loading;
        loading_video_sync1 <= loading_video_sync0;
        resident_sync0      <= resident_status;
        resident_sync1      <= resident_sync0;
        bank_owner0_sync0   <= bank_owner0_status;
        bank_owner0_sync1   <= bank_owner0_sync0;
        bank_owner1_sync0   <= bank_owner1_status;
        bank_owner1_sync1   <= bank_owner1_sync0;
        bank_owner2_sync0   <= bank_owner2_status;
        bank_owner2_sync1   <= bank_owner2_sync0;
        bank_owner3_sync0   <= bank_owner3_status;
        bank_owner3_sync1   <= bank_owner3_sync0;
        category_cache_sync0 <= category_cache_status;
        category_cache_sync1 <= category_cache_sync0;
        startup_progress_sync0 <= startup_progress;
        startup_progress_sync1 <= startup_progress_sync0;
        parameter_popup_active_sync0 <= parameter_display_active;
        parameter_popup_active_sync1 <= parameter_popup_active_sync0;
        parameter_popup_kind_sync0 <= selected_parameter;
        parameter_popup_kind_sync1 <= parameter_popup_kind_sync0;
        parameter_popup_ones_sync0 <= selected_display_ones;
        parameter_popup_ones_sync1 <= parameter_popup_ones_sync0;
        parameter_popup_tens_sync0 <= selected_display_tens;
        parameter_popup_tens_sync1 <= parameter_popup_tens_sync0;
        parameter_popup_hundreds_sync0 <= selected_display_hundreds;
        parameter_popup_hundreds_sync1 <= parameter_popup_hundreds_sync0;
        parameter_popup_digit_count_sync0 <= selected_display_digit_count;
        parameter_popup_digit_count_sync1 <= parameter_popup_digit_count_sync0;
        parameter_popup_fill_end_sync0 <= selected_popup_fill_end;
        parameter_popup_fill_end_sync1 <= parameter_popup_fill_end_sync0;
        if (frame_start_video) begin
            display_valid_frame <= display_valid_sync1;
            thumbnail_focus_frame <= thumbnail_focus_sync1;
            menu_state_frame     <= menu_state_sync1;
            dish_index_frame     <= dish_index_sync1;
            category_index_frame <= category_index_sync1;
            image_index_frame     <= image_index_sync1;
            brightness_frame     <= brightness_sync1;
            contrast_frame       <= contrast_sync1;
            cart_order_frame     <= cart_order_sync1;
            cart_distinct_count_frame <= cart_distinct_count_sync1;
        end
    end
end

assign brightness_video = brightness_frame;
assign contrast_video   = contrast_frame;
assign volume_video     = volume_sync1;

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (~video_rst_n),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .photo_mode        (photo_mode_frame),
    .read_underflow    (video_read_underflow),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
assign vout_data_base = display_valid_frame ? vout_data_raw : 24'd0;

thumbnail_overlay_720p u_thumbnail_overlay_720p (
    .clk              (video_clk),
    .rst_n            (video_rst_n),
    .vs               (vs),
    .de               (de),
    .rgb_in           (vout_data_base),
    .thumbnail_mode  (thumbnail_mode_frame),
    .focus_index     (thumbnail_focus_frame),
    .image_complete  (resident_sync1),
    .bank_owner0     (bank_owner0_sync1),
    .bank_owner1     (bank_owner1_sync1),
    .bank_owner2     (bank_owner2_sync1),
    .bank_owner3     (bank_owner3_sync1),
    .category_cache_status(category_cache_sync1),
    .vs_out          (thumbnail_vs),
    .de_out          (thumbnail_de),
    .rgb_out         (thumbnail_data)
);

video_transition_720p u_video_transition_720p (
    .clk             (video_clk),
    .rst_n           (video_rst_n),
    .frame_start     (frame_start_video),
    .player_active   (display_valid_frame),
    .requested_index (disp_buf_idx_sync1),
    .auto_enabled    (auto_play_sync1),
    .fade_request    (thumbnail_fade_pending || ad_fade_request),
    .direct_request  (thumbnail_direct_pending),
    .vs              (thumbnail_vs),
    .de              (thumbnail_de),
    .rgb_in          (thumbnail_data),
    .active_index    (disp_buf_idx_frame),
    .vs_out          (transition_vs),
    .de_out          (transition_de),
    .rgb_out         (transition_data),
    .transition_busy (transition_busy),
    .fade_active     (),
    .wipe_active     (),
    .transition_level(transition_level),
    .transition_kind ()
);

brightness_contrast_adjust u_brightness_contrast_adjust (
    .clk        (video_clk),
    .rst_n      (video_rst_n),
    .in_vs      (order_transition_vs),
    .in_de      (order_transition_de),
    .rgb_in     (order_transition_data),
    .brightness (brightness_video),
    .contrast   (contrast_video),
    .out_vs     (adjusted_vs),
    .out_de     (adjusted_de),
    .rgb_out    (adjusted_data)
);

assign auto_progress_on = auto_play_sync1 && (resident_sync1 == 4'hf);

auto_elapsed_timer #(
    .CLOCK_HZ         (74_242_424)
) u_auto_elapsed_timer (
    .clk              (video_clk),
    .rst_n            (video_rst_n),
    .auto_enabled     (auto_progress_on),
    .image_index      (image_index_frame),
    .max_seconds      (interval_video),
    .seconds_digit    (auto_elapsed_seconds),
    .tenths_digit     (auto_elapsed_tenths),
    .hundredths_digit (auto_elapsed_hundredths),
    .progress_px      (auto_progress_px)
);

// Waveform colours of switch mode 110, in the order of the popup names
// 青色 蓝色 紫色 粉色 红色 橙色 黄色 绿色 白色 金色.
function [23:0] palette;
    input [3:0] index;
    begin
        case (index)
            4'd2:  palette = 24'h60a5fa;
            4'd3:  palette = 24'hb388ff;
            4'd4:  palette = 24'hf472b6;
            4'd5:  palette = 24'hf43f5e;
            4'd6:  palette = 24'hfb923c;
            4'd7:  palette = 24'hfde047;
            4'd8:  palette = 24'h4ade80;
            4'd9:  palette = 24'hf8fafc;
            4'd10: palette = 24'hd4a937;
            default: palette = 24'h5eead4;
        endcase
    end
endfunction

always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        sold_out_video_sync0 <= 16'd0;
        sold_out_video_sync1 <= 16'd0;
        ticker_speed_video_sync0 <= 4'd5;
        ticker_speed_video_sync1 <= 4'd5;
        interval_video_sync0 <= 4'd8;
        interval_video_sync1 <= 4'd8;
        interval_video <= 4'd8;
        wave_color_video_sync0 <= 4'd1;
        wave_color_video_sync1 <= 4'd1;
        accent_rgb <= 24'h5eead4;
    end else begin
        sold_out_video_sync0 <= sold_out_mask;
        sold_out_video_sync1 <= sold_out_video_sync0;
        ticker_speed_video_sync0 <= ticker_speed_cfg;
        ticker_speed_video_sync1 <= ticker_speed_video_sync0;
        interval_video_sync0 <= auto_interval_seconds;
        interval_video_sync1 <= interval_video_sync0;
        if (interval_video_sync0 == interval_video_sync1)
            interval_video <= interval_video_sync1;
        wave_color_video_sync0 <= wave_color_cfg;
        wave_color_video_sync1 <= wave_color_video_sync0;
        if (wave_color_video_sync0 == wave_color_video_sync1)
            accent_rgb <= palette(wave_color_video_sync1);
    end
end

// ===================== Board link to the kitchen =====================
// (its wires are declared above the TF loader, which uses them first)
wire [2:0] card_kind_link;
front_link u_front_link (
    .clk50         (clk),
    .rst_n         (reset_release_n),
    .rgmii_txd     (phy1_rgmii_tx_data),
    .rgmii_tx_ctl  (phy1_rgmii_tx_ctl),
    .rgmii_txc     (phy1_rgmii_tx_clk),
    .rgmii_rxd     (phy1_rgmii_rx_data),
    .rgmii_rx_ctl  (phy1_rgmii_rx_ctl),
    .rgmii_rxc     (phy1_rgmii_rx_clk),
    .submit_toggle (submit_toggle),
    .submit_count  (submit_count),
    .submit_items  (submit_items),
    .order_pending (link_order_pending),
    .front_mode    (selected_switch),
    .sold_mask     (sold_out_mask),
    .ad_index      (link_ad_index),
    .kitchen_event (link_kitchen_event),
    .kitchen_seen  (link_kitchen_seen),
    .link_up       (link_up_eth),
    .ticker_clk    (ticker_wclk),
    .ticker_we     (ticker_we),
    .ticker_addr   (ticker_waddr),
    .ticker_data   (ticker_wdata),
    .card_we       (card_we),
    .card_kind     (card_kind_link),
    .led_rx        (link_led_rx),
    .led_tx        (link_led_tx)
);
assign led = {link_order_pending, link_led_tx, link_led_rx, link_up_eth};

// Weather card colour: fixed per weather (not the accent colour). The kind
// changes rarely; two flops and two equal samples bring it to the video clock.
(* async_reg = "true" *) reg [2:0] card_kind_video_sync0;
(* async_reg = "true" *) reg [2:0] card_kind_video_sync1;
reg  [23:0] weather_rgb;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        card_kind_video_sync0 <= 3'd0;
        card_kind_video_sync1 <= 3'd0;
        weather_rgb <= 24'hffc94d;
    end else begin
        card_kind_video_sync0 <= card_kind_link;
        card_kind_video_sync1 <= card_kind_video_sync0;
        if (card_kind_video_sync0 == card_kind_video_sync1)
            case (card_kind_video_sync1)
                3'd1:    weather_rgb <= 24'hffe08a;     // 多云 pale gold
                3'd2:    weather_rgb <= 24'hb4c0cc;     // 阴天 grey
                3'd3:    weather_rgb <= 24'h7cc6ff;     // 小雨 light blue
                3'd4:    weather_rgb <= 24'h4f9cff;     // 大雨 blue
                3'd5:    weather_rgb <= 24'hc4e8ff;     // 雪天 ice blue
                default: weather_rgb <= 24'hffc94d;     // 晴天 sun gold
            endcase
    end
end

status_osd_720p u_status_osd_720p (
    .clk             (video_clk),
    .rst_n           (video_rst_n),
    .enable          (display_valid_frame && !thumbnail_mode_frame &&
                      menu_state_frame == 2'd0 && !ad_view_frame),
    .vs              (transition_vs),
    .de              (transition_de),
    .rgb_in          (transition_data),
    .image_index     (image_index_frame),
    .image_count     (image_count_sync1),
    .auto_enabled    (auto_play_sync1),
    .loading         (loading_video_sync1),
    .resident_mask   (resident_sync1),
    .elapsed_seconds (auto_elapsed_seconds),
    .elapsed_tenths  (auto_elapsed_tenths),
    .elapsed_hundredths(auto_elapsed_hundredths),
    .brightness      (brightness_video),
    .contrast        (contrast_video),
    .volume          (volume_video),
    .ticker_speed    (ticker_speed_video_sync1),
    .ticker_wclk     (ticker_wclk),
    .ticker_we       (ticker_we),
    .ticker_waddr    (ticker_waddr),
    .ticker_wdata    (ticker_wdata),
    .vs_out          (osd_vs),
    .de_out          (osd_de),
    .rgb_out         (vout_data),
    .osd_active      ()
);

// The weather card the kitchen sets, shown at the bottom of every advert.
weather_card_720p u_weather_card_720p (
    .clk             (video_clk),
    .rst_n           (video_rst_n),
    .enable          (display_valid_frame && ad_view_frame && !thumbnail_mode_frame),
    .vs              (osd_vs),
    .de              (osd_de),
    .rgb_in          (vout_data),
    .weather_rgb     (weather_rgb),
    .card_wclk       (ticker_wclk),
    .card_we         (card_we),
    .card_waddr      (ticker_waddr),
    .card_wdata      (ticker_wdata),
    .vs_out          (card_vs),
    .de_out          (card_de),
    .rgb_out         (card_data)
);

always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        key1_video_sync0 <= 1'b1;
        key1_video_sync1 <= 1'b1;
        key2_video_sync0 <= 1'b1;
        key2_video_sync1 <= 1'b1;
        key3_video_sync0 <= 1'b1;
        key3_video_sync1 <= 1'b1;
        key4_video_sync0 <= 1'b1;
        key4_video_sync1 <= 1'b1;
        waveform_pcm_sample <= 16'sd0;
        waveform_pcm_valid <= 1'b0;
    end else begin
        key1_video_sync0 <= key1;
        key1_video_sync1 <= key1_video_sync0;
        key2_video_sync0 <= key2;
        key2_video_sync1 <= key2_video_sync0;
        key3_video_sync0 <= key3;
        key3_video_sync1 <= key3_video_sync0;
        key4_video_sync0 <= key4;
        key4_video_sync1 <= key4_video_sync0;
        waveform_pcm_sample <= $signed(audio_left_data) >>> 7;
        waveform_pcm_valid <= audio_valid;
    end
end

promax_audio_waveform #(
    .WAVE_X          (0),
    .WAVE_Y          (616),
    .WAVE_WIDTH      (1280),
    .WAVE_HEIGHT     (64),
    .SAMPLE_COUNT    (64),
    .DECIMATE        (12)
) u_promax_audio_waveform (
    .clk             (video_clk),
    .rst_n           (video_rst_n),
    .vs              (card_vs),
    .de              (card_de),
    .rgb_in          (card_data),
    .enable          (display_valid_frame && !thumbnail_mode_frame &&
                      menu_state_frame == 2'd0 && !ad_view_frame),
    .pcm_tap_valid   (waveform_pcm_valid),
    .pcm_tap_left    (waveform_pcm_sample),
    .accent_rgb      (accent_rgb),
    .progress_on     (auto_progress_on),
    .progress_px     (auto_progress_px),
    .vs_out          (waveform_vs),
    .de_out          (waveform_de),
    .rgb_out         (waveform_data),
    .waveform_active ()
);

order_detail_ui_720p u_order_detail_ui_720p (
    .clk             (video_clk),
    .rst_n           (video_rst_n),
    .vs              (waveform_vs),
    .de              (waveform_de),
    .rgb_in          (waveform_data),
    .menu_state      (order_active_menu_state),
    .dish_index      (order_active_dish_index),
    .category_index  (category_index_frame),
    .photo_ready     (photo_asset_ready_video),
    .cart_qty0       (cart_qty_sync1[3:0]),
    .cart_qty1       (cart_qty_sync1[7:4]),
    .cart_qty2       (cart_qty_sync1[11:8]),
    .cart_qty3       (cart_qty_sync1[15:12]),
    .cart_total_count(cart_total_count_sync1),
    .cart_total_price(cart_total_price_sync1),
    .cart_order0     (cart_order_frame[3:0]),
    .cart_order1     (cart_order_frame[7:4]),
    .cart_order2     (cart_order_frame[11:8]),
    .cart_order3     (cart_order_frame[15:12]),
    .cart_distinct_count(cart_distinct_count_frame),
    .parameter_popup_active(parameter_popup_active_sync1),
    .parameter_popup_kind(parameter_popup_kind_sync1),
    .parameter_popup_ones(parameter_popup_ones_sync1),
    .parameter_popup_tens(parameter_popup_tens_sync1),
    .parameter_popup_hundreds(parameter_popup_hundreds_sync1),
    .parameter_popup_digit_count(parameter_popup_digit_count_sync1),
    .parameter_popup_fill_end(parameter_popup_fill_end_sync1),
    .accent_rgb      (accent_rgb),
    .sold_out_mask   (sold_out_video_sync1),
    .vs_out          (order_menu_vs),
    .de_out          (order_menu_de),
    .rgb_out         (order_menu_data)
);

order_ui_transition_720p u_order_ui_transition_720p (
    .clk             (video_clk),
    .rst_n           (video_rst_n),
    .frame_start     (frame_start_video),
    .requested_menu  (menu_state_frame),
    .requested_dish  (dish_index_frame),
    .vs              (order_menu_vs),
    .de              (order_menu_de),
    .rgb_in          (order_menu_data),
    .active_menu     (order_active_menu_state),
    .active_dish     (order_active_dish_index),
    .vs_out          (order_transition_vs),
    .de_out          (order_transition_de),
    .rgb_out         (order_transition_data)
);

startup_welcome_720p u_startup_welcome_720p (
    .clk             (video_clk),
    .rst_n           (video_rst_n),
    .vs              (adjusted_vs),
    .de              (adjusted_de),
    .rgb_in          (adjusted_data),
    .resident_mask   (resident_sync1),
    .load_progress   (startup_progress_sync1),
    .asset_boot_done (photo_asset_boot_done_video),
    .preload_settled (preload_settled_video),
    .vs_out          (welcome_vs),
    .de_out          (welcome_de),
    .rgb_out         (welcome_data),
    .welcome_active  (welcome_active),
    .welcome_done    (welcome_done),
    .chime_start     (welcome_chime_start),
    .chime_exit      (welcome_chime_exit)
);

frame_read_write #(
    .BURST_SIZE       (128),
    .PACK_RGB565      (1),
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (1280),
    .FRAME_HEIGHT     (720)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (~mem_rst_n),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (photo_mode_frame ? photo_read_addr : BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (BUF2_ADDR),
    .read_addr_3       (BUF3_ADDR),
    .read_addr_index   (photo_mode_frame ? 2'd0 : disp_buf_idx_frame),
    .read_len          (photo_mode_frame ? PHOTO_WORDS : thumbnail_mode_frame ?
                        FRAME_PIXELS[ADDR_BITS-1:0] :
                        FRAME_WORDS[ADDR_BITS-1:0]),
    .thumbnail_mode    (thumbnail_mode_frame),
    .read_en           (video_read_en),
    .read_data         (video_read_data),
    .read_underflow    (video_read_underflow),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (BUF2_ADDR),
    .write_addr_3      (BUF3_ADDR),
    .write_addr_index  (write_buf_idx),
    .write_asset_mode  (photo_asset_write_mode),
    .write_asset_addr  (PHOTO_BASE_ADDR),
    .write_len         (photo_asset_write_mode ? PHOTO_ASSET_WORDS : FRAME_WORDS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (~mem_rst_n),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// The track and on / off state chosen by music_scene_fader (video clock) as
// the player's index. The music starts once the main screen is up and then
// keeps playing: adverts and category loads that evict a bank do not stop it.
always @(posedge sd_card_clk or posedge sdcard_app_rst) begin
    if (sdcard_app_rst) begin
        audio_track_sync0 <= 4'd0;
        audio_track_sync1 <= 4'd0;
        audio_track_request <= 3'd0;
        audio_music_on <= 1'b1;
        audio_music_started <= 1'b0;
    end else begin
        audio_track_sync0 <= {music_play_on, music_play_track - 3'd1};
        audio_track_sync1 <= audio_track_sync0;
        if (audio_track_sync0 == audio_track_sync1) begin
            audio_track_request <= audio_track_sync1[2:0];
            audio_music_on <= audio_track_sync1[3];
        end
        if (display_valid && welcome_done_sd &&
            ((resident_status == 4'hf) || preload_settled))
            audio_music_started <= 1'b1;
    end
end

audio_track_control u_audio_track_control (
    .clk                 (sd_card_clk),
    .rst                 (sdcard_app_rst),
    .audio_available     (audio_file_available),
    .display_ready       (audio_music_started && audio_music_on),
    .requested_track     (audio_track_request),
    .file_start_lba      (audio_file_start_lba),
    .file_total_sectors  (audio_file_total_sectors),
    .play_enable         (audio_play_enable),
    .active_track        (audio_track_active),
    .track_start_lba     (audio_track_start_lba),
    .track_total_sectors (audio_track_total_sectors)
);

always @(posedge sd_card_clk or posedge sdcard_app_rst) begin
    if (sdcard_app_rst) begin
        audio_track_start_lba_reg <= 32'd0;
        audio_track_total_sectors_reg <= 32'd0;
    end else begin
        audio_track_start_lba_reg <= audio_track_start_lba;
        audio_track_total_sectors_reg <= audio_track_total_sectors;
    end
end

always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        audio_sample_accumulator <= 32'd0;
        audio_sample_tick <= 1'b0;
    end else begin
        audio_sample_tick <= 1'b0;
        if (audio_sample_accumulator >= (32'd74_242_424 - 32'd48_000)) begin
            audio_sample_accumulator <= audio_sample_accumulator + 32'd48_000 - 32'd74_242_424;
            audio_sample_tick <= 1'b1;
        end else begin
            audio_sample_accumulator <= audio_sample_accumulator + 32'd48_000;
        end
    end
end

// 2048-sample FIFO (43 ms): a sector lasts 5.3 ms and the SD arbiter serves
// the music between the image sectors.
wav_stream_player #(
    .ADDR_WIDTH     (11)
) u_wav_stream_player (
    .wr_clk         (sd_card_clk),
    .wr_rst_n       (sdcard_rst_n),
    .play_enable    (audio_play_enable),
    .start_lba      (audio_track_start_lba_reg),
    .total_sectors  (audio_track_total_sectors_reg),
    .track          (audio_track_active),
    .sd_req         (audio_sd_req),
    .sd_lba         (audio_sd_lba),
    .sd_busy        (audio_sd_busy),
    .sd_valid       (audio_sd_valid),
    .sd_byte        (audio_sd_byte),
    .sd_byte_index  (audio_sd_byte_index),
    .sd_done        (audio_sd_done),
    .sd_error       (audio_sd_error),
    .rd_clk         (video_clk),
    .rd_rst_n       (video_rst_n),
    .sample_tick    (audio_sample_tick),
    .sample_out     (wav_sample_out),
    .sample_valid   (wav_sample_valid),
    .sample_ready   (1'b1),
    .sample_counter (),
    .stream_active  (wav_stream_active),
    .stream_end     (wav_stream_end),
    .buffer_low     (wav_buffer_low)
);

// A front order accepted or ready in the kitchen (its front ticker line
// changes to 6 or 7, or the order number changes) plays a chime. The first
// kitchen status after the link comes up only sets the reference.
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        kitchen_event_video_sync0 <= 12'd0;
        kitchen_event_video_sync1 <= 12'd0;
        kitchen_event_video <= 11'd0;
        kitchen_event_armed <= 1'b0;
        kitchen_chime <= 1'b0;
        kitchen_chime_melody <= 2'd1;
    end else begin
        kitchen_event_video_sync0 <= {link_kitchen_seen, link_kitchen_event};
        kitchen_event_video_sync1 <= kitchen_event_video_sync0;
        kitchen_chime <= 1'b0;
        if (kitchen_event_video_sync0 == kitchen_event_video_sync1 && kitchen_event_video_sync1[11]) begin
            kitchen_event_video <= kitchen_event_video_sync1[10:0];
            kitchen_event_armed <= 1'b1;
            if (kitchen_event_armed && kitchen_event_video_sync1[10:0] != kitchen_event_video &&
                kitchen_event_video_sync1[10:9] == 2'b11) begin
                kitchen_chime <= welcome_done;
                kitchen_chime_melody <= kitchen_event_video_sync1[8] ? 2'd3 : 2'd1;
            end
        end
    end
end

// The startup animation is silent; two transition sounds mark the iris into
// the welcome scene and the iris into the main screen. Kitchen events use
// the same player.
transition_chime u_transition_chime (
    .clk          (video_clk),
    .rst_n        (video_rst_n),
    .trigger      (welcome_chime_start || kitchen_chime),
    .melody       (kitchen_chime ? kitchen_chime_melody : welcome_chime_exit ? 2'd2 : 2'd0),
    .sample_tick  (audio_sample_tick),
    .active       (transition_chime_active),
    .sample_left  (transition_chime_left),
    .sample_right (transition_chime_right)
);

key_press_debounce #(
    .CLK_FREQ_HZ (74_242_424),
    .DEBOUNCE_MS (10)
) u_key1_click_debounce (
    .clk              (video_clk),
    .rst              (~video_rst_n),
    .button_in        (key1_video_sync1),
    .press_pulse      (key1_click_pulse),
    .button_stable_out()
);

key_press_debounce #(
    .CLK_FREQ_HZ (74_242_424),
    .DEBOUNCE_MS (10)
) u_key2_click_debounce (
    .clk              (video_clk),
    .rst              (~video_rst_n),
    .button_in        (key2_video_sync1),
    .press_pulse      (key2_click_pulse),
    .button_stable_out()
);

key_press_debounce #(
    .CLK_FREQ_HZ (74_242_424),
    .DEBOUNCE_MS (10)
) u_key3_click_debounce (
    .clk              (video_clk),
    .rst              (~video_rst_n),
    .button_in        (key3_video_sync1),
    .press_pulse      (key3_click_pulse),
    .button_stable_out()
);

key_press_debounce #(
    .CLK_FREQ_HZ (74_242_424),
    .DEBOUNCE_MS (10)
) u_key4_click_debounce (
    .clk              (video_clk),
    .rst              (~video_rst_n),
    .button_in        (key4_video_sync1),
    .press_pulse      (key4_click_pulse),
    .button_stable_out()
);

assign key_click_trigger = welcome_done && (key1_click_pulse || key2_click_pulse ||
                           key3_click_pulse || key4_click_pulse);
assign key_click_code = key1_click_pulse ? 2'd0 :
                        key2_click_pulse ? 2'd1 :
                        key3_click_pulse ? 2'd2 : 2'd3;

key_click_sound u_key_click_sound (
    .clk          (video_clk),
    .rst_n        (video_rst_n),
    .trigger      (key_click_trigger),
    .key_code     (key_click_code),
    .sample_tick  (audio_sample_tick),
    .active       (key_click_active),
    .sample_left  (key_click_left),
    .sample_right (key_click_right)
);

// The music plays on through picture changes: the volume alone scales it.
assign audio_effective_gain = volume_video;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n)
        audio_effective_gain_q <= 8'd0;
    else
        audio_effective_gain_q <= audio_effective_gain;
end
// Track of each screen: categories 主食 小吃 饮品 套餐 -> 1-4 (the detail and
// order pages keep their category's track), adverts -> 5, thumbnails -> 6.
// It changes at the frame where the new picture starts its transition.
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        music_want_sync0 <= 1'b1;
        music_want_sync1 <= 1'b1;
        music_target_track <= 3'd1;
        wav_sample_valid_d1 <= 1'b0;
        wav_sample_valid_d2 <= 1'b0;
    end else begin
        music_want_sync0 <= music_on_cfg;
        music_want_sync1 <= music_want_sync0;
        wav_sample_valid_d1 <= wav_sample_valid;
        wav_sample_valid_d2 <= wav_sample_valid_d1;
        if (frame_start_video)
            music_target_track <= ad_view_frame ? 3'd5 :
                                  thumbnail_mode_frame ? 3'd6 :
                                  (menu_state_frame == 2'd0) ? {1'b0, image_index_frame[1:0]} + 3'd1 :
                                  {1'b0, category_index_frame} + 3'd1;
    end
end

music_scene_fader u_music_scene_fader (
    .clk           (video_clk),
    .rst_n         (video_rst_n),
    .sample_tick   (audio_sample_tick),
    .want_on       (music_want_sync1),
    .target_track  (music_target_track),
    .stream_active (wav_stream_active),
    .sample_in     (wav_sample_out),
    .play_on       (music_play_on),
    .play_track    (music_play_track),
    .gain          (music_gain),
    .sample_out    (music_faded_sample)
);

// Music (mono, half scale, faded), transition sounds and key clicks are summed.
assign audio_base_left = wav_stream_active ? {{1{music_faded_sample[15]}}, music_faded_sample, 7'd0} : 24'sd0;
assign audio_base_right = audio_base_left;
assign audio_mix_left = $signed({audio_base_left[23], audio_base_left}) +
                        $signed({transition_chime_left[23], transition_chime_left}) +
                        $signed({key_click_left[23], key_click_left});
assign audio_mix_right = $signed({audio_base_right[23], audio_base_right}) +
                         $signed({transition_chime_right[23], transition_chime_right}) +
                         $signed({key_click_right[23], key_click_right});
assign audio_source_left = audio_source_left_q;
assign audio_source_right = audio_source_right_q;
assign audio_left_scaled = $signed(audio_source_left) * $signed({1'b0, audio_effective_gain_q});
assign audio_right_scaled = $signed(audio_source_right) * $signed({1'b0, audio_effective_gain_q});
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        audio_left_data <= 24'd0;
        audio_right_data <= 24'd0;
        audio_valid <= 1'b0;
        audio_mix_left_q <= 25'sd0;
        audio_mix_right_q <= 25'sd0;
        audio_source_left_q <= 24'sd0;
        audio_source_right_q <= 24'sd0;
        audio_mix_valid_q <= 1'b0;
        audio_valid_raw_q <= 1'b0;
    end else begin
        audio_mix_left_q <= audio_mix_left;
        audio_mix_right_q <= audio_mix_right;
        audio_mix_valid_q <= wav_sample_valid_d2;  // one per sample tick, music or not
        audio_source_left_q <= saturate_audio(audio_mix_left_q);
        audio_source_right_q <= saturate_audio(audio_mix_right_q);
        audio_valid_raw_q <= audio_mix_valid_q;
        audio_left_data <= audio_left_scaled >>> 8;
        audio_right_data <= audio_right_scaled >>> 8;
        audio_valid <= audio_valid_raw_q;
    end
end


// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_720p u_video_rgb_to_axis_720p(
    .I_clk         (video_clk),
    .I_rst         (~video_rst_n),
    .I_vs          (welcome_vs),
    .I_de          (welcome_de),
    .I_rgb         (welcome_data),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);


audio_arc_calculate #(
    .ACR_N (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (~video_rst_n),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (~video_rst_n),
    .O_pulse (edid_trig)
);

// ===================== HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 1650       ),
    .HSA                    ( 40         ),
    .HFP                    ( 110        ),
    .HBP                    ( 220        ),
    .HACTIVE                ( 1280       ),
    .VTOTAL                 ( 750        ),
    .VSA                    ( 5          ),
    .VFP                    ( 5          ),
    .VBP                    ( 20         ),
    .VACTIVE                ( 720        ),
    .VIDEO_VIC              ( 4          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 750        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (~video_rst_n),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (~video_rst_n),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
