
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [3:0]   SCAN_TARGET_COUNT = 4'd8,
    parameter integer LONG_PRESS_MS     = 600,
    parameter integer MAX_LOAD_RETRIES  = 1,
    parameter integer FRAME_PIXELS      = 921_600,
    parameter integer AD_IDLE_MS        = 20000
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_prev,
    input                       key_auto,
    input                       key_confirm,
    input                       key_back,
    input  [3:0]                auto_interval,       // auto-play seconds 5..15, asynchronous
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    // Dishes the kitchen marked sold out, bit {category, dish}; asynchronous.
    input  [15:0]               sold_out_mask,
    // Order submission to the kitchen: K4 in switch mode 111.
    input                       key_submit,
    input                       link_busy,           // asynchronous: an order is pending
    output reg                  submit_toggle,
    output reg [2:0]            submit_count,
    output reg [31:0]           submit_items,        // {qty, dish} per byte
    // Advert player.
    input                       ad_enable,           // welcome finished
    input  [3:0]                idle_keys,           // raw K1..K4, 0 = pressed
    input  [2:0]                ad_select,           // poster chosen by the kitchen, 1..4
    output reg [3:0]            ad_bank_mask,        // banks holding a poster
    output reg [2:0]            ad_zoom_level,       // 0 full screen .. 5 smallest
    output reg                  ad_key_mask,         // keys drive the advert player
    output reg                  display_valid,
    output      [2:0]           image_index_status,
    output      [3:0]           image_count_status,
    output                      loading,
    output      [3:0]           state_code,
    output                      auto_play_enabled,
    output      [3:0]           resident_status,
    output      [2:0]           bank_owner0_status,
    output      [2:0]           bank_owner1_status,
    output      [2:0]           bank_owner2_status,
    output      [2:0]           bank_owner3_status,
    output      [7:0]           category_cache_status,
    output      [7:0]           startup_progress,
    output reg                  preload_settled,
    // Bring-up record of the FIRST failed load, latched until reset:
    // [19:16] cause (1 header, 2 SD sector, 3 truncated, 4 FAT, 7 stalled
    //         streaming, 8 stalled waiting for SDRAM write, 9 stalled
    //         waiting for the SD bus), [15:12] resource number (1-8),
    // [11:8] BMP reader state, [7:4] SD command FSM state, [3:0] failures.
    output      [19:0]          debug_status,
    output reg                  thumbnail_mode,
    output reg [2:0]            thumbnail_focus_idx,
    output reg                  thumbnail_exit_toggle,
    output reg [1:0]            menu_state,
    output reg [1:0]            dish_index,
    output      [1:0]           category_index,
    output                      photo_asset_ready,
    output                      photo_asset_boot_done,
    output                      photo_asset_write_mode,
    output reg [3:0]            cart_qty0,
    output reg [3:0]            cart_qty1,
    output reg [3:0]            cart_qty2,
    output reg [3:0]            cart_qty3,
    output reg [5:0]            cart_total_count,
    output reg [9:0]            cart_total_price,
    output reg [3:0]            cart_order0,
    output reg [3:0]            cart_order1,
    output reg [3:0]            cart_order2,
    output reg [3:0]            cart_order3,
    output reg [2:0]            cart_distinct_count,

    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO,
    input                       audio_sd_req,
    input  [31:0]               audio_sd_lba,
    output                      audio_sd_busy,
    output                      audio_sd_valid,
    output [7:0]                audio_sd_byte,
    output [8:0]                audio_sd_byte_index,
    output                      audio_sd_done,
    output [7:0]                audio_sd_error,
    output reg                  audio_available,
    output reg [31:0]           audio_start_lba,
    output reg [31:0]           audio_total_sectors
);

wire key_next_press;
wire key_prev_press;
wire key_auto_press;
wire key_auto_stable;
wire key_confirm_press;
wire key_back_press;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire             bmp_sd_sec_read_data_valid;
wire             bmp_sd_sec_read_end;
wire             sd_top_read;
wire [31:0]      sd_top_read_addr;
wire [3:0]       state_code_i;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
wire             bmp_ready;
reg              bmp_ready_q;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [3:0]       scan_found_total;
wire             load_done;
wire             load_error;
wire [2:0]       bmp_error;
wire [6:0]       frame_load_progress;
wire             audio_available_i;
wire [31:0]      audio_start_lba_i;
wire [31:0]      audio_total_sectors_i;
reg              sd_owner_audio;
reg              sd_active;
// An abort resets the BMP reader, dropping its request. If that lands just
// after the arbiter granted the bus but before the SD controller latched the
// read, the bus would wait forever for a read_end. Hold the granted request
// (and its address) until the sector actually ends.
reg              image_read_hold;
reg [31:0]       image_read_addr;
wire [4:0]       sd_cmd_state;
reg [9:0]        audio_byte_count;
reg              audio_done_reg;
reg [7:0]        audio_error_reg;

