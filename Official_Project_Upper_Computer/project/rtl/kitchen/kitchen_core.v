`timescale 1ns/1ps

// State of the kitchen console: pages and transitions, the order queue, the
// sold-out mask, slogans, popups, the ticker state and the composer's
// variable bus. Everything runs in the video clock.
//
// Switch modes {SW4, SW3, SW2, SW1}:
//   0000 work     K1 next item, K2 previous, K3 act on it, K4 next page
//                 (held: previous page). On the order board K3 moves the
//                 selected order on: accept -> ready -> remove. On the
//                 weather page K3 selects the weather, the temperature or the
//                 humidity and K1/K2 change it (held: repeat for the
//                 temperature and the humidity).
//   0001-0100     brightness / contrast / volume / ticker speed (parameter
//                 controller, shown here as popups)
//   0101 adverts  K1 next advert, K2 previous
//   0110 colour   K1 next accent colour, K2 previous (1..10, spectrum bars
//                 and popups); K3 creates a test order
//   0111 music    K1 next track, K2 previous (1..6, track 6 after reset),
//                 K3 music on / off (on after reset)
//   1111 orders   the order board from any page: K1/K2 choose the order,
//                 K3 moves it on (accept -> ready -> remove), K4 turns pages
//   others        no key action
module kitchen_core #(
    parameter integer WIPE_STEP = 2,       // transition level per frame (16 = full)
    parameter integer CENTRE_STEP = 1,
    parameter [2:0]   DEFAULT_MUSIC = 3'd6,
    parameter [2:0]   MUSIC_TRACKS = 3'd6
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,
    input  wire        k1, k2, k3, k4_short, k4_long,      // one-clock presses
    input  wire        k1_down, k2_down,                   // K1 / K2 held (debounced)
    input  wire [3:0]  mode,
    // Parameter controller.
    input  wire [7:0]  brightness, contrast, volume,       // percent
    input  wire [3:0]  ticker_speed,                       // 1..10
    input  wire        param_active,
    input  wire [1:0]  param_kind,                         // 0 brightness .. 3 speed
    // Boot sequencer.
    input  wire        boot_page_b,
    input  wire        boot_exit,
    input  wire [3:0]  boot_step,
    input  wire [4:0]  boot_progress,
    // Composer and display.
    output wire [2:0]  page,
    input  wire [5:0]  var_id,
    output reg  [15:0] var_value,
    output reg  [1:0]  trans_kind,
    output reg  [1:0]  trans_phase,
    output reg  [4:0]  trans_level,
    output reg  [6:0]  hi_elem,
    output wire [3:0]  pulse,
    output reg  [4:0]  popup_alpha,
    output wire        ui_live,
    output reg  [1:0]  ticker_line,
    output reg         order_chime,                        // one clock: new order
    // Summary for the seven-segment display and the future link.
    output wire [2:0]  order_count_out,
    output wire [3:0]  pending_out,
    output wire [3:0]  making_out,
    output reg  [15:0] sold_mask,
    output reg  [2:0]  applied_slogan,                     // 1..5
    output reg  [2:0]  ad_index,                           // 1..4
    // Weather set on the weather page, for the front advert card.
    output reg  [2:0]  weather_kind,                       // 0 晴天 .. 5 雪天
    output wire [2:0]  weather_band,                       // 0 炎热 .. 4 寒冷
    output wire        weather_neg,
    output wire [3:0]  weather_tens, weather_ones,         // |temperature|
    output reg  [2:0]  music_track,                        // 1..MUSIC_TRACKS
    output reg         music_on,
    output reg  [3:0]  accent_index,                       // colour 1..10
    // Board link (kitchen_link), already in this clock domain.
    input  wire        link_up,
    input  wire [15:0] stat_status, stat_seq, stat_retx, stat_rx, stat_tx,
    output reg         stats_clear,                        // one clock
    input  wire        front_order_req,                    // toggles: a front order waits
    input  wire [2:0]  front_order_count,
    input  wire [31:0] front_order_items,                  // {qty, dish} per byte
    output reg         front_order_taken,                  // toggle back once on the board
    output reg  [2:0]  front_line,                         // front ticker text
    output reg  [7:0]  front_no                            // order number shown in it
);
`include "kitchen_ui_defs.vh"

    localparam [1:0] ST_EMPTY = 2'd0, ST_PENDING = 2'd1, ST_MAKING = 2'd2, ST_DONE = 2'd3;
    localparam [1:0] TK_NONE = 2'd0, TK_NEXT = 2'd1, TK_PREV = 2'd2, TK_CENTRE = 2'd3;
    localparam [1:0] TP_IDLE = 2'd0, TP_OUT = 2'd1, TP_HOLD = 2'd2, TP_IN = 2'd3;
    localparam [7:0] POPUP_FRAMES = 8'd120;

    // ------------------------------------------------------------ frame clock
    reg [7:0] frame_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) frame_count <= 8'd0;
        else if (frame_start) frame_count <= frame_count + 1'b1;
    end
    // Triangle 0..15..0 with a period of 64 frames.
    assign pulse = frame_count[5] ? ~frame_count[4:1] : frame_count[4:1];

    // ------------------------------------------------------------ order queue
    // Slots 0..count-1 are used, oldest first.
    reg [1:0] slot_st  [0:3];
    reg [7:0] slot_no  [0:3];
    reg [9:0] slot_tot [0:3];
    reg [2:0] slot_cnt [0:3];
    reg [7:0] slot_item [0:15];           // {qty, dish}, slot * 4 + item

    wire [2:0] count = (slot_st[0] != 0) + (slot_st[1] != 0) + (slot_st[2] != 0) + (slot_st[3] != 0);
    wire [3:0] pending = (slot_st[0] == ST_PENDING) + (slot_st[1] == ST_PENDING) +
                         (slot_st[2] == ST_PENDING) + (slot_st[3] == ST_PENDING);
    wire [3:0] making = (slot_st[0] == ST_MAKING) + (slot_st[1] == ST_MAKING) +
                        (slot_st[2] == ST_MAKING) + (slot_st[3] == ST_MAKING);
    assign order_count_out = count;
    assign pending_out = pending;
    assign making_out = making;

    // First finished order, evicted when a new order finds the queue full.
    wire       has_done = slot_st[0] == ST_DONE || slot_st[1] == ST_DONE ||
                          slot_st[2] == ST_DONE || slot_st[3] == ST_DONE;
    wire [1:0] first_done = (slot_st[0] == ST_DONE) ? 2'd0 : (slot_st[1] == ST_DONE) ? 2'd1 :
                            (slot_st[2] == ST_DONE) ? 2'd2 : 2'd3;

    reg [2:0]  page_shown;
    reg [1:0]  sel_order;
    reg [3:0]  sel_dish;
    reg [2:0]  sel_slogan;
    reg [15:0] done_total;
    // Weather page.
    reg signed [6:0] weather_temp;      // -9..40 ℃
    reg  [1:0] weather_field;           // K3: 0 weather, 1 temperature, 2 humidity
    reg  [6:0] weather_hum;             // 0..100 %, shown on this page only
    // Held K1 / K2: frames since the press; repeat steps from frame 30
    // (0.5 s), then every 4 frames.
    reg  [5:0] hold_frames_k;
    reg        rep_up, rep_down;        // one clock each
    wire [5:0] weather_abs = weather_temp[6] ? -weather_temp : weather_temp;
    assign weather_neg = weather_temp[6];
    assign weather_tens = weather_abs / 6'd10;
    assign weather_ones = weather_abs % 6'd10;
    assign weather_band = (weather_temp >= 7'sd33) ? 3'd0 : (weather_temp >= 7'sd27) ? 3'd1 :
                          (weather_temp >= 7'sd18) ? 3'd2 : (weather_temp >= 7'sd10) ? 3'd3 : 3'd4;
    // A finished order for the statistics (one clock).
    reg        tally_req;
    reg [31:0] tally_items_req;
    reg [2:0]  tally_cnt_req;
    reg [9:0]  tally_tot_req;
    reg [3:0]  top_dish;                // statistics: the best-selling dish
    reg [7:0]  top_qty;
    reg [7:0]  next_no;
    reg        last_done;               // ticker: the last event was a ready order

    // New order being added (test generator now, network link later).
    reg        add_req;
    reg [7:0]  add_item [0:3];
    reg [2:0]  add_cnt;
    reg [9:0]  add_tot;

    // Popup.
    reg [3:0]  popup_kind;
    reg [15:0] popup_value;
    reg [3:0]  popup_bar;
    reg [3:0]  popup_dish;
    reg [7:0]  popup_order;
    reg [7:0]  popup_timer;
    reg        event_popup;             // request from this clock's key handling
    reg [3:0]  event_kind;
    reg [15:0] event_value;
    reg [3:0]  event_dish;
    reg [7:0]  event_order;

    // Front orders and the front ticker. The ready text stays for a minute,
    // then the front shows the applied slogan again.
    localparam [11:0] READY_FRAMES = 12'd3600;
    localparam [2:0]  LINE_RECEIVED = 3'd5, LINE_MAKING = 3'd6, LINE_READY = 3'd7;
    reg        slot_front [0:3];         // the order came from the front
    reg        add_front;
    reg [2:0]  front_load;               // a front order being priced
    reg [9:0]  item_cost [0:3];
    reg        front_full_shown;
    reg [11:0] ready_timer;
    // Front orders are priced by the kitchen itself (item_cost below).

    // Transition requests.
    reg        trans_req;
    reg [1:0]  trans_req_kind;
    reg [2:0]  trans_req_page;
    reg [2:0]  trans_target;
    reg [1:0]  hold_frames;

    wire [4:0] trans_step = (trans_kind == TK_CENTRE) ? CENTRE_STEP : WIPE_STEP;
    assign ui_live = page_shown < UI_PAGES;
    // Page order of K4: 订单 菜品 标语 天气 统计 链路, wrapping around.
    function [2:0] page_step;
        input [2:0] p;
        input       forward;
        begin
            if (forward)
                page_step = (p >= UI_PAGES - 1'b1) ? 3'd0 : p + 1'b1;
            else
                page_step = (p == 3'd0) ? UI_PAGES - 1'b1 : p - 1'b1;
        end
    endfunction
    assign page = page_shown;
    wire keys_ok = ui_live && trans_phase == TP_IDLE;

    // ------------------------------------------------------------ test order generator
    reg [15:0] lfsr;
    reg [1:0]  gen_state;
    reg [1:0]  gen_target;
    reg [3:0]  gen_cand;
    reg [3:0]  gen_probe;
    reg [2:0]  gen_cnt;
    reg [9:0]  gen_tot;
    reg [7:0]  gen_item [0:3];
    reg        gen_start;
    localparam [1:0] G_IDLE = 2'd0, G_PICK = 2'd1, G_DONE = 2'd2;
    wire gen_taken = (gen_cnt > 0 && gen_item[0][3:0] == gen_cand) ||
                     (gen_cnt > 1 && gen_item[1][3:0] == gen_cand) ||
                     (gen_cnt > 2 && gen_item[2][3:0] == gen_cand);
    wire [3:0] gen_qty = lfsr[5] ? 4'd2 : 4'd1;

    integer i;
    reg [3:0] mode_q;                   // previous mode: a change shows its popup

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 4; i = i + 1) begin
                slot_st[i] <= ST_EMPTY; slot_no[i] <= 8'd0; slot_tot[i] <= 10'd0; slot_cnt[i] <= 3'd0;
                slot_front[i] <= 1'b0;
                add_item[i] <= 8'd0; gen_item[i] <= 8'd0;
            end
            for (i = 0; i < 16; i = i + 1)
                slot_item[i] <= 8'd0;
            page_shown <= PAGE_BOOT_A;
            sel_order <= 2'd0;
            sel_dish <= 4'd0;
            sel_slogan <= 3'd0;
            applied_slogan <= 3'd1;
            ad_index <= 3'd1;
            music_track <= DEFAULT_MUSIC;
            music_on <= 1'b1;
            accent_index <= 4'd1;
            sold_mask <= 16'd0;
            done_total <= 16'd0;
            weather_kind <= DEFAULT_WX_KIND;
            weather_temp <= DEFAULT_WX_TEMP;
            weather_field <= 2'd0;
            weather_hum <= DEFAULT_WX_HUM;
            hold_frames_k <= 6'd0; rep_up <= 1'b0; rep_down <= 1'b0;
            tally_req <= 1'b0; tally_items_req <= 32'd0; tally_cnt_req <= 3'd0; tally_tot_req <= 10'd0;
            next_no <= 8'd1;
            last_done <= 1'b0;
            add_req <= 1'b0; add_cnt <= 3'd0; add_tot <= 10'd0;
            popup_kind <= POPUP_NONE; popup_value <= 16'd0; popup_bar <= 4'd0;
            popup_dish <= 4'd0; popup_order <= 8'd0; popup_timer <= 8'd0; popup_alpha <= 5'd0;
            event_popup <= 1'b0; event_kind <= 4'd0; event_value <= 16'd0;
            event_dish <= 4'd0; event_order <= 8'd0;
            add_front <= 1'b0; front_full_shown <= 1'b0; ready_timer <= 12'd0; front_load <= 3'd0;
            item_cost[0] <= 10'd0; item_cost[1] <= 10'd0; item_cost[2] <= 10'd0; item_cost[3] <= 10'd0;
            stats_clear <= 1'b0; front_order_taken <= 1'b0; front_line <= 3'd0; front_no <= 8'd0;
            trans_req <= 1'b0; trans_req_kind <= TK_NONE; trans_req_page <= 3'd0;
            trans_kind <= TK_NONE; trans_phase <= TP_IDLE; trans_level <= 5'd0;
            trans_target <= 3'd0; hold_frames <= 2'd0;
            hi_elem <= 7'd0;
            order_chime <= 1'b0;
            ticker_line <= 2'd0;
            lfsr <= 16'hace1;
            gen_state <= G_IDLE; gen_target <= 2'd0; gen_cand <= 4'd0; gen_probe <= 4'd0;
            gen_cnt <= 3'd0; gen_tot <= 10'd0; gen_start <= 1'b0;
            mode_q <= 4'b0000;
        end else begin
            mode_q <= mode;
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            ticker_line <= (pending != 0 || making != 0) ? 2'd1 : last_done ? 2'd2 : 2'd0;
            event_popup <= 1'b0;
            tally_req <= 1'b0;
            trans_req <= 1'b0;
            gen_start <= 1'b0;
            order_chime <= 1'b0;
            stats_clear <= 1'b0;
            rep_up <= 1'b0; rep_down <= 1'b0;

            // ---------------- key repeat (one key held, not both)
            if (!(k1_down ^ k2_down)) begin
                hold_frames_k <= 6'd0;
            end else if (frame_start) begin
                if (hold_frames_k >= 6'd29) begin
                    hold_frames_k <= 6'd26;
                    rep_up <= k1_down; rep_down <= k2_down;
                end else begin
                    hold_frames_k <= hold_frames_k + 1'b1;
                end
            end

            // ---------------- boot
            if (boot_page_b && page_shown == PAGE_BOOT_A)
                page_shown <= PAGE_BOOT_B;
            if (boot_exit) begin
                trans_req <= 1'b1;
                trans_req_kind <= TK_CENTRE;
                trans_req_page <= PAGE_ORDER;
            end

            // ---------------- keys
            if (keys_ok) begin
                case (mode)
                    4'b0000: begin
                        if (k1 || k2) begin
                            case (page_shown)
                                PAGE_ORDER:
                                    if (count != 0)
                                        sel_order <= k1 ? ((sel_order + 1'b1 >= count) ? 2'd0 : sel_order + 1'b1) :
                                                          ((sel_order == 0) ? count - 1'b1 : sel_order - 1'b1);
                                PAGE_DISH:
                                    sel_dish <= k1 ? sel_dish + 1'b1 : sel_dish - 1'b1;
                                PAGE_SLOGAN:
                                    sel_slogan <= k1 ? ((sel_slogan == 3'd4) ? 3'd0 : sel_slogan + 1'b1) :
                                                       ((sel_slogan == 3'd0) ? 3'd4 : sel_slogan - 1'b1);
                                PAGE_WEATHER:
                                    if (weather_field == 2'd0)
                                        weather_kind <= k1 ? ((weather_kind >= 3'd5) ? 3'd0 : weather_kind + 1'b1) :
                                                             ((weather_kind == 3'd0) ? 3'd5 : weather_kind - 1'b1);
                                default: ;
                            endcase
                        end
                        if (k3) begin
                            case (page_shown)
                                PAGE_ORDER:
                                    if (count != 0)
                                        advance_order;
                                PAGE_DISH: begin
                                    sold_mask[sel_dish] <= !sold_mask[sel_dish];
                                    event_popup <= 1'b1; event_kind <= POPUP_SOLD;
                                    event_dish <= sel_dish;
                                    event_value <= {15'd0, !sold_mask[sel_dish]};
                                end
                                PAGE_SLOGAN: begin
                                    applied_slogan <= sel_slogan + 1'b1;
                                    front_line <= sel_slogan;
                                    ready_timer <= 12'd0;
                                    event_popup <= 1'b1; event_kind <= POPUP_SLOGAN;
                                    event_value <= {13'd0, sel_slogan + 1'b1};
                                end
                                PAGE_WEATHER:
                                    weather_field <= (weather_field == 2'd2) ? 2'd0 : weather_field + 1'b1;
                                PAGE_LINK: begin
                                    stats_clear <= 1'b1;
                                    event_popup <= 1'b1; event_kind <= POPUP_CLEARED;
                                end
                                default: ;
                            endcase
                        end
                        if (k4_short || k4_long) begin
                            trans_req <= 1'b1;
                            trans_req_kind <= k4_short ? TK_NEXT : TK_PREV;
                            trans_req_page <= page_step(page_shown, k4_short);
                        end
                        // Temperature and humidity: a press or a repeat step.
                        if (page_shown == PAGE_WEATHER && (k1 || k2 || rep_up || rep_down)) begin
                            if (weather_field == 2'd1)
                                weather_temp <= (k1 || rep_up) ?
                                                ((weather_temp >= 7'sd40) ? 7'sd40 : weather_temp + 7'sd1) :
                                                ((weather_temp <= -7'sd9) ? -7'sd9 : weather_temp - 7'sd1);
                            else if (weather_field == 2'd2)
                                weather_hum <= (k1 || rep_up) ?
                                               ((weather_hum >= 7'd100) ? 7'd100 : weather_hum + 7'd1) :
                                               ((weather_hum == 7'd0) ? 7'd0 : weather_hum - 7'd1);
                        end
                    end
                    4'b0101: if (k1 || k2) begin
                        ad_index <= k1 ? ((ad_index >= 3'd4) ? 3'd1 : ad_index + 1'b1) :
                                         ((ad_index <= 3'd1) ? 3'd4 : ad_index - 1'b1);
                        event_popup <= 1'b1; event_kind <= POPUP_AD;
                        event_value <= k1 ? ((ad_index >= 3'd4) ? 16'd1 : ad_index + 1'b1) :
                                            ((ad_index <= 3'd1) ? 16'd4 : ad_index - 1'b1);
                    end
                    4'b0110: begin
                        if (k1 || k2) begin
                            // Accent colour: K1 next, K2 previous, 1..10.
                            accent_index <= k1 ? ((accent_index >= 4'd10) ? 4'd10 : accent_index + 1'b1) :
                                                 ((accent_index <= 4'd1) ? 4'd1 : accent_index - 1'b1);
                            event_popup <= 1'b1; event_kind <= POPUP_COLOR;
                            event_value <= k1 ? ((accent_index >= 4'd10) ? 16'd10 : accent_index + 1'b1) :
                                                ((accent_index <= 4'd1) ? 16'd1 : accent_index - 1'b1);
                        end
                        if (k3 && gen_state == G_IDLE && !add_req)
                            gen_start <= 1'b1;
                    end
                    4'b0111: if (k1 || k2) begin
                        // Music: K1 next track, K2 previous, no wrap-around. The
                        // popup value is the track, 0 while the music is off.
                        music_track <= k1 ? ((music_track >= MUSIC_TRACKS) ? MUSIC_TRACKS : music_track + 1'b1) :
                                            ((music_track <= 3'd1) ? 3'd1 : music_track - 1'b1);
                        event_popup <= 1'b1; event_kind <= POPUP_MUSIC;
                        event_value <= !music_on ? 16'd0 :
                                       k1 ? ((music_track >= MUSIC_TRACKS) ? MUSIC_TRACKS : music_track + 1'b1) :
                                            ((music_track <= 3'd1) ? 16'd1 : music_track - 1'b1);
                    end else if (k3) begin
                        music_on <= !music_on;
                        event_popup <= 1'b1; event_kind <= POPUP_MUSIC;
                        event_value <= music_on ? 16'd0 : {13'd0, music_track};
                    end
                    4'b1111: begin
                        // The order board from any page: the first K1/K2/K3
                        // press elsewhere opens it.
                        if ((k1 || k2 || k3) && page_shown != PAGE_ORDER) begin
                            trans_req <= 1'b1;
                            trans_req_kind <= TK_CENTRE;
                            trans_req_page <= PAGE_ORDER;
                        end else if (k3) begin
                            if (count != 0)
                                advance_order;
                        end else if ((k1 || k2) && count != 0) begin
                            sel_order <= k1 ? ((sel_order + 1'b1 >= count) ? 2'd0 : sel_order + 1'b1) :
                                              ((sel_order == 0) ? count - 1'b1 : sel_order - 1'b1);
                        end
                        if (k4_short || k4_long) begin
                            trans_req <= 1'b1;
                            trans_req_kind <= k4_short ? TK_NEXT : TK_PREV;
                            trans_req_page <= page_step(page_shown, k4_short);
                        end
                    end
                    default: ;
                endcase
            end

            // ---------------- switches moved: show the new mode's value
            if (mode != mode_q && ui_live) begin
                case (mode)
                    4'b0101: begin
                        event_popup <= 1'b1; event_kind <= POPUP_AD;
                        event_value <= {13'd0, ad_index};
                    end
                    4'b0110: begin
                        event_popup <= 1'b1; event_kind <= POPUP_COLOR;
                        event_value <= {12'd0, accent_index};
                    end
                    4'b0111: begin
                        event_popup <= 1'b1; event_kind <= POPUP_MUSIC;
                        event_value <= music_on ? {13'd0, music_track} : 16'd0;
                    end
                    default: ;
                endcase
            end

            // ---------------- test order generator: up to three distinct dishes
            // that are not sold out, one or two of each.
            case (gen_state)
                G_IDLE: if (gen_start) begin
                    gen_target <= (lfsr[1:0] == 2'd3) ? 2'd2 : lfsr[1:0] + 1'b1;
                    gen_cand <= lfsr[7:4];
                    gen_probe <= 4'd0;
                    gen_cnt <= 3'd0;
                    gen_tot <= 10'd0;
                    gen_state <= G_PICK;
                end
                G_PICK: begin
                    if (!sold_mask[gen_cand] && !gen_taken) begin
                        gen_item[gen_cnt] <= {gen_qty, gen_cand};
                        gen_tot <= gen_tot + (lfsr[5] ? {3'd0, dish_price(gen_cand), 1'b0} :
                                                         {4'd0, dish_price(gen_cand)});
                        gen_cnt <= gen_cnt + 1'b1;
                        gen_cand <= gen_cand + lfsr[11:9] + 4'd3;
                        gen_probe <= 4'd0;
                        if (gen_cnt + 1'b1 == {1'b0, gen_target})
                            gen_state <= G_DONE;
                    end else if (gen_probe == 4'd15) begin
                        gen_state <= G_DONE;
                    end else begin
                        gen_cand <= gen_cand + 1'b1;
                        gen_probe <= gen_probe + 1'b1;
                    end
                end
                G_DONE: begin
                    gen_state <= G_IDLE;
                    if (gen_cnt == 0) begin
                        event_popup <= 1'b1; event_kind <= POPUP_FULL;
                    end else begin
                        add_req <= 1'b1;
                        add_cnt <= gen_cnt;
                        add_tot <= gen_tot;
                        for (i = 0; i < 4; i = i + 1)
                            add_item[i] <= (i < gen_cnt) ? gen_item[i] : 8'd0;
                    end
                end
                default: gen_state <= G_IDLE;
            endcase

            // ---------------- a front order waiting on the link
            // Load, price each item, then queue the order (three clocks).
            front_load <= {front_load[1:0], 1'b0};
            if (frame_start && !add_req && front_load == 3'd0 && gen_state == G_IDLE && !gen_start &&
                front_order_req != front_order_taken) begin
                front_load[0] <= 1'b1;
                add_cnt <= front_order_count;
                for (i = 0; i < 4; i = i + 1)
                    add_item[i] <= (i < front_order_count) ? front_order_items[i * 8 +: 8] : 8'd0;
            end
            if (front_load[0])
                for (i = 0; i < 4; i = i + 1)
                    item_cost[i] <= add_item[i][7:4] * dish_price(add_item[i][3:0]);
            if (front_load[1]) begin
                add_tot <= item_cost[0] + item_cost[1] + item_cost[2] + item_cost[3];
                add_req <= 1'b1;
                add_front <= 1'b1;
            end
            // The ready text returns to the slogan after a minute.
            if (frame_start && ready_timer != 0) begin
                ready_timer <= ready_timer - 1'b1;
                if (ready_timer == 12'd1)
                    front_line <= applied_slogan - 1'b1;
            end

            // ---------------- add an order (evicting the oldest finished one)
            // Never in the same clock as a key action, which may also move slots.
            if (add_req && !(keys_ok && (k1 || k2 || k3 || k4_short || k4_long))) begin
                if (count == 3'd4 && has_done) begin
                    remove_slot(first_done);     // the append follows next clock
                end else if (count == 3'd4) begin
                    // A front order stays waiting on the link and is retried.
                    add_req <= 1'b0;
                    add_front <= 1'b0;
                    if (!add_front || !front_full_shown) begin
                        event_popup <= 1'b1; event_kind <= POPUP_FULL;
                    end
                    if (add_front)
                        front_full_shown <= 1'b1;
                end else begin
                    add_req <= 1'b0;
                    slot_st[count[1:0]] <= ST_PENDING;
                    slot_no[count[1:0]] <= next_no;
                    slot_tot[count[1:0]] <= add_tot;
                    slot_cnt[count[1:0]] <= add_cnt;
                    slot_front[count[1:0]] <= add_front;
                    for (i = 0; i < 4; i = i + 1)
                        slot_item[{count[1:0], 2'd0} + i] <= add_item[i];
                    add_front <= 1'b0;
                    if (add_front) begin
                        front_order_taken <= front_order_req;
                        front_full_shown <= 1'b0;
                        front_line <= LINE_RECEIVED;
                        front_no <= next_no;
                        ready_timer <= 12'd0;
                    end
                    next_no <= (next_no == 8'd255) ? 8'd1 : next_no + 1'b1;
                    sel_order <= count[1:0];
                    last_done <= 1'b0;
                    order_chime <= 1'b1;
                    event_popup <= 1'b1; event_order <= next_no;
                    event_kind <= POPUP_NEW;
                    if (ui_live && page_shown != PAGE_ORDER) begin
                        trans_req <= 1'b1;
                        trans_req_kind <= TK_CENTRE;
                        trans_req_page <= PAGE_ORDER;
                    end
                end
            end

            // ---------------- keep the selected order inside the queue
            if (count == 0)
                sel_order <= 2'd0;
            else if ({1'b0, sel_order} >= count)
                sel_order <= count - 1'b1;

            // ---------------- transitions, one step per frame
            if (trans_req && trans_phase == TP_IDLE) begin
                trans_kind <= trans_req_kind;
                trans_target <= trans_req_page;
                trans_phase <= TP_OUT;
                trans_level <= 5'd0;
            end else if (frame_start) begin
                case (trans_phase)
                    TP_OUT: begin
                        if (trans_level + trans_step >= 5'd16) begin
                            trans_level <= 5'd16;
                            trans_phase <= TP_HOLD;
                            hold_frames <= 2'd0;
                            page_shown <= trans_target;
                        end else begin
                            trans_level <= trans_level + trans_step;
                        end
                    end
                    TP_HOLD: begin
                        // The composer needs two frame starts to show the new page.
                        if (hold_frames == 2'd3) begin
                            trans_phase <= TP_IN;
                            trans_level <= 5'd0;
                        end else begin
                            hold_frames <= hold_frames + 1'b1;
                        end
                    end
                    TP_IN: begin
                        if (trans_level + trans_step >= 5'd16) begin
                            trans_level <= 5'd0;
                            trans_phase <= TP_IDLE;
                            trans_kind <= TK_NONE;
                        end else begin
                            trans_level <= trans_level + trans_step;
                        end
                    end
                    default: ;
                endcase
            end

            // ---------------- popups
            if (param_active && ui_live) begin
                popup_kind <= {2'b00, param_kind} + 4'd1;
                popup_value <= (param_kind == 2'd3) ? {12'd0, ticker_speed} :
                               (param_kind == 2'd0) ? {8'd0, brightness} :
                               (param_kind == 2'd1) ? {8'd0, contrast} : {8'd0, volume};
                popup_bar <= (param_kind == 2'd3) ? ticker_speed :
                             percent_tenths((param_kind == 2'd0) ? brightness :
                                            (param_kind == 2'd1) ? contrast : volume);
                popup_alpha <= 5'd16;
                popup_timer <= 8'd0;
            end else if (event_popup) begin
                popup_kind <= event_kind;
                popup_value <= event_value;
                popup_dish <= event_dish;
                popup_order <= event_order;
                popup_alpha <= 5'd16;
                popup_timer <= POPUP_FRAMES;
            end else if (frame_start) begin
                if (popup_timer != 0)
                    popup_timer <= popup_timer - 1'b1;
                else if (popup_alpha != 0)
                    popup_alpha <= popup_alpha - 1'b1;
                else
                    popup_kind <= POPUP_NONE;
            end

            // ---------------- highlighted element
            case (page_shown)
                PAGE_ORDER:  hi_elem <= (count != 0) ? ELEM_ORDER + sel_order : 7'd0;
                PAGE_DISH:   hi_elem <= ELEM_DISH + sel_dish;
                PAGE_SLOGAN: hi_elem <= ELEM_SLOGAN + sel_slogan;
                PAGE_WEATHER: hi_elem <= (weather_field == 2'd1) ? ELEM_WX_TEMP :
                                         (weather_field == 2'd2) ? ELEM_WX_HUM : ELEM_WX + weather_kind;
                PAGE_STATS:  hi_elem <= (top_qty != 0) ? ELEM_TOP : 7'd0;
                default:     hi_elem <= 7'd0;
            endcase
        end
    end

    // K3 on the selected order: accept it, mark it ready, then remove it.
    task advance_order;
        begin
            case (slot_st[sel_order])
                ST_PENDING: begin
                    slot_st[sel_order] <= ST_MAKING;
                    event_popup <= 1'b1; event_kind <= POPUP_ACCEPT;
                    event_order <= slot_no[sel_order];
                    if (slot_front[sel_order]) begin
                        front_line <= LINE_MAKING;
                        front_no <= slot_no[sel_order];
                        ready_timer <= 12'd0;
                    end
                end
                ST_MAKING: begin
                    slot_st[sel_order] <= ST_DONE;
                    done_total <= done_total + 1'b1;
                    tally_req <= 1'b1;
                    tally_items_req <= {slot_item[{sel_order, 2'd3}], slot_item[{sel_order, 2'd2}],
                                        slot_item[{sel_order, 2'd1}], slot_item[{sel_order, 2'd0}]};
                    tally_cnt_req <= slot_cnt[sel_order];
                    tally_tot_req <= slot_tot[sel_order];
                    last_done <= 1'b1;
                    event_popup <= 1'b1; event_kind <= POPUP_DONE;
                    event_order <= slot_no[sel_order];
                    if (slot_front[sel_order]) begin
                        front_line <= LINE_READY;
                        front_no <= slot_no[sel_order];
                        ready_timer <= READY_FRAMES;
                    end
                end
                ST_DONE: begin
                    remove_slot(sel_order);
                    event_popup <= 1'b1; event_kind <= POPUP_REMOVED;
                    event_order <= slot_no[sel_order];
                end
                default: ;
            endcase
        end
    endtask

    // Remove a slot and close the gap.
    task remove_slot;
        input [1:0] s;
        integer k, j;
        begin
            for (k = 0; k < 4; k = k + 1) begin
                if (k >= s && k < 3) begin
                    slot_st[k] <= slot_st[k + 1];
                    slot_no[k] <= slot_no[k + 1];
                    slot_tot[k] <= slot_tot[k + 1];
                    slot_cnt[k] <= slot_cnt[k + 1];
                    slot_front[k] <= slot_front[k + 1];
                    for (j = 0; j < 4; j = j + 1)
                        slot_item[k * 4 + j] <= slot_item[(k + 1) * 4 + j];
                end
            end
            slot_st[3] <= ST_EMPTY;
            slot_cnt[3] <= 3'd0;
            slot_front[3] <= 1'b0;
        end
    endtask

    function [3:0] percent_tenths;       // 0..100 -> 0..10
        input [7:0] value;
        reg [15:0] scaled;
        begin
            scaled = value * 8'd205;
            percent_tenths = (value >= 8'd100) ? 4'd10 : scaled[14:11];
        end
    endfunction

    // ------------------------------------------------------------ business statistics
    // Finished orders are tallied one item per clock: servings per dish and
    // category, revenue. A running scan finds the top seller, a sequential
    // divider the average order. The values shown on the statistics page
    // count up from zero each time the page opens: all of them follow one
    // ease-out factor (0, 1/8, 1/4, 1/2, 3/4, 7/8, 15/16, 31/32, 1; four
    // frames per step), applied on the variable bus as one shift and one
    // subtraction.
    reg [15:0] st_revenue, st_sold;
    reg [7:0]  st_q [0:15];
    reg [9:0]  st_cat [0:3];
    reg [31:0] tl_items;
    reg [2:0]  tl_n;
    reg [3:0]  scan_i, scan_best_i;
    reg [7:0]  scan_best_q;
    reg [4:0]  div_step;
    reg [15:0] div_num, div_rem, div_quo, st_avg;
    reg [5:0]  up_frames, up_s, up_m;
    reg [6:0]  up_h;
    reg [5:0]  count_up;                // frames since the page opened, saturating at 36
    wire [3:0] tl_dish = tl_items[3:0];
    wire [3:0] tl_qty = tl_items[7:4];
    // Two clocks per item: read the dish's count, then write it back.
    reg        tl_phase;
    reg [3:0]  tl_dish_q, tl_qty_q;
    reg [7:0]  tl_old;
    wire [8:0] tl_sum = tl_old + tl_qty_q;
    wire [16:0] div_trial = {div_rem[15:0], div_num[15]} - {1'b0, done_total};
    wire       stats_live = page_shown == PAGE_STATS && trans_phase != TP_OUT;

    function [15:0] count_scale;        // value * ease-out factor of the frame count
        input [15:0] v;
        input [5:0]  f;
        begin
            case (f[5:2])
                4'd0:    count_scale = 16'd0;
                4'd1:    count_scale = v >> 3;
                4'd2:    count_scale = v >> 2;
                4'd3:    count_scale = v >> 1;
                4'd4:    count_scale = v - (v >> 2);
                4'd5:    count_scale = v - (v >> 3);
                4'd6:    count_scale = v - (v >> 4);
                4'd7:    count_scale = v - (v >> 5);
                default: count_scale = v;
            endcase
        end
    endfunction

    integer s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_revenue <= 16'd0; st_sold <= 16'd0; tl_items <= 32'd0; tl_n <= 3'd0;
            tl_phase <= 1'b0; tl_dish_q <= 4'd0; tl_qty_q <= 4'd0; tl_old <= 8'd0;
            for (s = 0; s < 16; s = s + 1) st_q[s] <= 8'd0;
            for (s = 0; s < 4; s = s + 1) st_cat[s] <= 10'd0;
            scan_i <= 4'd0; scan_best_i <= 4'd0; scan_best_q <= 8'd0; top_dish <= 4'd0; top_qty <= 8'd0;
            div_step <= 5'd0; div_num <= 16'd0; div_rem <= 16'd0; div_quo <= 16'd0; st_avg <= 16'd0;
            up_frames <= 6'd0; up_s <= 6'd0; up_m <= 6'd0; up_h <= 7'd0;
            count_up <= 6'd0;
        end else begin
            // Tally.
            if (tally_req) begin
                st_revenue <= st_revenue + tally_tot_req;
                tl_items <= tally_items_req;
                tl_n <= tally_cnt_req;
                tl_phase <= 1'b0;
            end else if (tl_n != 3'd0 && !tl_phase) begin
                tl_dish_q <= tl_dish;
                tl_qty_q <= tl_qty;
                tl_old <= st_q[tl_dish];
                tl_phase <= 1'b1;
            end else if (tl_n != 3'd0) begin
                st_q[tl_dish_q] <= tl_sum[8] ? 8'd255 : tl_sum[7:0];
                st_sold <= st_sold + tl_qty_q;
                st_cat[tl_dish_q[3:2]] <= st_cat[tl_dish_q[3:2]] + tl_qty_q;
                tl_items <= {8'd0, tl_items[31:8]};
                tl_n <= tl_n - 1'b1;
                tl_phase <= 1'b0;
            end
            // Top seller: one dish per clock.
            scan_i <= scan_i + 1'b1;
            if (scan_i == 4'd0 || st_q[scan_i] > scan_best_q) begin
                scan_best_q <= st_q[scan_i];
                scan_best_i <= scan_i;
            end
            if (scan_i == 4'd15) begin
                top_dish <= (st_q[15] > scan_best_q) ? 4'd15 : scan_best_i;
                top_qty <= (st_q[15] > scan_best_q) ? st_q[15] : scan_best_q;
            end
            // Average order: revenue / completed orders, restoring division.
            if (div_step == 5'd0) begin
                div_num <= st_revenue;
                div_rem <= 16'd0;
                div_quo <= 16'd0;
                div_step <= 5'd16;
            end else begin
                div_num <= {div_num[14:0], 1'b0};
                if (!div_trial[16]) begin
                    div_rem <= div_trial[15:0];
                    div_quo <= {div_quo[14:0], 1'b1};
                end else begin
                    div_rem <= {div_rem[14:0], div_num[15]};
                    div_quo <= {div_quo[14:0], 1'b0};
                end
                div_step <= div_step - 1'b1;
                if (div_step == 5'd1)
                    st_avg <= (done_total == 16'd0) ? 16'd0 :
                              {div_quo[14:0], !div_trial[16]};
            end
            // Uptime at 60 frames per second.
            if (frame_start) begin
                if (up_frames == 6'd59) begin
                    up_frames <= 6'd0;
                    if (up_s == 6'd59) begin
                        up_s <= 6'd0;
                        if (up_m == 6'd59) begin
                            up_m <= 6'd0;
                            up_h <= (up_h == 7'd99) ? 7'd0 : up_h + 1'b1;
                        end else begin
                            up_m <= up_m + 1'b1;
                        end
                    end else begin
                        up_s <= up_s + 1'b1;
                    end
                end else begin
                    up_frames <= up_frames + 1'b1;
                end
            end
            // Count-up of the shown values.
            if (frame_start)
                count_up <= !stats_live ? 6'd0 : (count_up >= 6'd36) ? 6'd36 : count_up + 1'b1;
        end
    end

    // ------------------------------------------------------------ variable bus
    wire [6:0] weather_temp_off = weather_temp + 7'sd10;     // 1..50
    wire [4:0] weather_temp_bar = weather_temp_off[5:1];     // 0..25 segments
    wire [4:0] sold_count = sold_mask[0] + sold_mask[1] + sold_mask[2] + sold_mask[3] +
                            sold_mask[4] + sold_mask[5] + sold_mask[6] + sold_mask[7] +
                            sold_mask[8] + sold_mask[9] + sold_mask[10] + sold_mask[11] +
                            sold_mask[12] + sold_mask[13] + sold_mask[14] + sold_mask[15];
    // Counted-up statistics: the raw value of var_id, registered (the composer
    // holds var_id two clocks), then scaled once.
    reg [15:0] stat_raw, stat_raw_q;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) stat_raw_q <= 16'd0;
        else stat_raw_q <= stat_raw;
    always @* begin
        stat_raw = 16'd0;
        case (var_id)
            VAR_S_DONE:    stat_raw = done_total;
            VAR_S_REVENUE: stat_raw = st_revenue;
            VAR_S_SOLD:    stat_raw = st_sold;
            VAR_S_AVG:     stat_raw = st_avg;
            default:
                if (var_id >= VAR_S_Q0 && var_id < VAR_S_Q0 + 6'd16)
                    stat_raw = {8'd0, st_q[var_id - VAR_S_Q0]};
                else if (var_id >= VAR_S_CAT0 && var_id < VAR_S_CAT0 + 6'd4)
                    stat_raw = {6'd0, st_cat[var_id - VAR_S_CAT0]};
        endcase
    end
    always @* begin
        var_value = 16'd0;
        case (var_id)
            VAR_PAGE:           var_value = {13'd0, page_shown};
            VAR_MODE:           var_value = {12'd0, mode};
            VAR_PENDING:        var_value = {12'd0, pending};
            VAR_MAKING:         var_value = {12'd0, making};
            VAR_DONE_TOTAL:     var_value = done_total;
            VAR_ORDER_COUNT:    var_value = {13'd0, count};
            VAR_SEL_ORDER:      var_value = {14'd0, sel_order};
            VAR_SEL_DISH:       var_value = {12'd0, sel_dish};
            VAR_SEL_SLOGAN:     var_value = {13'd0, sel_slogan};
            VAR_APPLIED_SLOGAN: var_value = {13'd0, applied_slogan};
            VAR_TICKER_SPEED:   var_value = {12'd0, ticker_speed};
            VAR_AD_INDEX:       var_value = {13'd0, ad_index};
            VAR_LINK_UP:        var_value = {15'd0, link_up};
            VAR_HB_COUNT:       var_value = stat_status;
            VAR_LAST_SEQ:       var_value = stat_seq;
            VAR_RETX:           var_value = stat_retx;
            VAR_RX_FRAMES:      var_value = stat_rx;
            VAR_TX_FRAMES:      var_value = stat_tx;
            VAR_BOOT_STEP:      var_value = {12'd0, boot_step};
            VAR_POPUP_KIND:     var_value = {12'd0, popup_kind};
            VAR_POPUP_VALUE:    var_value = popup_value;
            VAR_POPUP_BAR:      var_value = {12'd0, popup_bar};
            VAR_SOLD_COUNT:     var_value = {11'd0, sold_count};
            VAR_SOLD_MASK:      var_value = sold_mask;
            VAR_POPUP_DISH:     var_value = {12'd0, popup_dish};
            VAR_BOOT_PROGRESS:  var_value = {11'd0, boot_progress};
            VAR_POPUP_ORDER_NO: var_value = {8'd0, popup_order};
            VAR_MUSIC:          var_value = {13'd0, music_track};
            default: begin
                if (page_shown == PAGE_WEATHER && var_id >= 6'd28) begin
                    case (var_id)
                        VAR_W_KIND:     var_value = {13'd0, weather_kind};
                        VAR_W_FIELD:    var_value = {14'd0, weather_field};
                        VAR_W_TEMP_ABS: var_value = {10'd0, weather_abs};
                        VAR_W_TEMP_NEG: var_value = {15'd0, weather_neg};
                        VAR_W_BAND:     var_value = {13'd0, weather_band};
                        VAR_W_BAND_TXT: var_value = {12'd0, 4'd6 + {1'b0, weather_band}};
                        VAR_W_REC:      var_value = {12'd0, 4'd11 + {1'b0, weather_band}};
                        VAR_W_TEMP_BAR: var_value = {11'd0, weather_temp_bar};
                        VAR_W_HUM:      var_value = {9'd0, weather_hum};
                        VAR_W_HUM_BAR:  var_value = {11'd0, weather_hum[6:2]};
                        default: ;
                    endcase
                end else if (page_shown == PAGE_STATS && var_id >= 6'd28) begin
                    case (var_id)
                        VAR_S_UP_H:     var_value = {9'd0, up_h};
                        VAR_S_UP_M:     var_value = {10'd0, up_m};
                        VAR_S_UP_S:     var_value = {10'd0, up_s};
                        VAR_S_TOP:      var_value = {12'd0, top_dish};
                        VAR_S_TOP_QTY:  var_value = {8'd0, top_qty};
                        default:        var_value = count_scale(stat_raw_q, count_up);
                    endcase
                end else if (var_id >= 6'd28 && var_id < 6'd32)
                    var_value = {14'd0, slot_st[var_id[1:0]]};
                else if (var_id >= 6'd32 && var_id < 6'd36)
                    var_value = {8'd0, slot_no[var_id[1:0]]};
                else if (var_id >= 6'd36 && var_id < 6'd40)
                    var_value = {6'd0, slot_tot[var_id[1:0]]};
                else if (var_id >= 6'd40 && var_id < 6'd44)
                    var_value = {13'd0, slot_cnt[var_id[1:0]]};
                else if (var_id >= 6'd44 && var_id < 6'd60)
                    var_value = {8'd0, slot_item[var_id - 6'd44]};
            end
        endcase
    end
endmodule
