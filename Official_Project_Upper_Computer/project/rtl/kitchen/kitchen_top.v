`timescale 1ns/1ps

// Kitchen console (后厨控制端), HX4S20 / EG4S20BG256.
// The interface runs in the 74.24 MHz video clock and is drawn by the FPGA
// (tile engine, no SDRAM). The TF card only holds the background music
// (AUDIO.PCM, read in the 50 MHz board clock by kitchen_music). HDMI carries
// video and the audio of the music, the chimes and the key clicks.
module top (
    input  wire       clk,            // 50 MHz
    input  wire       key1,           // K1 next / increase
    input  wire       key2,           // K2 previous / decrease
    input  wire       key3,           // K3 act
    input  wire       key4,           // K4 page (held: previous page)
    input  wire       sw1,            // mode bit 0
    input  wire       sw2,            // mode bit 1
    input  wire       sw3,            // mode bit 2
    input  wire       sw4,            // mode bit 3
    // TF card (SPI mode): background music.
    output wire       sd_ncs,
    output wire       sd_dclk,
    output wire       sd_mosi,
    input  wire       sd_miso,
    output wire [7:0] seg_sel,
    output wire [7:0] seg_data,
    output wire       HDMI_CLK_P,
    output wire       HDMI_D2_P,
    output wire       HDMI_D1_P,
    output wire       HDMI_D0_P,
    output wire       HDMI_DDC_SCL,
    inout  wire       HDMI_DDC_SDA,
    // Gigabit Ethernet (RTL8211E, RGMII) to the front-end board.
    output wire [3:0] phy1_rgmii_tx_data,
    output wire       phy1_rgmii_tx_ctl,
    output wire       phy1_rgmii_tx_clk,
    input  wire [3:0] phy1_rgmii_rx_data,
    input  wire       phy1_rgmii_rx_ctl,
    input  wire       phy1_rgmii_rx_clk,
    output wire [3:0] led                // LED0 link, LED1 receive, LED2 send, LED3 front order waiting
);
`include "kitchen_ui_defs.vh"

    localparam integer CLK_HZ = 74_242_424;
    localparam integer LONG_PRESS_CYCLES = CLK_HZ / 1000 * 600;

    // ------------------------------------------------------------ clocks and reset
    wire video_clk, hdmi_5x_clk, video_pll_lock;
    video_pll_720p_formal u_video_pll (
        .refclk(clk), .reset(1'b0), .extlock(video_pll_lock),
        .clk0_out(video_clk), .clk1_out(hdmi_5x_clk));

    reg [19:0] lock_count = 20'd0;
    reg        rst_all = 1'b1;
    always @(posedge clk or negedge video_pll_lock) begin
        if (!video_pll_lock) begin
            lock_count <= 20'd0;
            rst_all <= 1'b1;
        end else if (rst_all) begin
            // Release reset after the PLL has been locked for 20 ms.
            if (lock_count < 20'd1_000_000)
                lock_count <= lock_count + 1'b1;
            else
                rst_all <= 1'b0;
        end
    end
    wire rst_n;
    reset_sync u_video_reset (.clk(video_clk), .ext_rst_n(!rst_all), .rst_n_sync(rst_n));

    // ------------------------------------------------------------ keys and switches
    wire k1_press, k2_press, k3_press, k4_press;
    wire k1_level, k2_level, k3_level, k4_level;
    key_press_debounce #(.CLK_FREQ_HZ(CLK_HZ), .DEBOUNCE_MS(15)) u_k1 (
        .clk(video_clk), .rst(!rst_n), .button_in(key1), .press_pulse(k1_press), .button_stable_out(k1_level));
    key_press_debounce #(.CLK_FREQ_HZ(CLK_HZ), .DEBOUNCE_MS(15)) u_k2 (
        .clk(video_clk), .rst(!rst_n), .button_in(key2), .press_pulse(k2_press), .button_stable_out(k2_level));
    key_press_debounce #(.CLK_FREQ_HZ(CLK_HZ), .DEBOUNCE_MS(15)) u_k3 (
        .clk(video_clk), .rst(!rst_n), .button_in(key3), .press_pulse(k3_press), .button_stable_out(k3_level));
    key_press_debounce #(.CLK_FREQ_HZ(CLK_HZ), .DEBOUNCE_MS(15)) u_k4 (
        .clk(video_clk), .rst(!rst_n), .button_in(key4), .press_pulse(k4_press), .button_stable_out(k4_level));

    // K4: short press on release, long press once after 600 ms.
    reg [26:0] k4_hold;
    reg        k4_down, k4_long_done, k4_short, k4_long;
    always @(posedge video_clk or negedge rst_n) begin
        if (!rst_n) begin
            k4_hold <= 27'd0; k4_down <= 1'b0; k4_long_done <= 1'b0; k4_short <= 1'b0; k4_long <= 1'b0;
        end else begin
            k4_short <= 1'b0;
            k4_long <= 1'b0;
            if (k4_press) begin
                k4_down <= 1'b1;
                k4_hold <= 27'd0;
                k4_long_done <= 1'b0;
            end else if (k4_down && k4_level) begin
                k4_down <= 1'b0;
                k4_short <= !k4_long_done;
            end else if (k4_down && !k4_long_done) begin
                if (k4_hold >= LONG_PRESS_CYCLES - 1) begin
                    k4_long <= 1'b1;
                    k4_long_done <= 1'b1;
                end else begin
                    k4_hold <= k4_hold + 1'b1;
                end
            end
        end
    end

    // Mode {SW4, SW3, SW2, SW1} (switches are active low).
    (* async_reg = "true" *) reg [3:0] mode_sync0;
    (* async_reg = "true" *) reg [3:0] mode_sync1;
    always @(posedge video_clk or negedge rst_n) begin
        if (!rst_n) begin
            mode_sync0 <= 4'b0000;
            mode_sync1 <= 4'b0000;
        end else begin
            mode_sync0 <= {~sw4, ~sw3, ~sw2, ~sw1};
            mode_sync1 <= mode_sync0;
        end
    end
    wire [3:0] mode = mode_sync1;

    // ------------------------------------------------------------ parameters
    wire       ui_live;
    wire       param_keys = ui_live && mode != 4'b0000 && mode <= 4'b0100;
    wire [7:0] brightness, contrast, volume;
    wire [3:0] ticker_speed;
    wire       param_active;
    wire [1:0] param_kind;
    parameter_adjust_controller #(.CLK_FREQ_HZ(CLK_HZ)) u_parameters (
        .clk(video_clk), .rst(!rst_n),
        .key_increase(param_keys ? key1 : 1'b1), .key_decrease(param_keys ? key2 : 1'b1),
        .sw1(sw1), .sw2(sw2), .sw3(sw3), .sw4(sw4), .popup_on_switch(ui_live),
        .brightness(brightness), .contrast(contrast), .volume(volume),
        .ticker_speed(ticker_speed), .display_active(param_active), .selected_parameter(param_kind));

    // ------------------------------------------------------------ boot
    wire       frame_start;
    wire [9:0] boot_t;
    wire       boot_layer_on, boot_page_b, boot_exit, chime_boot, chime_ready;
    wire [3:0] boot_step;
    wire [4:0] boot_progress;
    kitchen_boot_sequencer u_boot (
        .clk(video_clk), .rst_n(rst_n), .frame_start(frame_start), .boot_t(boot_t),
        .layer_on(boot_layer_on), .page_b(boot_page_b), .boot_step(boot_step),
        .boot_progress(boot_progress), .exit_req(boot_exit),
        .chime_boot(chime_boot), .chime_ready(chime_ready));

    // ------------------------------------------------------------ core
    wire [2:0]  page;
    wire [5:0]  var_id;
    wire [15:0] var_value;
    wire [1:0]  trans_kind, trans_phase, ticker_line;
    wire [4:0]  trans_level, popup_alpha;
    wire [6:0]  hi_elem;
    wire [3:0]  pulse;
    wire        order_chime;
    wire [2:0]  order_count;
    wire [3:0]  pending, making;
    wire [15:0] sold_mask;
    wire [2:0]  applied_slogan;
    wire [2:0]  ad_index;
    wire [2:0]  weather_kind, weather_band;
    wire        weather_neg;
    wire [3:0]  weather_tens, weather_ones;
    wire [2:0]  music_track;
    wire        music_on;
    wire [3:0]  accent_index;
    wire        link_up, stats_clear, front_order_req, front_order_taken;
    wire [15:0] stat_status, stat_seq, stat_retx, stat_rx, stat_tx;
    wire [2:0]  front_order_count, front_line;
    wire [31:0] front_order_items;
    wire [7:0]  front_no;
    wire        led_rx, led_tx;
    kitchen_core u_core (
        .clk(video_clk), .rst_n(rst_n), .frame_start(frame_start),
        .k1(k1_press), .k2(k2_press), .k3(k3_press), .k4_short(k4_short), .k4_long(k4_long),
        .k1_down(!k1_level), .k2_down(!k2_level),
        .mode(mode), .brightness(brightness), .contrast(contrast), .volume(volume),
        .ticker_speed(ticker_speed), .param_active(param_active), .param_kind(param_kind),
        .boot_page_b(boot_page_b), .boot_exit(boot_exit), .boot_step(boot_step),
        .boot_progress(boot_progress), .page(page), .var_id(var_id), .var_value(var_value),
        .trans_kind(trans_kind), .trans_phase(trans_phase), .trans_level(trans_level),
        .hi_elem(hi_elem), .pulse(pulse), .popup_alpha(popup_alpha), .ui_live(ui_live),
        .ticker_line(ticker_line), .order_chime(order_chime), .order_count_out(order_count),
        .pending_out(pending), .making_out(making), .sold_mask(sold_mask),
        .applied_slogan(applied_slogan), .ad_index(ad_index), .music_track(music_track),
        .weather_kind(weather_kind), .weather_band(weather_band), .weather_neg(weather_neg),
        .weather_tens(weather_tens), .weather_ones(weather_ones),
        .music_on(music_on), .accent_index(accent_index),
        .link_up(link_up), .stat_status(stat_status), .stat_seq(stat_seq), .stat_retx(stat_retx),
        .stat_rx(stat_rx), .stat_tx(stat_tx), .stats_clear(stats_clear),
        .front_order_req(front_order_req), .front_order_count(front_order_count),
        .front_order_items(front_order_items), .front_order_taken(front_order_taken),
        .front_line(front_line), .front_no(front_no));

    // ------------------------------------------------------------ board link
    kitchen_link u_link (
        .clk50(clk), .rst_n(!rst_all),
        .rgmii_txd(phy1_rgmii_tx_data), .rgmii_tx_ctl(phy1_rgmii_tx_ctl), .rgmii_txc(phy1_rgmii_tx_clk),
        .rgmii_rxd(phy1_rgmii_rx_data), .rgmii_rx_ctl(phy1_rgmii_rx_ctl), .rgmii_rxc(phy1_rgmii_rx_clk),
        .app_clk(video_clk), .app_rst_n(rst_n), .sold_mask(sold_mask), .ad_index(ad_index),
        .applied_slogan(applied_slogan), .front_line(front_line), .front_no(front_no),
        .weather_kind(weather_kind), .weather_band(weather_band), .weather_neg(weather_neg),
        .weather_tens(weather_tens), .weather_ones(weather_ones),
        .stats_clear(stats_clear), .link_up(link_up), .order_req(front_order_req),
        .order_taken(front_order_taken), .order_count(front_order_count),
        .order_items(front_order_items), .stat_status(stat_status), .stat_seq(stat_seq),
        .stat_retx(stat_retx), .stat_rx(stat_rx), .stat_tx(stat_tx),
        .led_rx(led_rx), .led_tx(led_tx));
    assign led = {front_order_req != front_order_taken, led_tx, led_rx, link_up};

    // ------------------------------------------------------------ composer and tile map
    wire        front;
    wire        frame_ready;
    wire [11:0] ram_addr_a, ram_addr_b;
    wire        ram_we;
    wire [31:0] ram_wdata, ram_rdata, tile_data;
    wire [10:0] dl_addr;
    wire [31:0] dl_lo, dl_hi;
    wire [9:0]  ph_addr;
    wire [8:0]  ph_data;
    kitchen_composer u_composer (
        .clk(video_clk), .rst_n(rst_n), .frame_start(frame_start), .page(page),
        .front(front), .frame_ready(frame_ready), .var_id(var_id), .var_value(var_value),
        .ram_addr(ram_addr_a), .ram_we(ram_we), .ram_wdata(ram_wdata), .ram_rdata(ram_rdata),
        .dl_addr(dl_addr), .dl_data({dl_hi, dl_lo}), .ph_addr(ph_addr), .ph_data(ph_data));
    kitchen_tile_ram u_tiles (
        .clk(video_clk), .addra(ram_addr_a), .wea(ram_we), .dia(ram_wdata), .doa(ram_rdata),
        .addrb(ram_addr_b), .dob(tile_data));
    kitchen_rom #(.WIDTH(32), .DEPTH(DLIST_DEPTH), .ADDR_W(11), .FILE("kitchen_dlist_lo"))
        u_dlist_lo (.clk(video_clk), .addr(dl_addr), .data(dl_lo));
    kitchen_rom #(.WIDTH(32), .DEPTH(DLIST_DEPTH), .ADDR_W(11), .FILE("kitchen_dlist_hi"))
        u_dlist_hi (.clk(video_clk), .addr(dl_addr), .data(dl_hi));
    kitchen_rom #(.WIDTH(9), .DEPTH(PHRASE_DEPTH), .ADDR_W(10), .FILE("kitchen_phrase"))
        u_phrase (.clk(video_clk), .addr(ph_addr), .data(ph_data));

    // ------------------------------------------------------------ display
    // Accent colours 1..10, the same as the front end's waveform colours.
    function [23:0] accent_palette;
        input [3:0] index;
        begin
            case (index)
                4'd2:  accent_palette = 24'h60a5fa;
                4'd3:  accent_palette = 24'hb388ff;
                4'd4:  accent_palette = 24'hf472b6;
                4'd5:  accent_palette = 24'hf43f5e;
                4'd6:  accent_palette = 24'hfb923c;
                4'd7:  accent_palette = 24'hfde047;
                4'd8:  accent_palette = 24'h4ade80;
                4'd9:  accent_palette = 24'hf8fafc;
                4'd10: accent_palette = 24'hd4a937;
                default: accent_palette = 24'h5eead4;
            endcase
        end
    endfunction
    reg [23:0] accent_rgb;
    always @(posedge video_clk or negedge rst_n) begin
        if (!rst_n) accent_rgb <= 24'h5eead4;
        else accent_rgb <= accent_palette(accent_index);
    end

    wire        disp_vs, disp_de;
    wire [23:0] disp_rgb;
    kitchen_display u_display (
        .clk(video_clk), .rst_n(rst_n), .front(front), .tile_addr(ram_addr_b), .tile_data(tile_data),
        .hi_elem(hi_elem), .pulse(pulse), .popup_alpha(popup_alpha), .accent(accent_rgb),
        .ticker_enable(ui_live), .ticker_line(ticker_line), .ticker_speed(ticker_speed),
        .trans_kind(trans_kind), .trans_phase(trans_phase), .trans_level(trans_level),
        .boot_t(boot_t), .boot_layer_on(boot_layer_on), .frame_start(frame_start),
        .vs_out(disp_vs), .de_out(disp_de), .rgb_out(disp_rgb));

    function [7:0] percent_to_u8;
        input [7:0] value;
        begin
            percent_to_u8 = (value >= 8'd100) ? 8'd255 : ((value * 16'd653 + 16'd128) >> 8);
        end
    endfunction
    reg [7:0] brightness_u8, contrast_u8, volume_u8;
    always @(posedge video_clk or negedge rst_n) begin
        if (!rst_n) begin
            brightness_u8 <= 8'd255; contrast_u8 <= 8'd128; volume_u8 <= 8'd255;
        end else if (frame_start) begin
            brightness_u8 <= percent_to_u8(brightness);
            contrast_u8 <= percent_to_u8(contrast);
            volume_u8 <= percent_to_u8(volume);
        end
    end
    // Spectrum bars above the ticker, driven by the sound on HDMI.
    reg  [23:0]       audio_left, audio_right;     // HDMI audio (audio section below)
    reg               audio_valid;
    wire               music_valid;
    wire signed [15:0] music_sample;
    wire        bars_vs, bars_de;
    wire [23:0] bars_rgb;
    // Animated weather picture on the weather page.
    wire        art_vs, art_de;
    wire [23:0] art_rgb;
    kitchen_weather_art u_weather_art (
        .clk(video_clk), .rst_n(rst_n),
        .enable(page == PAGE_WEATHER && trans_phase == 2'd0), .kind(weather_kind),
        .in_vs(disp_vs), .in_de(disp_de), .rgb_in(disp_rgb),
        .out_vs(art_vs), .out_de(art_de), .rgb_out(art_rgb));

    kitchen_spectrum u_spectrum (
        .clk(video_clk), .rst_n(rst_n), .enable(ui_live),
        .sample(audio_left[23:8]), .sample_valid(audio_valid), .accent(accent_rgb),
        .in_vs(art_vs), .in_de(art_de), .rgb_in(art_rgb),
        .out_vs(bars_vs), .out_de(bars_de), .rgb_out(bars_rgb));

    wire        adj_vs, adj_de;
    wire [23:0] adj_rgb;
    brightness_contrast_adjust u_adjust (
        .clk(video_clk), .rst_n(rst_n), .in_vs(bars_vs), .in_de(bars_de), .rgb_in(bars_rgb),
        .brightness(brightness_u8), .contrast(contrast_u8),
        .out_vs(adj_vs), .out_de(adj_de), .rgb_out(adj_rgb));

    wire        axis_user, axis_valid, axis_last, axis_ready;
    wire [23:0] axis_data;
    video_rgb_to_axis_720p u_axis (
        .I_clk(video_clk), .I_rst(!rst_n), .I_vs(adj_vs), .I_de(adj_de), .I_rgb(adj_rgb),
        .O_video_user(axis_user), .O_video_valid(axis_valid), .O_video_last(axis_last),
        .O_video_data(axis_data));

    // ------------------------------------------------------------ audio
    reg [31:0] sample_acc;
    reg        sample_tick;
    always @(posedge video_clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_acc <= 32'd0;
            sample_tick <= 1'b0;
        end else begin
            sample_tick <= 1'b0;
            if (sample_acc >= CLK_HZ - 48_000) begin
                sample_acc <= sample_acc + 48_000 - CLK_HZ;
                sample_tick <= 1'b1;
            end else begin
                sample_acc <= sample_acc + 48_000;
            end
        end
    end

    wire               chime_active;
    wire signed [23:0] chime_left, chime_right;
    kitchen_chime u_chime (
        .clk(video_clk), .rst_n(rst_n),
        .trigger(chime_boot || chime_ready || order_chime),
        .melody(order_chime ? 2'd1 : chime_ready ? 2'd2 : 2'd0),
        .sample_tick(sample_tick), .active(chime_active),
        .sample_left(chime_left), .sample_right(chime_right));

    wire               click_active;
    wire signed [23:0] click_left, click_right;
    wire               any_key = ui_live && (k1_press || k2_press || k3_press || k4_press);
    key_click_sound u_click (
        .clk(video_clk), .rst_n(rst_n), .trigger(any_key),
        .key_code(k1_press ? 2'd0 : k2_press ? 2'd1 : k3_press ? 2'd2 : 2'd3),
        .sample_tick(sample_tick), .active(click_active),
        .sample_left(click_left), .sample_right(click_right));

    // Background music (mono, at half scale to leave room for the chimes).
    wire music_found;
    kitchen_music #(.CLK_HZ(50_000_000)) u_music (
        .clk(clk), .rst_n(!rst_all), .track_async(music_track), .enable_async(ui_live && music_on),
        .sd_ncs(sd_ncs), .sd_dclk(sd_dclk), .sd_mosi(sd_mosi), .sd_miso(sd_miso),
        .rd_clk(video_clk), .rd_rst_n(rst_n), .sample_tick(sample_tick),
        .sample(music_sample), .sample_valid(music_valid), .file_found(music_found));
    wire signed [23:0] music24 = {music_sample[15], music_sample, 7'd0};

    wire signed [24:0] mix_left = $signed({chime_left[23], chime_left}) + $signed({click_left[23], click_left}) +
                                  $signed({music24[23], music24});
    wire signed [24:0] mix_right = $signed({chime_right[23], chime_right}) + $signed({click_right[23], click_right}) +
                                   $signed({music24[23], music24});
    function signed [23:0] saturate;
        input signed [24:0] s;
        begin
            if (s > 25'sd8388607) saturate = 24'sd8388607;
            else if (s < -25'sd8388608) saturate = -24'sd8388608;
            else saturate = s[23:0];
        end
    endfunction
    reg signed [23:0] src_left, src_right;
    reg               src_valid;
    wire signed [32:0] scaled_left = src_left * $signed({1'b0, volume_u8});
    wire signed [32:0] scaled_right = src_right * $signed({1'b0, volume_u8});
    always @(posedge video_clk or negedge rst_n) begin
        if (!rst_n) begin
            src_left <= 24'sd0; src_right <= 24'sd0; src_valid <= 1'b0;
            audio_left <= 24'd0; audio_right <= 24'd0; audio_valid <= 1'b0;
        end else begin
            src_left <= saturate(mix_left);
            src_right <= saturate(mix_right);
            src_valid <= sample_tick;
            audio_left <= scaled_left >>> 8;
            audio_right <= scaled_right >>> 8;
            audio_valid <= src_valid;
        end
    end

    wire        acr_valid;
    wire [19:0] acr_cts, acr_n;
    audio_arc_calculate #(.ACR_N(6144)) u_acr (
        .I_clk(video_clk), .I_rst(!rst_n), .I_audio_valid(audio_valid),
        .O_acr_valid(acr_valid), .O_acr_cts(acr_cts), .O_acr_n(acr_n));

    // ------------------------------------------------------------ HDMI
    wire edid_trig, edid_valid;
    wire [7:0] edid_data;
    startup_pulse #(.CNT_MAX(20'd100000)) u_edid_pulse (
        .I_clk(video_clk), .I_rst(!rst_n), .O_pulse(edid_trig));
    wire [9:0] tmds_ch0, tmds_ch1, tmds_ch2, tmds_clk;
    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE("EG"), .HTOTAL(1650), .HSA(40), .HFP(110), .HBP(220), .HACTIVE(1280),
        .VTOTAL(750), .VSA(5), .VFP(5), .VBP(20), .VACTIVE(720), .VIDEO_VIC(4),
        .VIDEO_TPG("Disable"), .VIDEO_FORMAT("RGB"), .AUDIO_SAMPLE_RATE("48K"), .IIC_SCL_DIV(750)
    ) u_hdmi (
        .I_pixel_clk(video_clk), .I_rst(!rst_n), .I_edid_read_trig(edid_trig),
        .O_edid_read_valid(edid_valid), .O_edid_read_data(edid_data),
        .I_axis_s_user(axis_user), .I_axis_s_valid(axis_valid), .I_axis_s_last(axis_last),
        .I_axis_s_data(axis_data), .O_axis_s_ready(axis_ready),
        .I_audio_valid(audio_valid), .I_audio_left_data(audio_left), .I_audio_right_data(audio_right),
        .I_acr_valid(acr_valid), .I_acr_cts(acr_cts), .I_acr_n(acr_n),
        .O_video_locked(), .O_ddc_scl(HDMI_DDC_SCL), .IO_ddc_sda(HDMI_DDC_SDA),
        .O_ch0_tmds_data(tmds_ch0), .O_ch1_tmds_data(tmds_ch1), .O_ch2_tmds_data(tmds_ch2),
        .O_clk_tmds_data(tmds_clk));
    hdmi_phy_wrapper #(.DEVICE("EG")) u_hdmi_phy (
        .I_pixel_clk(video_clk), .I_serial_clk(hdmi_5x_clk), .I_rst(!rst_n),
        .I_tmds_channel_0(tmds_ch0), .I_tmds_channel_1(tmds_ch1), .I_tmds_channel_2(tmds_ch2),
        .I_tmds_channel_clk(tmds_clk),
        .O_tmds_ch0_p(HDMI_D0_P), .O_tmds_ch1_p(HDMI_D1_P), .O_tmds_ch2_p(HDMI_D2_P),
        .O_tmds_clk_p(HDMI_CLK_P));

    // ------------------------------------------------------------ seven segments
    // [mode] [mode] [P] [page] [ ] [ ] [ ] [orders on the board]
    // Digits 0-1: switch mode in decimal (0..7, 15); digits 2-3: "P" and the
    // page (1 orders, 2 dishes, 3 slogans, 4 weather, 5 statistics, 6 link); digit 7: orders on the
    // board. The others stay dark.
    wire [6:0] seg_mode, seg_page, seg_orders;
    wire       mode_tens = mode >= 4'd10;
    seg_decoder u_seg_mode (.bin_data(mode_tens ? mode - 4'd10 : mode), .seg_data(seg_mode));
    seg_decoder u_seg_page (.bin_data({1'b0, page} + 4'd1), .seg_data(seg_page));
    seg_decoder u_seg_orders (.bin_data({1'b0, order_count}), .seg_data(seg_orders));
    wire [7:0] dash = {1'b1, 7'b011_1111};
    wire [7:0] blank = 8'hff;
    seg_scan #(.CLK_FREQ(CLK_HZ)) u_seg_scan (
        .clk(video_clk), .rst_n(rst_n), .seg_sel(seg_sel), .seg_data(seg_data),
        .seg_data_0(ui_live ? (mode_tens ? {1'b1, 7'b111_1001} : {1'b1, seg_mode}) : dash),
        .seg_data_1(ui_live ? (mode_tens ? {1'b1, seg_mode} : blank) : dash),
        .seg_data_2(ui_live ? {1'b1, 7'b000_1100} : dash),     // P
        .seg_data_3(ui_live ? {1'b1, seg_page} : dash),
        .seg_data_4(ui_live ? blank : dash),
        .seg_data_5(ui_live ? blank : dash),
        .seg_data_6(ui_live ? blank : dash),
        .seg_data_7(ui_live ? {1'b1, seg_orders} : dash));
endmodule