assign audio_sd_busy = sd_active || sd_sec_read;
assign audio_sd_valid = sd_active && sd_owner_audio && sd_sec_read_data_valid;
assign audio_sd_byte = sd_sec_read_data;
assign audio_sd_byte_index = audio_byte_count[8:0];
assign audio_sd_done = audio_done_reg;
assign audio_sd_error = audio_error_reg;
assign bmp_sd_sec_read_data_valid = sd_active && !sd_owner_audio && sd_sec_read_data_valid;
assign bmp_sd_sec_read_end = sd_active && !sd_owner_audio && sd_sec_read_end;
assign sd_top_read = sd_active && (sd_owner_audio ? 1'b1 : (sd_sec_read || image_read_hold));
assign sd_top_read_addr = sd_owner_audio ? audio_sd_lba :
                          image_read_hold ? image_read_addr : sd_sec_read_addr;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              scan_complete;
reg              scan_retry_pending;
reg [24:0]       scan_retry_cnt;
reg              first_image_committed;
reg              auto_play_en;
reg [31:0]       auto_cnt;
reg [3:0]        img_found_count;
reg [3:0]        navigation_count;
reg [2:0]        img_idx;              // 当前真正显示中的分类编号
reg [2:0]        load_idx;             // 当前正在写入的分类编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的 SDRAM bank
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg [31:0]       img_sector4;
reg [31:0]       img_sector5;
reg [31:0]       img_sector6;
reg [31:0]       img_sector7;
reg              next_req_pending;
reg              prev_req_pending;
reg              prefetch_load;
reg              prefetch_reverse;
reg              prefetch_armed;
reg              cache_valid;
reg [2:0]        cache_idx;
reg [1:0]        cache_buf_idx;
reg              load_busy;
reg              load_launch_pending;
reg [31:0]       load_timeout_cnt;
reg [1:0]        load_retry_count;
reg [7:0]        bad_image_mask;
reg [3:0]        resident_mask;
reg [2:0]        bank_owner0;
reg [2:0]        bank_owner1;
reg [2:0]        bank_owner2;
reg [2:0]        bank_owner3;
reg [7:0]        category_cache_valid;
reg              photo_asset_ready_reg;
reg              photo_asset_boot_done_reg;
reg [1:0]        photo_asset_category;
reg              detail_enter_pending;

reg              load_abort;
// Advert player.
localparam [1:0] AD_OFF    = 2'd0;
localparam [1:0] AD_FIRST  = 2'd1;    // first poster loading, screen unchanged
localparam [1:0] AD_SHOW   = 2'd2;    // poster on screen
localparam [1:0] AD_SWITCH = 2'd3;    // poster on screen, the next one loading
reg [1:0]        ad_state;
reg              ad_loading;
reg [1:0]        ad_load_bank;
reg [1:0]        ad_load_index;
reg [1:0]        ad_show_bank;
reg [1:0]        ad_show_index;
reg [2:0]        ad_load_level;          // size of the poster loading
reg [2:0]        ad_show_level;          // size of the poster on screen
reg [1:0]        ad_bank_a;
reg [1:0]        ad_bank_b;
reg [1:0]        ad_return_bank;
reg [3:0]        ad_bad;
reg [14:0]       ad_idle_cnt;          // milliseconds (up to 32 s)
reg              ad_trigger;
(* async_reg = "true" *) reg [3:0] ad_keys_sync0;
(* async_reg = "true" *) reg [3:0] ad_keys_sync1;
(* async_reg = "true" *) reg [2:0] ad_select_sync0;
(* async_reg = "true" *) reg [2:0] ad_select_sync1;
reg [2:0]        ad_select_q;
reg [16:0]       ad_ms_cnt;
reg [3:0]        ad_key_stable;          // debounced, 1 = released
reg [3:0]        ad_key_press;
reg [3:0]        ad_key_cnt0, ad_key_cnt1, ad_key_cnt2, ad_key_cnt3;
wire [3:0]       ad_found;
wire [10:0]      ad_width;
wire [10:0]      ad_height;
wire             ad_stream_start;
wire             ad_source_go;
wire             ad_scaler_valid;
wire [31:0]      ad_scaler_data;
wire             ad_any_key = ad_keys_sync1 != 4'hf;
// The kitchen's choice (1..4) if that poster exists, else the first one there.
wire [1:0]       ad_select_index = ad_select_q[1:0] - 2'd1;
wire [3:0]       ad_usable = ad_found & ~ad_bad;
wire [1:0]       ad_wanted = (ad_select_q >= 3'd1 && ad_select_q <= 3'd4 &&
                              ad_usable[ad_select_index]) ? ad_select_index :
                             ad_usable[0] ? 2'd0 : ad_usable[1] ? 2'd1 :
                             ad_usable[2] ? 2'd2 : 2'd3;
wire             ad_available = |ad_usable;
reg [31:0]       key_auto_hold_count;
reg              key_auto_long_marked;
reg              thumbnail_toggle_pulse;
reg              thumbnail_enter_pulse;
reg              thumbnail_select_pulse;
reg              thumbnail_cancel_pulse;
reg              dish_return_pulse;
reg              dish_undo_pulse;
reg              thumbnail_req_pending;
reg              manual_reload_pending;
reg [2:0]        manual_reload_idx;
reg [2:0]        category_return_idx;

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;
reg              write_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
(* async_reg = "true" *) reg [2:0] wrfin_tgl_sync;
wire             write_finish_pulse;

reg auto_tick;
reg  [2:0] next_from_current;
reg  [2:0] prev_from_current;
reg  [2:0] next_from_focus;
reg  [2:0] prev_from_focus;
reg  [2:0] prefetch_from_current;
reg  [2:0] first_available_idx;
reg  [2:0] next_after_failure;
wire [2:0] next_from_current_comb;
wire [2:0] prev_from_current_comb;
wire [2:0] next_from_focus_comb;
wire [2:0] prev_from_focus_comb;
wire [2:0] prefetch_from_current_comb;
wire [2:0] first_available_idx_comb;
wire [2:0] next_after_failure_comb;
wire       playable_available;
wire [7:0] discovered_mask;
wire [7:0] active_group_mask;
wire [7:0] navigation_bad_mask;
wire       preload_available;
wire       next_press_valid;
wire       prev_press_valid;
wire       prefetch_claim_next;
wire       prefetch_claim_prev;
wire [2:0] resident_count;
wire [9:0] startup_progress_sum;
wire [6:0] startup_category_progress;
wire [6:0] startup_asset_progress;
// One file is 0..64 progress steps worth 51 units of the 255 total; the
// product needs 13 bits.
wire [12:0] frame_progress_units = frame_load_progress * 13'd51;
(* async_reg = "true" *) reg [15:0] sold_out_sync0;
(* async_reg = "true" *) reg [15:0] sold_out_sync1;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sold_out_sync0 <= 16'd0;
        sold_out_sync1 <= 16'd0;
    end else begin
        sold_out_sync0 <= sold_out_mask;
        sold_out_sync1 <= sold_out_sync0;
    end
end
localparam integer CLOCKS_PER_SECOND = CLK_FREQ_HZ;
localparam integer LONG_PRESS_CYCLES = (CLK_FREQ_HZ / 1000) * LONG_PRESS_MS;
localparam integer LOAD_STALL_TIMEOUT_CYCLES = (CLK_FREQ_HZ / 1000) * 3000;
localparam integer SCAN_RETRY_CYCLES = (CLK_FREQ_HZ / 1000) * 250;
localparam [1:0] MENU_CATEGORY = 2'd0;
localparam [1:0] MENU_DISH     = 2'd1;
localparam [1:0] MENU_ORDER    = 2'd2;

reg [3:0] order_history [0:15];
reg [4:0] order_history_depth;
reg       order_undo_pending;
reg [3:0] order_undo_dish;
reg [5:0] order_undo_price;
integer order_history_index;

function [5:0] dish_price;
    input [3:0] index;
    begin
        case (index)
            4'h0: dish_price = 6'd18;
            4'h1: dish_price = 6'd15;
            4'h2: dish_price = 6'd17;
            4'h3: dish_price = 6'd16;
            4'h4: dish_price = 6'd12;
            4'h5: dish_price = 6'd14;
            4'h6: dish_price = 6'd10;
            4'h7: dish_price = 6'd9;
            4'h8: dish_price = 6'd8;
            4'h9: dish_price = 6'd7;
            4'ha: dish_price = 6'd6;
            4'hb: dish_price = 6'd8;
            4'hc: dish_price = 6'd25;
            4'hd: dish_price = 6'd23;
            4'he: dish_price = 6'd20;
            default: dish_price = 6'd38;
        endcase
    end
endfunction

wire [3:0] selected_order_item = {category_return_idx[1:0], dish_index};
wire cart_match0 = cart_distinct_count > 0 && cart_order0 == selected_order_item;
wire cart_match1 = cart_distinct_count > 1 && cart_order1 == selected_order_item;
wire cart_match2 = cart_distinct_count > 2 && cart_order2 == selected_order_item;
wire cart_match3 = cart_distinct_count > 3 && cart_order3 == selected_order_item;
wire cart_accept_item = !sold_out_sync1[selected_order_item] &&
                        ((cart_match0 && cart_qty0 < 4'd15) ||
                         (cart_match1 && cart_qty1 < 4'd15) ||
                         (cart_match2 && cart_qty2 < 4'd15) ||
                         (cart_match3 && cart_qty3 < 4'd15) ||
                         cart_distinct_count < 3'd4);

assign write_en   = ad_loading ? ad_scaler_valid : bmp_data_wr_en;
assign write_data = ad_loading ? ad_scaler_data :
                    {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
assign auto_play_enabled = auto_play_en;
assign category_index = category_return_idx[1:0];
assign image_index_status = (menu_state == MENU_CATEGORY) ? img_idx : {1'b0, dish_index};
assign image_count_status = (navigation_count > 4'd4) ? 4'd4 : navigation_count;
assign resident_status = resident_mask;
assign bank_owner0_status = bank_owner0;
assign bank_owner1_status = bank_owner1;
assign bank_owner2_status = bank_owner2;
assign bank_owner3_status = bank_owner3;
assign category_cache_status = category_cache_valid;
assign photo_asset_ready = photo_asset_ready_reg;
assign photo_asset_boot_done = photo_asset_boot_done_reg;
assign photo_asset_write_mode = load_busy && !ad_loading && load_idx >= 3'd4;
assign resident_count = resident_mask[0] + resident_mask[1] +
                        resident_mask[2] + resident_mask[3];
assign startup_category_progress = (load_busy && load_idx < 3'd4) ?
                                   frame_progress_units[12:6] : 7'd0;
assign startup_asset_progress = (load_busy && load_idx == 3'd4) ?
                                frame_progress_units[12:6] : 7'd0;
assign startup_progress_sum = resident_count * 7'd51 +
                              startup_category_progress + startup_asset_progress;
assign startup_progress = ((resident_mask == 4'hf && photo_asset_boot_done_reg) ||
                           startup_progress_sum >= 10'd255) ?
                          8'd255 : startup_progress_sum[7:0];
assign loading = load_busy && !ad_loading &&
                 (!prefetch_load || next_req_pending || prev_req_pending ||
                               prefetch_claim_next || prefetch_claim_prev);
assign active_group_mask = (menu_state == MENU_CATEGORY) ? 8'h0f : 8'h00;
assign navigation_bad_mask = bad_image_mask | ~active_group_mask;
assign next_from_current_comb = next_available_index(img_idx, navigation_count, navigation_bad_mask);
assign prev_from_current_comb = prev_available_index(img_idx, navigation_count, navigation_bad_mask);
assign next_from_focus_comb = next_available_index(thumbnail_focus_idx, navigation_count,
                                                    bad_image_mask | 8'hf0);
assign prev_from_focus_comb = prev_available_index(thumbnail_focus_idx, navigation_count,
                                                    bad_image_mask | 8'hf0);
assign discovered_mask = (navigation_count >= 4'd8) ? 8'hff :
                         (navigation_count == 4'd7) ? 8'h7f :
                         (navigation_count == 4'd6) ? 8'h3f :
                         (navigation_count == 4'd5) ? 8'h1f :
                         (navigation_count == 4'd4) ? 8'h0f :
                         (navigation_count == 4'd3) ? 8'h07 :
                         (navigation_count == 4'd2) ? 8'h03 :
                         (navigation_count == 4'd1) ? 8'h01 : 8'h00;
assign preload_available = |(discovered_mask & active_group_mask &
                             ~(bad_image_mask | category_cache_valid));
assign prefetch_from_current_comb = prefetch_reverse ?
                                    prev_available_index(img_idx, navigation_count,
                                                         navigation_bad_mask | category_cache_valid) :
                                    next_available_index(img_idx, navigation_count,
                                                         navigation_bad_mask | category_cache_valid);
assign first_available_idx_comb = first_available_index(navigation_count, bad_image_mask | 8'hf0);
assign next_after_failure_comb = next_available_index(img_idx, navigation_count,
                                                      navigation_bad_mask |
                                                      (8'b0000_0001 << load_idx));
assign playable_available = ((navigation_count > 3'd0) && !bad_image_mask[0]) ||
                            ((navigation_count > 3'd1) && !bad_image_mask[1]) ||
                            ((navigation_count > 3'd2) && !bad_image_mask[2]) ||
                            ((navigation_count > 3'd3) && !bad_image_mask[3]);
assign next_press_valid = key_next_press && !thumbnail_mode &&
                           (menu_state == MENU_CATEGORY) &&
                           display_valid &&
                           (img_idx < 3'd4) &&
                           (next_from_current != img_idx);
assign prev_press_valid = key_prev_press && !thumbnail_mode &&
                           (menu_state == MENU_CATEGORY) &&
                           display_valid &&
                           (img_idx < 3'd4) &&
                           (prev_from_current != img_idx);
assign prefetch_claim_next = next_press_valid && load_busy && prefetch_load &&
                             (load_idx == next_from_current);
assign prefetch_claim_prev = prev_press_valid && load_busy && prefetch_load &&
                             (load_idx == prev_from_current);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
assign state_code = display_valid ? ((menu_state == MENU_CATEGORY) ?
                    ({2'b00, img_idx} + 4'd1) : ({2'b00, dish_index} + 4'd1)) : state_code_i;

// Auto-play interval: the switch setting arrives asynchronously; take it once
// two samples agree. The tick fires when auto_cnt reaches seconds * f - 2.
(* async_reg = "true" *) reg [3:0] auto_interval_sync0;
(* async_reg = "true" *) reg [3:0] auto_interval_sync1;
reg [3:0]  auto_seconds;
reg [31:0] auto_tick_count;
reg        auto_due_q;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        auto_interval_sync0 <= 4'd8;
        auto_interval_sync1 <= 4'd8;
        auto_seconds <= 4'd8;
        auto_tick_count <= 8 * CLOCKS_PER_SECOND - 2;
        auto_due_q <= 1'b0;
        auto_tick <= 1'b0;
    end else begin
        auto_interval_sync0 <= auto_interval;
        auto_interval_sync1 <= auto_interval_sync0;
        if (auto_interval_sync0 == auto_interval_sync1 &&
            auto_interval_sync1 >= 4'd5 && auto_interval_sync1 <= 4'd15)
            auto_seconds <= auto_interval_sync1;
        case (auto_seconds)
            4'd5:  auto_tick_count <= 5 * CLOCKS_PER_SECOND - 2;
            4'd6:  auto_tick_count <= 6 * CLOCKS_PER_SECOND - 2;
            4'd7:  auto_tick_count <= 7 * CLOCKS_PER_SECOND - 2;
            4'd9:  auto_tick_count <= 9 * CLOCKS_PER_SECOND - 2;
            4'd10: auto_tick_count <= 10 * CLOCKS_PER_SECOND - 2;
            4'd11: auto_tick_count <= 11 * CLOCKS_PER_SECOND - 2;
            4'd12: auto_tick_count <= 12 * CLOCKS_PER_SECOND - 2;
            4'd13: auto_tick_count <= 13 * CLOCKS_PER_SECOND - 2;
            4'd14: auto_tick_count <= 14 * CLOCKS_PER_SECOND - 2;
            4'd15: auto_tick_count <= 15 * CLOCKS_PER_SECOND - 2;
            default: auto_tick_count <= 8 * CLOCKS_PER_SECOND - 2;
        endcase
        // One pulse when auto_cnt reaches the count; >= so that a shorter
        // interval chosen mid-way still ends the wait.
        auto_due_q <= auto_cnt >= auto_tick_count;
        auto_tick <= auto_cnt >= auto_tick_count && !auto_due_q;
    end
end

// Advert player: raw keys (any press counts as activity), kitchen selection,
// a 10 ms debounce for the player's own keys, and the idle timer.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        ad_keys_sync0 <= 4'hf;
        ad_keys_sync1 <= 4'hf;
        ad_select_sync0 <= 3'd1;
        ad_select_sync1 <= 3'd1;
        ad_select_q <= 3'd1;
        ad_ms_cnt <= 17'd0;
        ad_key_stable <= 4'hf;
        ad_key_press <= 4'd0;
        ad_key_cnt0 <= 4'd0;
        ad_key_cnt1 <= 4'd0;
        ad_key_cnt2 <= 4'd0;
        ad_key_cnt3 <= 4'd0;
        ad_idle_cnt <= 15'd0;
        ad_trigger <= 1'b0;
    end else begin
        ad_keys_sync0 <= idle_keys;
        ad_keys_sync1 <= ad_keys_sync0;
        ad_select_sync0 <= ad_select;
        ad_select_sync1 <= ad_select_sync0;
        if (ad_select_sync0 == ad_select_sync1)
            ad_select_q <= ad_select_sync1;
        ad_key_press <= 4'd0;
        ad_ms_cnt <= (ad_ms_cnt == CLK_FREQ_HZ / 1000 - 1) ? 17'd0 : ad_ms_cnt + 17'd1;
        if (ad_ms_cnt == 17'd0) begin
            ad_key_cnt0 <= (ad_keys_sync1[0] == ad_key_stable[0]) ? 4'd0 : ad_key_cnt0 + 4'd1;
            ad_key_cnt1 <= (ad_keys_sync1[1] == ad_key_stable[1]) ? 4'd0 : ad_key_cnt1 + 4'd1;
            ad_key_cnt2 <= (ad_keys_sync1[2] == ad_key_stable[2]) ? 4'd0 : ad_key_cnt2 + 4'd1;
            ad_key_cnt3 <= (ad_keys_sync1[3] == ad_key_stable[3]) ? 4'd0 : ad_key_cnt3 + 4'd1;
            if (ad_keys_sync1[0] != ad_key_stable[0] && ad_key_cnt0 == 4'd9) begin
                ad_key_stable[0] <= ad_keys_sync1[0];
                ad_key_press[0] <= !ad_keys_sync1[0];
                ad_key_cnt0 <= 4'd0;
            end
            if (ad_keys_sync1[1] != ad_key_stable[1] && ad_key_cnt1 == 4'd9) begin
                ad_key_stable[1] <= ad_keys_sync1[1];
                ad_key_press[1] <= !ad_keys_sync1[1];
                ad_key_cnt1 <= 4'd0;
            end
            if (ad_keys_sync1[2] != ad_key_stable[2] && ad_key_cnt2 == 4'd9) begin
                ad_key_stable[2] <= ad_keys_sync1[2];
                ad_key_press[2] <= !ad_keys_sync1[2];
                ad_key_cnt2 <= 4'd0;
            end
            if (ad_keys_sync1[3] != ad_key_stable[3] && ad_key_cnt3 == 4'd9) begin
                ad_key_stable[3] <= ad_keys_sync1[3];
                ad_key_press[3] <= !ad_keys_sync1[3];
                ad_key_cnt3 <= 4'd0;
            end
        end
        // Idle: main screen settled, nothing loading, no key for AD_IDLE_MS.
        ad_trigger <= 1'b0;
        if (!(ad_enable && ad_state == AD_OFF && ad_available && scan_complete &&
              display_valid && first_image_committed && preload_settled &&
              menu_state == MENU_CATEGORY && !thumbnail_mode && !auto_play_en &&
              !load_busy && !load_launch_pending && !next_req_pending &&
              !prev_req_pending && !manual_reload_pending && !thumbnail_req_pending &&
              !detail_enter_pending) || ad_any_key || !ad_key_stable[0] ||
            !ad_key_stable[1] || !ad_key_stable[2] || !ad_key_stable[3]) begin
            ad_idle_cnt <= 15'd0;
        end else if (ad_idle_cnt == AD_IDLE_MS - 1) begin
            ad_idle_cnt <= 15'd0;
            ad_trigger <= 1'b1;
        end else if (ad_ms_cnt == 17'd0) begin
            ad_idle_cnt <= ad_idle_cnt + 15'd1;
        end
    end
end

reg [3:0] debug_cause;
reg [3:0] debug_resource;
reg [3:0] debug_reader_state;
reg [3:0] debug_sd_state;
reg [3:0] debug_failures;
assign debug_status = {debug_cause, debug_resource, debug_reader_state,
                       debug_sd_state, debug_failures};

function [3:0] sd_state_digit;
    input [4:0] value;
    begin
        case (value)
            5'd16: sd_state_digit = 4'ha;   // READ_END
            5'd17: sd_state_digit = 4'hb;   // WAIT_READ_WRITE
            5'd18: sd_state_digit = 4'hc;   // CMD16
            default: sd_state_digit = value[3:0];
        endcase
    end
endfunction

// load_timeout_cnt has reached the 3 s stall limit. Registered next to the
// counter (set with its increment, cleared with it) to keep the 32-bit
// compare out of the load state logic.
reg load_timeout_hit;
wire debug_stall = load_busy && !load_error &&
                   !(source_done_seen && write_done_seen) &&
                   !(bmp_data_wr_en || load_done || write_finish_pulse || write_en) &&
                   load_timeout_hit;
wire [3:0] debug_stall_cause = load_launch_pending ? 4'd9 :
                               source_done_seen ? 4'd8 : 4'd7;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        debug_cause        <= 4'd0;
        debug_resource     <= 4'd0;
        debug_reader_state <= 4'd0;
        debug_sd_state     <= 4'd0;
        debug_failures     <= 4'd0;
    end else if ((load_busy && load_error) || debug_stall) begin
        if (debug_failures != 4'hf)
            debug_failures <= debug_failures + 1'b1;
        if (debug_cause == 4'd0) begin
            debug_cause        <= (load_busy && load_error) ? {1'b0, bmp_error} :
                                                              debug_stall_cause;
            debug_resource     <= {1'b0, load_idx} + 4'd1;
            debug_reader_state <= state_code_i;
            debug_sd_state     <= sd_state_digit(sd_cmd_state);
        end
    end
end

// Startup has reached a terminal state once each discovered category is either
// resident or isolated as bad and no load or retry is outstanding. The boot
// detail asset is only attempted after all four categories are resident.
always @(posedge clk or posedge rst) begin
    if (rst)
        preload_settled <= 1'b0;
    else
        preload_settled <= scan_complete && display_valid &&
                           !load_busy && !load_launch_pending &&
                           ((discovered_mask & 8'h0f &
                             ~(category_cache_valid | bad_image_mask)) == 8'h00) &&
                           (photo_asset_boot_done_reg ||
                            category_cache_valid[3:0] != 4'hf);
end

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (10)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press),
    .button_stable_out()
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (10)
) u_key_prev (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_prev),
    .press_pulse(key_prev_press),
    .button_stable_out()
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (10)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_press),
    .button_stable_out(key_auto_stable)
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (10)
) u_key_confirm (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_confirm),
    .press_pulse(key_confirm_press),
    .button_stable_out()
);

wire key_submit_press;
(* async_reg = "true" *) reg [1:0] link_busy_sync;
key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (10)
) u_key_submit (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_submit),
    .press_pulse(key_submit_press),
    .button_stable_out()
);
always @(posedge clk or posedge rst)
    if (rst) link_busy_sync <= 2'b11;
    else link_busy_sync <= {link_busy_sync[0], link_busy};

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (10)
) u_key_back (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_back),
    .press_pulse(key_back_press),
    .button_stable_out()
);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        key_auto_hold_count <= 32'd0;
        key_auto_long_marked <= 1'b0;
        thumbnail_toggle_pulse <= 1'b0;
        thumbnail_enter_pulse <= 1'b0;
        thumbnail_select_pulse <= 1'b0;
        thumbnail_cancel_pulse <= 1'b0;
        dish_return_pulse <= 1'b0;
        dish_undo_pulse <= 1'b0;
        thumbnail_mode <= 1'b0;
        thumbnail_focus_idx <= 3'd0;
    end else begin
        thumbnail_toggle_pulse <= 1'b0;
        thumbnail_enter_pulse <= 1'b0;
        thumbnail_select_pulse <= 1'b0;
        thumbnail_cancel_pulse <= 1'b0;
        dish_return_pulse <= 1'b0;
        dish_undo_pulse <= 1'b0;
        if (!sd_init_done) begin
            key_auto_hold_count <= 32'd0;
            key_auto_long_marked <= 1'b0;
            thumbnail_mode <= 1'b0;
            thumbnail_focus_idx <= 3'd0;
        end else if (!key_auto_stable) begin
            if (key_auto_hold_count < LONG_PRESS_CYCLES)
                key_auto_hold_count <= key_auto_hold_count + 1'b1;
            if (!key_auto_long_marked &&
                key_auto_hold_count >= LONG_PRESS_CYCLES - 1) begin
                key_auto_long_marked <= 1'b1;
                if (menu_state == MENU_CATEGORY && display_valid &&
                    category_cache_valid[3:0] == 4'hf && !load_busy) begin
                    thumbnail_mode <= ~thumbnail_mode;
                    thumbnail_toggle_pulse <= 1'b1;
                    if (!thumbnail_mode) begin
                        thumbnail_focus_idx <= img_idx;
                        thumbnail_enter_pulse <= 1'b1;
                    end
                end else if (menu_state == MENU_DISH && display_valid) begin
                    dish_return_pulse <= 1'b1;
                end
            end
        end else begin
            if (menu_state == MENU_DISH && key_auto_hold_count != 0 &&
                !key_auto_long_marked)
                dish_undo_pulse <= 1'b1;
            key_auto_hold_count <= 32'd0;
            key_auto_long_marked <= 1'b0;
        end

        if (thumbnail_mode) begin
            if (key_next_press)
                thumbnail_focus_idx <= next_from_focus;
            else if (key_prev_press)
                thumbnail_focus_idx <= prev_from_focus;
            if (key_confirm_press) begin
                thumbnail_mode <= 1'b0;
                thumbnail_select_pulse <= 1'b1;
            end else if (key_back_press) begin
                thumbnail_mode <= 1'b0;
                thumbnail_cancel_pulse <= 1'b1;
            end
        end
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        submit_toggle <= 1'b0;
        submit_count <= 3'd0;
        submit_items <= 32'd0;
        cart_qty0 <= 4'd0;
        cart_qty1 <= 4'd0;
        cart_qty2 <= 4'd0;
        cart_qty3 <= 4'd0;
        cart_total_count <= 6'd0;
        cart_total_price <= 10'd0;
        cart_order0 <= 4'd0;
        cart_order1 <= 4'd0;
        cart_order2 <= 4'd0;
        cart_order3 <= 4'd0;
        cart_distinct_count <= 3'd0;
        order_history_depth <= 5'd0;
        order_undo_pending <= 1'b0;
        order_undo_dish <= 4'd0;
        order_undo_price <= 6'd0;
        for (order_history_index = 0; order_history_index < 16;
             order_history_index = order_history_index + 1)
            order_history[order_history_index] <= 4'd0;
    end else if (!sd_init_done) begin
        cart_qty0 <= 4'd0;
        cart_qty1 <= 4'd0;
        cart_qty2 <= 4'd0;
        cart_qty3 <= 4'd0;
        cart_total_count <= 6'd0;
        cart_total_price <= 10'd0;
        cart_order0 <= 4'd0;
        cart_order1 <= 4'd0;
        cart_order2 <= 4'd0;
        cart_order3 <= 4'd0;
        cart_distinct_count <= 3'd0;
        order_history_depth <= 5'd0;
        order_undo_pending <= 1'b0;
        order_undo_dish <= 4'd0;
        order_undo_price <= 6'd0;
    end else if (key_submit_press && cart_total_count != 6'd0 && !link_busy_sync[1]) begin
        // Hand the cart to the link and start a new one.
        submit_count <= cart_distinct_count;
        submit_items <= {cart_qty3, cart_order3, cart_qty2, cart_order2,
                         cart_qty1, cart_order1, cart_qty0, cart_order0};
        submit_toggle <= ~submit_toggle;
        cart_qty0 <= 4'd0;
        cart_qty1 <= 4'd0;
        cart_qty2 <= 4'd0;
        cart_qty3 <= 4'd0;
        cart_total_count <= 6'd0;
        cart_total_price <= 10'd0;
        cart_order0 <= 4'd0;
        cart_order1 <= 4'd0;
        cart_order2 <= 4'd0;
        cart_order3 <= 4'd0;
        cart_distinct_count <= 3'd0;
        order_history_depth <= 5'd0;
    end else if (order_undo_pending) begin
        cart_total_count <= cart_total_count - 1'b1;
        cart_total_price <= cart_total_price - order_undo_price;
        if (cart_order0 == order_undo_dish) begin
            if (cart_qty0 == 4'd1) begin
                cart_order0 <= cart_order1;
                cart_order1 <= cart_order2;
                cart_order2 <= cart_order3;
                cart_order3 <= 4'd0;
                cart_qty0 <= cart_qty1;
                cart_qty1 <= cart_qty2;
                cart_qty2 <= cart_qty3;
                cart_qty3 <= 4'd0;
                cart_distinct_count <= cart_distinct_count - 1'b1;
            end else begin
                cart_qty0 <= cart_qty0 - 1'b1;
            end
        end else if (cart_order1 == order_undo_dish) begin
            if (cart_qty1 == 4'd1) begin
                cart_order1 <= cart_order2;
                cart_order2 <= cart_order3;
                cart_order3 <= 4'd0;
                cart_qty1 <= cart_qty2;
                cart_qty2 <= cart_qty3;
                cart_qty3 <= 4'd0;
                cart_distinct_count <= cart_distinct_count - 1'b1;
            end else begin
                cart_qty1 <= cart_qty1 - 1'b1;
            end
        end else if (cart_order2 == order_undo_dish) begin
            if (cart_qty2 == 4'd1) begin
                cart_order2 <= cart_order3;
                cart_order3 <= 4'd0;
                cart_qty2 <= cart_qty3;
                cart_qty3 <= 4'd0;
                cart_distinct_count <= cart_distinct_count - 1'b1;
            end else begin
                cart_qty2 <= cart_qty2 - 1'b1;
            end
        end else if (cart_order3 == order_undo_dish) begin
            if (cart_qty3 == 4'd1) begin
                cart_order3 <= 4'd0;
                cart_qty3 <= 4'd0;
                cart_distinct_count <= cart_distinct_count - 1'b1;
            end else begin
                cart_qty3 <= cart_qty3 - 1'b1;
            end
        end
        order_undo_pending <= 1'b0;
    end else if (!thumbnail_mode && menu_state == MENU_DISH &&
                 key_confirm_press && cart_total_count < 6'd16 && cart_accept_item) begin
        if (cart_match0)
            cart_qty0 <= cart_qty0 + 1'b1;
        else if (cart_match1)
            cart_qty1 <= cart_qty1 + 1'b1;
        else if (cart_match2)
            cart_qty2 <= cart_qty2 + 1'b1;
        else if (cart_match3)
            cart_qty3 <= cart_qty3 + 1'b1;
        else begin
            case (cart_distinct_count)
                3'd0: begin cart_order0 <= selected_order_item; cart_qty0 <= 4'd1; end
                3'd1: begin cart_order1 <= selected_order_item; cart_qty1 <= 4'd1; end
                3'd2: begin cart_order2 <= selected_order_item; cart_qty2 <= 4'd1; end
                default: begin cart_order3 <= selected_order_item; cart_qty3 <= 4'd1; end
            endcase
            cart_distinct_count <= cart_distinct_count + 1'b1;
        end
        order_history[order_history_depth[3:0]] <= selected_order_item;
        order_history_depth <= order_history_depth + 1'b1;
        cart_total_count <= cart_total_count + 1'b1;
        cart_total_price <= cart_total_price + dish_price(selected_order_item);
    end else if (dish_undo_pulse && order_history_depth != 0) begin
        order_undo_dish <= order_history[order_history_depth - 1'b1];
        order_undo_price <= dish_price(order_history[order_history_depth - 1'b1]);
        order_undo_pending <= 1'b1;
        order_history_depth <= order_history_depth - 1'b1;
    end
end

function [2:0] next_available_index;
    input [2:0] cur;
    input [3:0] count;
    input [7:0] bad_mask;
    reg [7:0] available;
    begin
        available[0] = count > 4'd0 && !bad_mask[0];
        available[1] = count > 4'd1 && !bad_mask[1];
        available[2] = count > 4'd2 && !bad_mask[2];
        available[3] = count > 4'd3 && !bad_mask[3];
        available[4] = count > 4'd4 && !bad_mask[4];
        available[5] = count > 4'd5 && !bad_mask[5];
        available[6] = count > 4'd6 && !bad_mask[6];
        available[7] = count > 4'd7 && !bad_mask[7];
        next_available_index = cur;
        case (cur)
            3'd0: if (available[1]) next_available_index = 3'd1;
                  else if (available[2]) next_available_index = 3'd2;
                  else if (available[3]) next_available_index = 3'd3;
                  else if (available[4]) next_available_index = 3'd4;
                  else if (available[5]) next_available_index = 3'd5;
                  else if (available[6]) next_available_index = 3'd6;
                  else if (available[7]) next_available_index = 3'd7;
            3'd1: if (available[2]) next_available_index = 3'd2;
                  else if (available[3]) next_available_index = 3'd3;
                  else if (available[4]) next_available_index = 3'd4;
                  else if (available[5]) next_available_index = 3'd5;
                  else if (available[6]) next_available_index = 3'd6;
                  else if (available[7]) next_available_index = 3'd7;
                  else if (available[0]) next_available_index = 3'd0;
            3'd2: if (available[3]) next_available_index = 3'd3;
                  else if (available[4]) next_available_index = 3'd4;
                  else if (available[5]) next_available_index = 3'd5;
                  else if (available[6]) next_available_index = 3'd6;
                  else if (available[7]) next_available_index = 3'd7;
                  else if (available[0]) next_available_index = 3'd0;
                  else if (available[1]) next_available_index = 3'd1;
            3'd3: if (available[4]) next_available_index = 3'd4;
                  else if (available[5]) next_available_index = 3'd5;
                  else if (available[6]) next_available_index = 3'd6;
                  else if (available[7]) next_available_index = 3'd7;
                  else if (available[0]) next_available_index = 3'd0;
                  else if (available[1]) next_available_index = 3'd1;
                  else if (available[2]) next_available_index = 3'd2;
            3'd4: if (available[5]) next_available_index = 3'd5;
                  else if (available[6]) next_available_index = 3'd6;
                  else if (available[7]) next_available_index = 3'd7;
                  else if (available[0]) next_available_index = 3'd0;
                  else if (available[1]) next_available_index = 3'd1;
                  else if (available[2]) next_available_index = 3'd2;
                  else if (available[3]) next_available_index = 3'd3;
            3'd5: if (available[6]) next_available_index = 3'd6;
                  else if (available[7]) next_available_index = 3'd7;
                  else if (available[0]) next_available_index = 3'd0;
                  else if (available[1]) next_available_index = 3'd1;
                  else if (available[2]) next_available_index = 3'd2;
                  else if (available[3]) next_available_index = 3'd3;
                  else if (available[4]) next_available_index = 3'd4;
            3'd6: if (available[7]) next_available_index = 3'd7;
                  else if (available[0]) next_available_index = 3'd0;
                  else if (available[1]) next_available_index = 3'd1;
                  else if (available[2]) next_available_index = 3'd2;
                  else if (available[3]) next_available_index = 3'd3;
                  else if (available[4]) next_available_index = 3'd4;
                  else if (available[5]) next_available_index = 3'd5;
            default: if (available[0]) next_available_index = 3'd0;
                     else if (available[1]) next_available_index = 3'd1;
                     else if (available[2]) next_available_index = 3'd2;
                     else if (available[3]) next_available_index = 3'd3;
                     else if (available[4]) next_available_index = 3'd4;
                     else if (available[5]) next_available_index = 3'd5;
                     else if (available[6]) next_available_index = 3'd6;
        endcase
    end
endfunction

function [2:0] prev_available_index;
    input [2:0] cur;
    input [3:0] count;
    input [7:0] bad_mask;
    reg [7:0] available;
    begin
        available[0] = count > 4'd0 && !bad_mask[0];
        available[1] = count > 4'd1 && !bad_mask[1];
        available[2] = count > 4'd2 && !bad_mask[2];
        available[3] = count > 4'd3 && !bad_mask[3];
        available[4] = count > 4'd4 && !bad_mask[4];
        available[5] = count > 4'd5 && !bad_mask[5];
        available[6] = count > 4'd6 && !bad_mask[6];
        available[7] = count > 4'd7 && !bad_mask[7];
        prev_available_index = cur;
        case (cur)
            3'd0: if (available[7]) prev_available_index = 3'd7;
                  else if (available[6]) prev_available_index = 3'd6;
                  else if (available[5]) prev_available_index = 3'd5;
                  else if (available[4]) prev_available_index = 3'd4;
                  else if (available[3]) prev_available_index = 3'd3;
                  else if (available[2]) prev_available_index = 3'd2;
                  else if (available[1]) prev_available_index = 3'd1;
            3'd1: if (available[0]) prev_available_index = 3'd0;
                  else if (available[7]) prev_available_index = 3'd7;
                  else if (available[6]) prev_available_index = 3'd6;
                  else if (available[5]) prev_available_index = 3'd5;
                  else if (available[4]) prev_available_index = 3'd4;
                  else if (available[3]) prev_available_index = 3'd3;
                  else if (available[2]) prev_available_index = 3'd2;
            3'd2: if (available[1]) prev_available_index = 3'd1;
                  else if (available[0]) prev_available_index = 3'd0;
                  else if (available[7]) prev_available_index = 3'd7;
                  else if (available[6]) prev_available_index = 3'd6;
                  else if (available[5]) prev_available_index = 3'd5;
                  else if (available[4]) prev_available_index = 3'd4;
                  else if (available[3]) prev_available_index = 3'd3;
            3'd3: if (available[2]) prev_available_index = 3'd2;
                  else if (available[1]) prev_available_index = 3'd1;
                  else if (available[0]) prev_available_index = 3'd0;
                  else if (available[7]) prev_available_index = 3'd7;
                  else if (available[6]) prev_available_index = 3'd6;
                  else if (available[5]) prev_available_index = 3'd5;
                  else if (available[4]) prev_available_index = 3'd4;
            3'd4: if (available[3]) prev_available_index = 3'd3;
                  else if (available[2]) prev_available_index = 3'd2;
                  else if (available[1]) prev_available_index = 3'd1;
                  else if (available[0]) prev_available_index = 3'd0;
                  else if (available[7]) prev_available_index = 3'd7;
                  else if (available[6]) prev_available_index = 3'd6;
                  else if (available[5]) prev_available_index = 3'd5;
            3'd5: if (available[4]) prev_available_index = 3'd4;
                  else if (available[3]) prev_available_index = 3'd3;
                  else if (available[2]) prev_available_index = 3'd2;
                  else if (available[1]) prev_available_index = 3'd1;
                  else if (available[0]) prev_available_index = 3'd0;
                  else if (available[7]) prev_available_index = 3'd7;
                  else if (available[6]) prev_available_index = 3'd6;
            3'd6: if (available[5]) prev_available_index = 3'd5;
                  else if (available[4]) prev_available_index = 3'd4;
                  else if (available[3]) prev_available_index = 3'd3;
                  else if (available[2]) prev_available_index = 3'd2;
                  else if (available[1]) prev_available_index = 3'd1;
                  else if (available[0]) prev_available_index = 3'd0;
                  else if (available[7]) prev_available_index = 3'd7;
            default: if (available[6]) prev_available_index = 3'd6;
                     else if (available[5]) prev_available_index = 3'd5;
                     else if (available[4]) prev_available_index = 3'd4;
                     else if (available[3]) prev_available_index = 3'd3;
                     else if (available[2]) prev_available_index = 3'd2;
                     else if (available[1]) prev_available_index = 3'd1;
                     else if (available[0]) prev_available_index = 3'd0;
        endcase
    end
endfunction

function [2:0] first_available_index;
    input [3:0] count;
    input [7:0] bad_mask;
    integer index;
    reg found;
    begin
        first_available_index = 3'd0;
        found = 1'b0;
        for (index = 0; index < 8; index = index + 1)
            if ((index < count) && !bad_mask[index] && !found) begin
                first_available_index = index[2:0];
                found = 1'b1;
            end
    end
endfunction

function [31:0] sector_lut;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: sector_lut = img_sector0;
            3'd1: sector_lut = img_sector1;
            3'd2: sector_lut = img_sector2;
            3'd3: sector_lut = img_sector3;
            3'd4: sector_lut = img_sector4;
            3'd5: sector_lut = img_sector5;
            3'd6: sector_lut = img_sector6;
            3'd7: sector_lut = img_sector7;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

function [1:0] bank_for_category;
    input [2:0] category;
    begin
        if (bank_owner0 == category)
            bank_for_category = 2'd0;
        else if (bank_owner1 == category)
            bank_for_category = 2'd1;
        else if (bank_owner2 == category)
            bank_for_category = 2'd2;
        else
            bank_for_category = 2'd3;
    end
endfunction

function [2:0] owner_of_bank;
    input [1:0] bank;
    begin
        case (bank)
            2'd0: owner_of_bank = bank_owner0;
            2'd1: owner_of_bank = bank_owner1;
            2'd2: owner_of_bank = bank_owner2;
            default: owner_of_bank = bank_owner3;
        endcase
    end
endfunction

function category_cached;
    input [2:0] category;
    begin
        case (category)
            3'd0: category_cached = category_cache_valid[0];
            3'd1: category_cached = category_cache_valid[1];
            3'd2: category_cached = category_cache_valid[2];
            3'd3: category_cached = category_cache_valid[3];
            default: category_cached = 1'b0;
        endcase
    end
endfunction

function [1:0] replacement_bank;
    input unused;
    begin
        if (!resident_mask[0] && disp_buf_idx != 2'd0)
            replacement_bank = 2'd0;
        else if (!resident_mask[1] && disp_buf_idx != 2'd1)
            replacement_bank = 2'd1;
        else if (!resident_mask[2] && disp_buf_idx != 2'd2)
            replacement_bank = 2'd2;
        else if (!resident_mask[3] && disp_buf_idx != 2'd3)
            replacement_bank = 2'd3;
        else if (disp_buf_idx != 2'd0)
            replacement_bank = 2'd0;
        else if (disp_buf_idx != 2'd1)
            replacement_bank = 2'd1;
        else if (disp_buf_idx != 2'd2)
            replacement_bank = 2'd2;
        else
            replacement_bank = 2'd3;
    end
endfunction

function [1:0] prefetch_bank;
    input unused;
    begin
        if (!resident_mask[0] && disp_buf_idx != 2'd0)
            prefetch_bank = 2'd0;
        else if (!resident_mask[1] && disp_buf_idx != 2'd1)
            prefetch_bank = 2'd1;
        else if (!resident_mask[2] && disp_buf_idx != 2'd2)
            prefetch_bank = 2'd2;
        else if (!resident_mask[3] && disp_buf_idx != 2'd3)
            prefetch_bank = 2'd3;
        else if (disp_buf_idx != 2'd0 &&
            !(category_cached(prev_from_current) &&
              bank_for_category(prev_from_current) == 2'd0) &&
            !(category_cached(next_from_current) &&
              bank_for_category(next_from_current) == 2'd0))
            prefetch_bank = 2'd0;
        else if (disp_buf_idx != 2'd1 &&
                 !(category_cached(prev_from_current) &&
                   bank_for_category(prev_from_current) == 2'd1) &&
                 !(category_cached(next_from_current) &&
                   bank_for_category(next_from_current) == 2'd1))
            prefetch_bank = 2'd1;
        else if (disp_buf_idx != 2'd2 &&
                 !(category_cached(prev_from_current) &&
                   bank_for_category(prev_from_current) == 2'd2) &&
                 !(category_cached(next_from_current) &&
                   bank_for_category(next_from_current) == 2'd2))
            prefetch_bank = 2'd2;
        else
            prefetch_bank = 2'd3;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        navigation_count <= 4'd0;
        next_from_current <= 3'd0;
        prev_from_current <= 3'd0;
        next_from_focus <= 3'd0;
        prev_from_focus <= 3'd0;
        prefetch_from_current <= 3'd0;
        first_available_idx <= 3'd0;
        next_after_failure <= 3'd0;
    end else begin
        navigation_count <= (img_found_count > 4'd4) ? 4'd4 : img_found_count;
        next_from_current <= next_from_current_comb;
        prev_from_current <= prev_from_current_comb;
        next_from_focus <= next_from_focus_comb;
        prev_from_focus <= prev_from_focus_comb;
        prefetch_from_current <= prefetch_from_current_comb;
        first_available_idx <= first_available_idx_comb;
        next_after_failure <= next_after_failure_comb;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_ready_q            <= 1'b0;
        wrfin_tgl_sync        <= 3'b000;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        scan_complete         <= 1'b0;
        scan_retry_pending    <= 1'b0;
        scan_retry_cnt        <= 25'd0;
        first_image_committed <= 1'b0;
        auto_play_en          <= 1'b0;
        auto_cnt              <= 32'd0;
        img_found_count       <= 4'd0;
        img_idx               <= 3'd0;
        load_idx              <= 3'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        img_sector4           <= 32'd0;
        img_sector5           <= 32'd0;
        img_sector6           <= 32'd0;
        img_sector7           <= 32'd0;
        next_req_pending      <= 1'b0;
        prev_req_pending      <= 1'b0;
        prefetch_load         <= 1'b0;
        prefetch_reverse      <= 1'b0;
        prefetch_armed        <= 1'b0;
        cache_valid           <= 1'b0;
        cache_idx             <= 3'd0;
        cache_buf_idx         <= 2'd0;
        load_busy             <= 1'b0;
        load_launch_pending   <= 1'b0;
        load_timeout_cnt      <= 32'd0; load_timeout_hit <= 1'b0;
        load_retry_count      <= 2'd0;
        bad_image_mask        <= 8'b0000_0000;
        resident_mask         <= 4'b0000;
        category_cache_valid  <= 8'b0000_0000;
        photo_asset_ready_reg <= 1'b0;
        photo_asset_boot_done_reg <= 1'b0;
        photo_asset_category  <= 2'd0;
        detail_enter_pending  <= 1'b0;
        bank_owner0           <= 3'd0;
        bank_owner1           <= 3'd0;
        bank_owner2           <= 3'd0;
        bank_owner3           <= 3'd0;
        load_abort            <= 1'b0;
        source_done_seen      <= 1'b0;
        write_done_seen       <= 1'b0;
        ad_state              <= AD_OFF;
        ad_loading            <= 1'b0;
        ad_load_bank          <= 2'd0;
        ad_load_index         <= 2'd0;
        ad_show_bank          <= 2'd0;
        ad_show_index         <= 2'd0;
        ad_bank_a             <= 2'd1;
        ad_bank_b             <= 2'd2;
        ad_return_bank        <= 2'd0;
        ad_bad                <= 4'd0;
        ad_bank_mask          <= 4'd0;
        ad_zoom_level         <= 3'd0;
        ad_load_level         <= 3'd0;
        ad_show_level         <= 3'd0;
        ad_key_mask           <= 1'b0;
        display_valid         <= 1'b0;
        thumbnail_exit_toggle <= 1'b0;
        thumbnail_req_pending <= 1'b0;
        manual_reload_pending  <= 1'b0;
        manual_reload_idx      <= 3'd0;
        menu_state             <= MENU_CATEGORY;
        dish_index             <= 2'd0;
        category_return_idx    <= 3'd0;
    end else begin
        bmp_ready_q       <= bmp_ready;
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_abort       <= 1'b0;

        if (load_launch_pending && bmp_ready_q && !sd_active) begin
            load_sector         <= ad_loading ? {28'd0, 2'b10, ad_load_index} : sector_lut(load_idx);
            load_start_pulse    <= 1'b1;
            load_launch_pending <= 1'b0;
        end

        if (scan_done) begin
            if (scan_found_total == 4'd0 && !display_valid) begin
                scan_complete      <= 1'b0;
                scan_retry_pending <= 1'b1;
                scan_retry_cnt     <= 25'd0;
            end else begin
                scan_complete      <= 1'b1;
                scan_retry_pending <= 1'b0;
                scan_retry_cnt     <= 25'd0;
                if (scan_found_total < 4'd5)
                    photo_asset_boot_done_reg <= 1'b1;
                if (display_valid)
                    prefetch_armed <= 1'b1;
            end
        end

        if (scan_retry_pending) begin
            if (scan_retry_cnt >= SCAN_RETRY_CYCLES - 1 && bmp_ready_q && !sd_active) begin
                scan_retry_pending <= 1'b0;
                scan_retry_cnt     <= 25'd0;
                scan_kicked        <= 1'b0;
            end else begin
                scan_retry_cnt <= scan_retry_cnt + 25'd1;
            end
        end

        if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            scan_complete         <= 1'b0;
            scan_retry_pending    <= 1'b0;
            scan_retry_cnt        <= 25'd0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 4'd0;
            img_idx               <= 3'd0;
            load_idx              <= 3'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            img_sector4           <= 32'd0;
            img_sector5           <= 32'd0;
            img_sector6           <= 32'd0;
            img_sector7           <= 32'd0;
            next_req_pending      <= 1'b0;
            prev_req_pending      <= 1'b0;
            prefetch_load         <= 1'b0;
            prefetch_reverse      <= 1'b0;
            prefetch_armed        <= 1'b0;
            cache_valid           <= 1'b0;
            cache_idx             <= 2'd0;
            cache_buf_idx         <= 2'd0;
            load_busy             <= 1'b0;
            load_launch_pending   <= 1'b0;
            load_timeout_cnt      <= 32'd0; load_timeout_hit <= 1'b0;
            load_retry_count      <= 2'd0;
            bad_image_mask        <= 8'b0000_0000;
            resident_mask         <= 4'b0000;
            category_cache_valid  <= 8'b0000_0000;
            photo_asset_ready_reg <= 1'b0;
            photo_asset_boot_done_reg <= 1'b0;
            photo_asset_category  <= 2'd0;
            detail_enter_pending  <= 1'b0;
            bank_owner0           <= 3'd0;
            bank_owner1           <= 3'd0;
            bank_owner2           <= 3'd0;
            bank_owner3           <= 3'd0;
            load_abort            <= 1'b0;
            source_done_seen      <= 1'b0;
            write_done_seen       <= 1'b0;
            ad_state              <= AD_OFF;
            ad_loading            <= 1'b0;
            ad_load_bank          <= 2'd0;
            ad_load_index         <= 2'd0;
            ad_show_bank          <= 2'd0;
            ad_show_index         <= 2'd0;
            ad_bank_a             <= 2'd1;
            ad_bank_b             <= 2'd2;
            ad_return_bank        <= 2'd0;
            ad_bad                <= 4'd0;
            ad_bank_mask          <= 4'd0;
            ad_zoom_level         <= 3'd0;
            ad_load_level         <= 3'd0;
            ad_show_level         <= 3'd0;
            ad_key_mask           <= 1'b0;
            manual_reload_pending <= 1'b0;
            manual_reload_idx     <= 3'd0;
            menu_state             <= MENU_CATEGORY;
            dish_index             <= 2'd0;
            category_return_idx    <= 3'd0;
            display_valid         <= 1'b0;
        end else begin
            // 扫描阶段缓存前 4 张图的起始 sector
            if (scan_found_valid) begin
                case (img_found_count)
                    4'd0: img_sector0 <= scan_found_sector;
                    4'd1: img_sector1 <= scan_found_sector;
                    4'd2: img_sector2 <= scan_found_sector;
                    4'd3: img_sector3 <= scan_found_sector;
                    4'd4: img_sector4 <= scan_found_sector;
                    4'd5: img_sector5 <= scan_found_sector;
                    4'd6: img_sector6 <= scan_found_sector;
                    4'd7: img_sector7 <= scan_found_sector;
                    default: ;
                endcase

                if (img_found_count < 4'd8)
                    img_found_count <= img_found_count + 4'd1;
            end

            // 记住 bmp_read 已经把源图送完 FIFO，但还不能切显示，得等整帧写完
            if (load_busy && load_done)
                source_done_seen <= 1'b1;

            // 记住写帧完成脉冲，避免“先写完后源结束”导致脉冲丢失而卡死
            if (load_busy && write_finish_pulse)
                write_done_seen <= 1'b1;

            // 只有“源图送完 + 整帧写完”都满足，才提交新图并切换显示缓冲区
            if (load_busy && load_error) begin
                load_timeout_cnt <= 32'd0; load_timeout_hit <= 1'b0;
                source_done_seen <= 1'b0;
                write_done_seen  <= 1'b0;
                cache_valid      <= 1'b0;
                if (load_retry_count < MAX_LOAD_RETRIES) begin
                    load_retry_count <= load_retry_count + 2'd1;
                    load_launch_pending <= 1'b1;
                end else if (ad_loading) begin
                    // A poster that cannot be read is skipped from now on.
                    load_busy        <= 1'b0;
                    load_retry_count <= 2'd0;
                    ad_loading       <= 1'b0;
                    ad_bad[ad_load_index] <= 1'b1;
                    if (ad_state == AD_FIRST) begin
                        ad_state       <= AD_OFF;
                        prefetch_armed <= 1'b1;
                    end else begin
                        ad_state <= AD_SHOW;
                    end
                end else begin
                    load_busy        <= 1'b0;
                    load_retry_count <= 2'd0;
                    bad_image_mask[load_idx] <= 1'b1;
                    if (load_idx >= 3'd4) begin
                        photo_asset_ready_reg <= 1'b0;
                        detail_enter_pending <= 1'b0;
                    end
                    if (load_idx == 3'd4)
                        photo_asset_boot_done_reg <= 1'b1;
                    prefetch_load    <= 1'b0;
                    prefetch_armed   <= display_valid;
                    if (auto_play_en && display_valid &&
                        (next_after_failure != img_idx)) begin
                        next_req_pending <= 1'b1;
                    end else if (auto_play_en && display_valid) begin
                        auto_play_en <= 1'b0;
                    end
                end
            end else if (load_busy && ad_loading && source_done_seen && write_done_seen) begin
                // Poster complete: show it (the video side fades from the centre).
                load_busy        <= 1'b0;
                load_timeout_cnt <= 32'd0; load_timeout_hit <= 1'b0;
                load_retry_count <= 2'd0;
                source_done_seen <= 1'b0;
                write_done_seen  <= 1'b0;
                ad_loading       <= 1'b0;
                ad_state         <= AD_SHOW;
                ad_show_bank     <= ad_load_bank;
                ad_show_index    <= ad_load_index;
                ad_show_level    <= ad_load_level;
                disp_buf_idx     <= ad_load_bank;
                ad_key_mask      <= 1'b1;
            end else if (load_busy && source_done_seen && write_done_seen) begin
                load_busy             <= 1'b0;
                load_timeout_cnt      <= 32'd0; load_timeout_hit <= 1'b0;
                load_retry_count      <= 2'd0;
                bad_image_mask[load_idx] <= 1'b0;
                if (load_idx >= 3'd4) begin
                    photo_asset_ready_reg <= 1'b1;
                    photo_asset_category <= load_idx - 3'd4;
                    photo_asset_boot_done_reg <= 1'b1;
                end else begin
                    category_cache_valid[load_idx] <= 1'b1;
                    resident_mask[pending_buf_idx] <= 1'b1;
                    ad_bank_mask[pending_buf_idx] <= 1'b0;
                    case (pending_buf_idx)
                    2'd0: begin
                        if (resident_mask[0]) category_cache_valid[bank_owner0] <= 1'b0;
                        bank_owner0 <= load_idx;
                    end
                    2'd1: begin
                        if (resident_mask[1]) category_cache_valid[bank_owner1] <= 1'b0;
                        bank_owner1 <= load_idx;
                    end
                    2'd2: begin
                        if (resident_mask[2]) category_cache_valid[bank_owner2] <= 1'b0;
                        bank_owner2 <= load_idx;
                    end
                    default: begin
                        if (resident_mask[3]) category_cache_valid[bank_owner3] <= 1'b0;
                        bank_owner3 <= load_idx;
                    end
                    endcase
                end
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
                if (load_idx >= 3'd4) begin
                    prefetch_load  <= 1'b0;
                    prefetch_armed <= 1'b0;
                    cache_valid    <= 1'b0;
                    if (detail_enter_pending &&
                        load_idx == {1'b1, category_return_idx[1:0]}) begin
                        menu_state <= MENU_DISH;
                        detail_enter_pending <= 1'b0;
                    end
                end else if (prefetch_load && !prefetch_claim_next && !prefetch_claim_prev) begin
                    prefetch_load <= 1'b0;
                    prefetch_armed <= (resident_mask != 4'hf);
                    cache_valid    <= 1'b0;
                end else begin
                    disp_buf_idx          <= pending_buf_idx;
                    img_idx               <= load_idx;
                    if (load_idx >= 3'd4)
                        dish_index <= load_idx - 3'd4;
                    display_valid         <= 1'b1;
                    first_image_committed <= 1'b1;
                    prefetch_armed        <= 1'b1;
                    cache_valid           <= 1'b0;
                end
            end else if (load_busy) begin
                if (bmp_data_wr_en || load_done || write_finish_pulse || write_en) begin
                    load_timeout_cnt <= 32'd0; load_timeout_hit <= 1'b0;
                end else if (load_timeout_hit) begin
                    // 超时（例如读到坏图或截断的文件导致死锁），强制释放 busy 以恢复按键响应
                    load_launch_pending   <= 1'b0;
                    load_timeout_cnt      <= 32'd0; load_timeout_hit <= 1'b0;
                    source_done_seen      <= 1'b0;
                    write_done_seen       <= 1'b0;
                    load_abort            <= 1'b1;
                    cache_valid           <= 1'b0;
                    if (load_retry_count < MAX_LOAD_RETRIES) begin
                        load_retry_count   <= load_retry_count + 2'd1;
                        load_launch_pending <= 1'b1;
                    end else if (ad_loading) begin
                        load_busy        <= 1'b0;
                        load_retry_count <= 2'd0;
                        ad_loading       <= 1'b0;
                        ad_bad[ad_load_index] <= 1'b1;
                        if (ad_state == AD_FIRST) begin
                            ad_state       <= AD_OFF;
                            prefetch_armed <= 1'b1;
                        end else begin
                            ad_state <= AD_SHOW;
                        end
                    end else begin
                        load_busy             <= 1'b0;
                        load_retry_count      <= 2'd0;
                        bad_image_mask[load_idx] <= 1'b1;
                        prefetch_load         <= 1'b0;
                        prefetch_armed        <= display_valid;
                        if (load_idx >= 3'd4) begin
                            photo_asset_ready_reg  <= 1'b0;
                            detail_enter_pending   <= 1'b0;
                        end
                        if (load_idx == 3'd4) begin
                            photo_asset_boot_done_reg <= 1'b1;
                        end else if (auto_play_en && display_valid &&
                                     (next_after_failure != img_idx)) begin
                            next_req_pending <= 1'b1;
                        end else if (auto_play_en && display_valid) begin
                            auto_play_en <= 1'b0;
                        end
                    end
                end else begin
                    load_timeout_cnt <= load_timeout_cnt + 32'd1;
                    load_timeout_hit <= load_timeout_cnt >= LOAD_STALL_TIMEOUT_CYCLES - 2;
                end
            end else begin
                load_timeout_cnt <= 32'd0; load_timeout_hit <= 1'b0;
            end

            // 上电后自动发起一次“扫描前 4 张 BMP”
            if (!scan_kicked && bmp_ready_q) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                scan_complete         <= 1'b0;
                scan_retry_pending    <= 1'b0;
                scan_retry_cnt        <= 25'd0;
                first_image_committed <= display_valid;
                auto_cnt              <= 32'd0;
                img_found_count       <= 4'd0;
                bad_image_mask        <= 8'b0000_0000;
                category_cache_valid  <= 8'b0000_0000;
                photo_asset_ready_reg <= 1'b0;
                photo_asset_boot_done_reg <= 1'b0;
                photo_asset_category  <= 2'd0;
                detail_enter_pending  <= 1'b0;
                resident_mask         <= 4'b0000;
                bank_owner0           <= 3'd0;
                bank_owner1           <= 3'd0;
                bank_owner2           <= 3'd0;
                bank_owner3           <= 3'd0;
                load_idx              <= 3'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;
                next_req_pending      <= 1'b0;
                prev_req_pending      <= 1'b0;
                prefetch_load         <= 1'b0;
                prefetch_reverse      <= 1'b0;
                prefetch_armed        <= display_valid;
                cache_valid           <= 1'b0;
                cache_idx             <= 3'd0;
                cache_buf_idx         <= 2'd0;
                load_busy             <= 1'b0;
                load_launch_pending   <= 1'b0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
                manual_reload_pending <= 1'b0;
                manual_reload_idx     <= 3'd0;
                if (!display_valid) begin
                    auto_play_en <= 1'b0;
                    img_idx      <= 3'd0;
                    disp_buf_idx <= 2'd0;
                end else begin
                    // A scan restart does not invalidate the frame currently on screen.
                    resident_mask[disp_buf_idx] <= 1'b1;
                    category_cache_valid[img_idx] <= 1'b1;
                    case (disp_buf_idx)
                        2'd0: bank_owner0 <= img_idx;
                        2'd1: bank_owner1 <= img_idx;
                        2'd2: bank_owner2 <= img_idx;
                        default: bank_owner3 <= img_idx;
                    endcase
                end
            end else begin
                if (!thumbnail_mode && display_valid && key_confirm_press &&
                    menu_state == MENU_CATEGORY && img_idx < 3'd4 &&
                    navigation_count >= 4'd4) begin
                    dish_index <= 2'd0;
                    category_return_idx <= img_idx;
                    if (photo_asset_ready_reg && photo_asset_category == img_idx[1:0]) begin
                        menu_state <= MENU_DISH;
                        detail_enter_pending <= 1'b0;
                    end else if (img_found_count > {2'b01, img_idx[1:0]}) begin
                        detail_enter_pending <= 1'b1;
                        bad_image_mask[{1'b1, img_idx[1:0]}] <= 1'b0;
                    end else begin
                        detail_enter_pending <= 1'b0;
                    end
                    auto_play_en <= 1'b0;
                    auto_cnt <= 32'd0;
                    next_req_pending <= 1'b0;
                    prev_req_pending <= 1'b0;
                end else if (!thumbnail_mode && display_valid && key_back_press &&
                             menu_state == MENU_ORDER) begin
                    menu_state <= MENU_DISH;
                end else if (!thumbnail_mode && display_valid && dish_return_pulse &&
                             menu_state == MENU_DISH) begin
                    menu_state <= MENU_CATEGORY;
                    auto_play_en <= 1'b0;
                    auto_cnt <= 32'd0;
                    next_req_pending <= 1'b0;
                    prev_req_pending <= 1'b0;
                end else if (!thumbnail_mode && display_valid && key_next_press &&
                             menu_state == MENU_DISH) begin
                    dish_index <= dish_index + 2'd1;
                end else if (!thumbnail_mode && display_valid && key_prev_press &&
                             menu_state == MENU_DISH) begin
                    dish_index <= dish_index - 2'd1;
                end

                if (menu_state == MENU_CATEGORY && key_auto_press &&
                    display_valid && (navigation_count > 4'd1)) begin
                    auto_play_en <= ~auto_play_en;
                    auto_cnt     <= 32'd0;
                end

                if (prev_press_valid) begin
                    detail_enter_pending <= 1'b0;
                    if (prefetch_claim_prev) begin
                        prev_req_pending <= 1'b0;
                        next_req_pending <= 1'b0;
                        prefetch_load    <= 1'b0;
                    end else begin
                        prev_req_pending <= 1'b1;
                        next_req_pending <= 1'b0;
                    end
                    prefetch_reverse <= 1'b1;
                end

                // 忙的时候也只记 1 次“下一张”请求，不会累积成连跳两张
                if (next_press_valid) begin
                    detail_enter_pending <= 1'b0;
                    if (prefetch_claim_next) begin
                        next_req_pending <= 1'b0;
                        prev_req_pending <= 1'b0;
                        prefetch_load    <= 1'b0;
                    end else begin
                        next_req_pending <= 1'b1;
                        prev_req_pending <= 1'b0;
                    end
                    prefetch_reverse <= 1'b0;
                end

                // 用户请求优先于后台预取；中止后保留当前画面，等待 SD 通道完全空闲再重载
                if (load_busy && display_valid && key_confirm_press &&
                    !thumbnail_mode && menu_state == MENU_CATEGORY &&
                    load_idx != {1'b1, img_idx[1:0]}) begin
                    load_abort          <= 1'b1;
                    load_busy           <= 1'b0;
                    load_launch_pending <= 1'b0;
                    load_timeout_cnt    <= 32'd0; load_timeout_hit <= 1'b0;
                    load_retry_count    <= 2'd0;
                    source_done_seen    <= 1'b0;
                    write_done_seen     <= 1'b0;
                    prefetch_load       <= 1'b0;
                    prefetch_armed      <= 1'b0;
                    cache_valid         <= 1'b0;
                end else if (load_busy && display_valid && next_press_valid &&
                    !prefetch_claim_next && (next_from_current != load_idx)) begin
                    load_abort          <= 1'b1;
                    load_busy           <= 1'b0;
                    load_launch_pending <= 1'b0;
                    load_timeout_cnt    <= 32'd0; load_timeout_hit <= 1'b0;
                    load_retry_count    <= 2'd0;
                    source_done_seen    <= 1'b0;
                    write_done_seen     <= 1'b0;
                    prefetch_load       <= 1'b0;
                    prefetch_armed      <= 1'b0;
                    cache_valid         <= 1'b0;
                    if (category_cached(next_from_current)) begin
                        manual_reload_pending <= 1'b0;
                    end else begin
                        manual_reload_pending <= 1'b1;
                        manual_reload_idx     <= next_from_current;
                        next_req_pending      <= 1'b0;
                    end
                end else if (load_busy && display_valid && prev_press_valid &&
                             !prefetch_claim_prev && (prev_from_current != load_idx)) begin
                    load_abort          <= 1'b1;
                    load_busy           <= 1'b0;
                    load_launch_pending <= 1'b0;
                    load_timeout_cnt    <= 32'd0; load_timeout_hit <= 1'b0;
                    load_retry_count    <= 2'd0;
                    source_done_seen    <= 1'b0;
                    write_done_seen     <= 1'b0;
                    prefetch_load       <= 1'b0;
                    prefetch_armed      <= 1'b0;
                    cache_valid         <= 1'b0;
                    if (category_cached(prev_from_current)) begin
                        manual_reload_pending <= 1'b0;
                    end else begin
                        manual_reload_pending <= 1'b1;
                        manual_reload_idx     <= prev_from_current;
                        prev_req_pending      <= 1'b0;
                    end
                end else if (load_busy && display_valid && thumbnail_req_pending &&
                             (cache_idx != load_idx)) begin
                    load_abort          <= 1'b1;
                    load_busy           <= 1'b0;
                    load_launch_pending <= 1'b0;
                    load_timeout_cnt    <= 32'd0; load_timeout_hit <= 1'b0;
                    load_retry_count    <= 2'd0;
                    source_done_seen    <= 1'b0;
                    write_done_seen     <= 1'b0;
                    prefetch_load       <= 1'b0;
                    prefetch_armed      <= 1'b0;
                    cache_valid         <= 1'b0;
                    if (category_cached(cache_idx)) begin
                        manual_reload_pending <= 1'b0;
                    end else begin
                        manual_reload_pending <= 1'b1;
                        manual_reload_idx     <= cache_idx;
                        thumbnail_req_pending <= 1'b0;
                    end
                end

                // 自动播放 1s 计数：只有当前没有写图任务时才计时
                if (key_auto_press) begin
                    auto_cnt <= 32'd0;
                end else if (menu_state == MENU_CATEGORY && scan_complete &&
                             auto_play_en && display_valid && !load_busy &&
                              first_image_committed && (navigation_count > 4'd1)) begin
                    if (auto_tick && (next_from_current != img_idx) &&
                        !bad_image_mask[next_from_current])
                        auto_cnt <= 32'd0;
                    else if (!auto_tick)
                        auto_cnt <= auto_cnt + 32'd1;
                end else begin
                    auto_cnt <= 32'd0;
                end

                // The advert player owns the loader while it is open.
                if (ad_state == AD_OFF && ad_trigger) begin
                    ad_state        <= AD_FIRST;
                    ad_loading      <= 1'b1;
                    ad_load_index   <= ad_wanted;
                    ad_load_level   <= 3'd0;
                    ad_load_bank    <= disp_buf_idx + 2'd1;
                    ad_bank_a       <= disp_buf_idx + 2'd1;
                    ad_bank_b       <= disp_buf_idx + 2'd2;
                    ad_return_bank  <= disp_buf_idx;
                    ad_zoom_level   <= 3'd0;
                    ad_bank_mask[disp_buf_idx + 2'd1] <= 1'b1;
                    resident_mask[disp_buf_idx + 2'd1] <= 1'b0;
                    if (resident_mask[disp_buf_idx + 2'd1])
                        category_cache_valid[owner_of_bank(disp_buf_idx + 2'd1)] <= 1'b0;
                    pending_buf_idx <= disp_buf_idx + 2'd1;
                    write_buf_idx   <= disp_buf_idx + 2'd1;
                    load_busy       <= 1'b1;
                    load_launch_pending <= 1'b1;
                    load_retry_count <= 2'd0;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    prefetch_load    <= 1'b0;
                    prefetch_armed   <= 1'b0;
                    cache_valid      <= 1'b0;
                end else if (ad_state == AD_FIRST) begin
                    // Any key before the poster appears cancels it; the key
                    // then acts normally (its debounced press comes later).
                    if (ad_any_key && load_busy) begin
                        load_abort          <= 1'b1;
                        load_busy           <= 1'b0;
                        load_launch_pending <= 1'b0;
                        load_timeout_cnt    <= 32'd0; load_timeout_hit <= 1'b0;
                        load_retry_count    <= 2'd0;
                        source_done_seen    <= 1'b0;
                        write_done_seen     <= 1'b0;
                        ad_loading          <= 1'b0;
                        ad_state            <= AD_OFF;
                        prefetch_armed      <= 1'b1;
                    end
                end else if (ad_state != AD_OFF) begin
                    if (ad_key_press[3]) begin
                        // K4: back to the screen the player interrupted.
                        if (load_busy) begin
                            load_abort          <= 1'b1;
                            load_busy           <= 1'b0;
                            load_launch_pending <= 1'b0;
                            load_timeout_cnt    <= 32'd0; load_timeout_hit <= 1'b0;
                            load_retry_count    <= 2'd0;
                            source_done_seen    <= 1'b0;
                            write_done_seen     <= 1'b0;
                        end
                        ad_loading     <= 1'b0;
                        ad_state       <= AD_OFF;
                        disp_buf_idx   <= ad_return_bank;
                        prefetch_armed <= 1'b1;
                        cache_valid    <= 1'b0;
                    end else begin
                        if (ad_key_press[1] && ad_zoom_level != 3'd5)
                            ad_zoom_level <= ad_zoom_level + 3'd1;
                        else if (ad_key_press[2] && ad_zoom_level != 3'd0)
                            ad_zoom_level <= ad_zoom_level - 3'd1;
                        // A new kitchen selection or a new size (K2 smaller, K3
                        // larger) is rendered into the other poster bank and
                        // then shown; the video side fades it in from the centre.
                        if (ad_state == AD_SHOW && bmp_ready_q && !sd_active &&
                            ((ad_wanted != ad_show_index && ad_found[ad_wanted] && !ad_bad[ad_wanted]) ||
                             ad_zoom_level != ad_show_level)) begin
                            ad_state        <= AD_SWITCH;
                            ad_loading      <= 1'b1;
                            ad_load_index   <= (ad_found[ad_wanted] && !ad_bad[ad_wanted]) ?
                                               ad_wanted : ad_show_index;
                            ad_load_level   <= ad_zoom_level;
                            ad_load_bank    <= (ad_show_bank == ad_bank_a) ? ad_bank_b : ad_bank_a;
                            ad_bank_mask[(ad_show_bank == ad_bank_a) ? ad_bank_b : ad_bank_a] <= 1'b1;
                            resident_mask[(ad_show_bank == ad_bank_a) ? ad_bank_b : ad_bank_a] <= 1'b0;
                            if (resident_mask[(ad_show_bank == ad_bank_a) ? ad_bank_b : ad_bank_a])
                                category_cache_valid[owner_of_bank((ad_show_bank == ad_bank_a) ?
                                                                   ad_bank_b : ad_bank_a)] <= 1'b0;
                            pending_buf_idx <= (ad_show_bank == ad_bank_a) ? ad_bank_b : ad_bank_a;
                            write_buf_idx   <= (ad_show_bank == ad_bank_a) ? ad_bank_b : ad_bank_a;
                            load_busy       <= 1'b1;
                            load_launch_pending <= 1'b1;
                            load_retry_count <= 2'd0;
                            source_done_seen <= 1'b0;
                            write_done_seen  <= 1'b0;
                        end
                    end
                end
                // Load the first valid image into its permanent frame bank.
                else if (scan_complete && !first_image_committed && bmp_ready_q && !load_busy && playable_available) begin
                    load_idx         <= first_available_idx;
                    pending_buf_idx  <= (resident_mask == 4'b0000) ? 2'd0 : replacement_bank(1'b0);
                    write_buf_idx    <= (resident_mask == 4'b0000) ? 2'd0 : replacement_bank(1'b0);
                    load_busy        <= 1'b1;
                    load_launch_pending <= 1'b1;
                    load_retry_count <= 2'd0;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    next_req_pending <= 1'b0;
                    prev_req_pending <= 1'b0;
                    prefetch_armed   <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                else if (scan_complete && bmp_ready_q && !sd_active && display_valid &&
                         !load_busy && manual_reload_pending) begin
                    load_idx         <= manual_reload_idx;
                    pending_buf_idx  <= replacement_bank(1'b0);
                    write_buf_idx    <= replacement_bank(1'b0);
                    load_busy        <= 1'b1;
                    load_launch_pending <= 1'b1;
                    load_retry_count <= 2'd0;
                    prefetch_load    <= 1'b0;
                    prefetch_armed   <= 1'b0;
                    cache_valid      <= 1'b0;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    manual_reload_pending <= 1'b0;
                    thumbnail_req_pending <= 1'b0;
                    next_req_pending <= 1'b0;
                    prev_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                else if (scan_complete && bmp_ready_q && !sd_active && display_valid &&
                         !load_busy && detail_enter_pending &&
                         img_found_count > {2'b01, category_return_idx[1:0]} &&
                         !bad_image_mask[{1'b1, category_return_idx[1:0]}]) begin
                    load_idx            <= {1'b1, category_return_idx[1:0]};
                    pending_buf_idx     <= 2'd0;
                    write_buf_idx       <= 2'd0;
                    load_busy           <= 1'b1;
                    load_launch_pending <= 1'b1;
                    load_retry_count    <= 2'd0;
                    prefetch_load       <= 1'b0;
                    prefetch_armed      <= 1'b0;
                    cache_valid         <= 1'b0;
                    source_done_seen    <= 1'b0;
                    write_done_seen     <= 1'b0;
                    photo_asset_ready_reg <= 1'b0;
                    auto_cnt            <= 32'd0;
                end
                else if (scan_complete && bmp_ready_q && display_valid && !load_busy && thumbnail_req_pending) begin
                    if (category_cached(cache_idx)) begin
                        disp_buf_idx <= bank_for_category(cache_idx);
                        img_idx      <= cache_idx;
                        if (cache_idx >= 3'd4)
                            dish_index <= cache_idx - 3'd4;
                        prefetch_armed <= 1'b1;
                    end else begin
                        load_idx         <= cache_idx;
                        pending_buf_idx  <= replacement_bank(1'b0);
                        write_buf_idx    <= replacement_bank(1'b0);
                        load_busy        <= 1'b1;
                        load_launch_pending <= 1'b1;
                        load_retry_count  <= 2'd0;
                        prefetch_load     <= 1'b0;
                        prefetch_armed    <= 1'b0;
                        source_done_seen  <= 1'b0;
                        write_done_seen   <= 1'b0;
                    end
                    thumbnail_req_pending <= 1'b0;
                    auto_cnt <= 32'd0;
                end
                // A resident image switches immediately; otherwise load its permanent bank.
                else if (scan_complete && bmp_ready_q && display_valid && !load_busy && next_req_pending &&
                         (navigation_count != 4'd0) && (next_from_current != img_idx) &&
                         !bad_image_mask[next_from_current]) begin
                    if (category_cached(next_from_current)) begin
                        disp_buf_idx <= bank_for_category(next_from_current);
                        img_idx      <= next_from_current;
                        if (next_from_current >= 3'd4)
                            dish_index <= next_from_current - 3'd4;
                        cache_valid  <= 1'b0;
                        prefetch_armed <= 1'b1;
                    end else begin
                        load_idx         <= next_from_current;
                        pending_buf_idx  <= replacement_bank(1'b0);
                        write_buf_idx    <= replacement_bank(1'b0);
                        load_busy        <= 1'b1;
                        load_launch_pending <= 1'b1;
                        load_retry_count <= 2'd0;
                        prefetch_load    <= 1'b0;
                        prefetch_armed   <= 1'b0;
                        cache_valid      <= 1'b0;
                        source_done_seen <= 1'b0;
                        write_done_seen  <= 1'b0;
                    end
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 手动上一张：下一张请求优先，上一张请求可在忙时挂起
                else if (scan_complete && bmp_ready_q && display_valid && !load_busy && prev_req_pending &&
                          (navigation_count > 4'd1) && (prev_from_current != img_idx) &&
                         !bad_image_mask[prev_from_current]) begin
                    if (category_cached(prev_from_current)) begin
                        disp_buf_idx <= bank_for_category(prev_from_current);
                        img_idx      <= prev_from_current;
                        if (prev_from_current >= 3'd4)
                            dish_index <= prev_from_current - 3'd4;
                        cache_valid  <= 1'b0;
                        prefetch_armed <= 1'b1;
                    end else begin
                        load_idx         <= prev_from_current;
                        pending_buf_idx  <= replacement_bank(1'b0);
                        write_buf_idx     <= replacement_bank(1'b0);
                        load_busy         <= 1'b1;
                        load_launch_pending <= 1'b1;
                        load_retry_count  <= 2'd0;
                        prefetch_load     <= 1'b0;
                        prefetch_armed    <= 1'b0;
                        cache_valid       <= 1'b0;
                        source_done_seen  <= 1'b0;
                        write_done_seen   <= 1'b0;
                    end
                    prev_req_pending  <= 1'b0;
                    auto_cnt          <= 32'd0;
                end
                // Automatic playback uses the same resident-bank path.
                else if (menu_state == MENU_CATEGORY && scan_complete && bmp_ready_q &&
                         display_valid && !load_busy && auto_play_en && auto_tick &&
                         !key_auto_press && !key_next_press && !key_prev_press && (navigation_count > 4'd1) &&
                         (next_from_current != img_idx) && !bad_image_mask[next_from_current]) begin
                    prefetch_reverse <= 1'b0;
                    if (category_cached(next_from_current)) begin
                        disp_buf_idx <= bank_for_category(next_from_current);
                        img_idx      <= next_from_current;
                        cache_valid  <= 1'b0;
                        prefetch_armed <= 1'b1;
                    end else begin
                        load_idx         <= next_from_current;
                        pending_buf_idx  <= replacement_bank(1'b0);
                        write_buf_idx    <= replacement_bank(1'b0);
                        load_busy        <= 1'b1;
                        load_launch_pending <= 1'b1;
                        load_retry_count <= 2'd0;
                        prefetch_load    <= 1'b0;
                        prefetch_armed   <= 1'b0;
                        cache_valid      <= 1'b0;
                        source_done_seen <= 1'b0;
                        write_done_seen  <= 1'b0;
                    end
                    auto_cnt         <= 32'd0;
                end
                else if (scan_complete && bmp_ready_q && display_valid && !load_busy &&
                         first_image_committed && category_cache_valid[3:0] == 4'hf &&
                         !photo_asset_boot_done_reg && img_found_count >= 4'd5 &&
                         !bad_image_mask[4]) begin
                    load_idx            <= 3'd4;
                    pending_buf_idx     <= 2'd0;
                    write_buf_idx       <= 2'd0;
                    load_busy           <= 1'b1;
                    load_launch_pending <= 1'b1;
                    load_retry_count    <= 2'd0;
                    prefetch_load       <= 1'b0;
                    prefetch_armed      <= 1'b0;
                    cache_valid         <= 1'b0;
                    source_done_seen    <= 1'b0;
                    write_done_seen     <= 1'b0;
                end
                else if (scan_complete && bmp_ready_q && display_valid && !load_busy && first_image_committed &&
                           prefetch_armed && !next_req_pending && !prev_req_pending && !cache_valid &&
                             (menu_state == MENU_CATEGORY) && !thumbnail_mode &&
                            !key_next_press && !key_prev_press && !key_auto_press &&
                            !key_confirm_press && !key_back_press &&
                             (navigation_count > 4'd1) &&
                          preload_available && !bad_image_mask[prefetch_from_current] &&
                          !category_cached(prefetch_from_current) &&
                          (prefetch_from_current != img_idx)) begin
                    load_idx         <= prefetch_from_current;
                    pending_buf_idx  <= prefetch_bank(1'b0);
                    write_buf_idx    <= prefetch_bank(1'b0);
                    load_busy        <= 1'b1;
                    load_launch_pending <= 1'b1;
                    load_retry_count <= 2'd0;
                    prefetch_load    <= 1'b1;
                    prefetch_armed   <= 1'b0;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                end
            end
            if (ad_state == AD_OFF && !ad_any_key && ad_key_stable == 4'hf)
                ad_key_mask <= 1'b0;
            if (thumbnail_enter_pulse) begin
                auto_play_en <= 1'b0;
                auto_cnt <= 32'd0;
                next_req_pending <= 1'b0;
                prev_req_pending <= 1'b0;
            end else if (thumbnail_select_pulse) begin
                auto_play_en <= 1'b0;
                auto_cnt <= 32'd0;
                next_req_pending <= 1'b0;
                prev_req_pending <= 1'b0;
                cache_idx <= thumbnail_focus_idx;
                thumbnail_req_pending <= 1'b1;
                thumbnail_exit_toggle <= ~thumbnail_exit_toggle;
            end else if (thumbnail_cancel_pulse) begin
                auto_play_en <= 1'b0;
                auto_cnt <= 32'd0;
                next_req_pending <= 1'b0;
                prev_req_pending <= 1'b0;
                thumbnail_req_pending <= 1'b0;
                thumbnail_exit_toggle <= ~thumbnail_exit_toggle;
            end
        end
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        audio_available <= 1'b0;
        audio_start_lba <= 32'd0;
        audio_total_sectors <= 32'd0;
        sd_active <= 1'b0;
        sd_owner_audio <= 1'b0;
        image_read_hold <= 1'b0;
        image_read_addr <= 32'd0;
        audio_byte_count <= 10'd0;
        audio_done_reg <= 1'b0;
        audio_error_reg <= 8'd0;
    end else begin
        if (sd_active && !sd_owner_audio && sd_sec_read && !image_read_hold)
            image_read_addr <= sd_sec_read_addr;
        if (!sd_active || sd_sec_read_end)
            image_read_hold <= 1'b0;
        else if (load_abort && !sd_owner_audio)
            image_read_hold <= 1'b1;
        if (audio_available_i) begin
            audio_available <= 1'b1;
            audio_start_lba <= audio_start_lba_i;
            audio_total_sectors <= audio_total_sectors_i;
        end
        audio_done_reg <= 1'b0;
        audio_error_reg <= 8'd0;
        // load_abort only abandons the image load bookkeeping; the BMP reader
        // and the SD sector controller both finish the sector in flight.
        // Releasing ownership here would hand the rest of that sector (and its
        // read_end) to the other requester and leave the WAV player waiting
        // forever for sd_done.
        if (!sd_active) begin
            audio_byte_count <= 10'd0;
            if (sd_sec_read) begin
                sd_active <= 1'b1;
                sd_owner_audio <= 1'b0;
            end else if (audio_sd_req) begin
                sd_active <= 1'b1;
                sd_owner_audio <= 1'b1;
            end
        end else if (sd_sec_read_end) begin
            if (sd_owner_audio) begin
                audio_done_reg <= 1'b1;
                audio_error_reg <= (audio_byte_count == 10'd512) ? 8'd0 : 8'h12;
            end
            sd_active <= 1'b0;
            sd_owner_audio <= 1'b0;
            audio_byte_count <= 10'd0;
        end else if (sd_owner_audio && sd_sec_read_data_valid) begin
            if (audio_byte_count < 10'd512)
                audio_byte_count <= audio_byte_count + 1'b1;
        end
    end
end

fat32_bmp_reader #(
    .CLK_FREQ_HZ        (CLK_FREQ_HZ),
    .SD_READ_TIMEOUT_MS (500),
    .EXPECTED_PIXELS    (FRAME_PIXELS),
    .ASSET_WIDTH        (400),
    .ASSET_HEIGHT       (1184),
    .ASSET_RESOURCE     (3'd4)
) bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_abort             (load_abort),
    .load_sector            (load_sector),
    .load_done              (load_done),
    .load_error             (load_error),
    .bmp_error              (bmp_error),
    .load_progress          (frame_load_progress),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code_i),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (bmp_sd_sec_read_data_valid),
    .sd_sec_read_end        (bmp_sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data),
    .ad_found               (ad_found),
    .ad_width               (ad_width),
    .ad_height              (ad_height),
    .ad_stream_start        (ad_stream_start),
    .ad_source_go           (ad_source_go),
    .audio_available        (audio_available_i),
    .audio_start_lba        (audio_start_lba_i),
    .audio_total_sectors    (audio_total_sectors_i),
    .audio_start            (1'b0),
    .audio_byte_valid       (),
    .audio_byte             (),
    .audio_done             (),
    .audio_error            ()
);

// Posters are scaled to fit 1280x720 while they stream in. The abort is
// registered: it only has to stop the scaler before the next poster starts.
reg ad_scaler_abort;
always @(posedge clk or posedge rst)
    if (rst) ad_scaler_abort <= 1'b1;
    else ad_scaler_abort <= load_abort || !ad_loading;
advert_fit_scaler u_advert_fit_scaler (
    .clk       (clk),
    .rst       (rst),
    .start     (ad_stream_start && ad_loading),
    .level     (ad_load_level),
    .abort     (ad_scaler_abort),
    .src_w     (ad_width),
    .src_h     (ad_height),
    .in_valid  (bmp_data_wr_en && ad_loading),
    .in_rgb    (bmp_data),
    .out_valid (ad_scaler_valid),
    .out_data  (ad_scaler_data),
    .busy      (),
    .source_go (ad_source_go)
);

// SPI mode samples MISO on the same fabric edge that raises DCLK, so the
// card has only one DCLK half period from the falling edge to drive data.
// At 100 MHz, DIV=0 gives 25 MHz (20 ns half period), which is shorter than
// pad + trace + 14 ns card output delay. DIV=1 gives 16.7 MHz (30 ns).
sd_card_top #(
    .SPI_HIGH_SPEED_DIV     (1)
) sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_top_read),
    .sd_sec_read_addr       (sd_top_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       (),
    .debug_state            (sd_cmd_state)
);

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse,
    output wire button_stable_out
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
// Down counter loaded with DEBOUNCE_CYCLES - 2: it turns negative on the
// DEBOUNCE_CYCLES-th clock of a changed input, so the end test is one bit.
localparam [23:0] DEBOUNCE_LOAD = DEBOUNCE_CYCLES - 2;
reg [23:0] cnt;                // up to 83 ms at 100 MHz

assign button_stable_out = button_stable;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= DEBOUNCE_LOAD;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= DEBOUNCE_LOAD;
        end else begin
            if (cnt[23]) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= DEBOUNCE_LOAD;
            end else begin
                cnt <= cnt - 24'd1;
            end
        end
    end
end

endmodule
