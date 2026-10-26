`timescale 1ns/1ps

// Kitchen side of the board-to-board link.
//
// Frames (payload after the EtherType; byte 0 magic 0xA7, 1 sender, 2 type,
// 3 frame counter):
//   front status  (F, type 1)  4 order seq, 5 bit0 order pending, 6 item count,
//                              7-10 items {qty, dish}, 11 ticker version held,
//                              12 front mode, 13 weather card version held
//   kitchen status(K, type 2)  4 order ack, 5-6 sold-out mask, 7 advert,
//                              8 ticker version, 9 applied slogan,
//                              10 front ticker line, 11 order number in it,
//                              12 weather card version, 13 its weather kind
//   ticker chunk  (K, type 3)  4 version, 5 chunk 0-3, 8.. 256 words of 32 bits
//   card chunk    (K, type 4)  the same for the weather card of the advert screen
//
// Both sides send a status frame every millisecond; a side is "up" while the
// other side's status keeps arriving. Everything is state, repeated until
// the other side echoes it, so lost frames only delay an update:
//   - an order is taken once (sequence number) and acknowledged in the
//     kitchen status after the kitchen core has accepted it;
//   - the front ticker text is streamed as glyph bitmaps whenever its
//     version differs from the version the front reports. The kitchen holds
//     the ticker font, so the front needs no font for these texts.
module kitchen_link #(
    parameter integer STATUS_PERIOD = 125_000,       // 1 ms at 125 MHz
    parameter integer CHUNK_PERIOD = 31_250,         // 250 us
    parameter integer LINK_TIMEOUT = 12_500_000      // 100 ms
) (
    input  wire        clk50,
    input  wire        rst_n,
    // RGMII pins.
    output wire [3:0]  rgmii_txd,
    output wire        rgmii_tx_ctl,
    output wire        rgmii_txc,
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rx_ctl,
    input  wire        rgmii_rxc,
    // Application, in app_clk.
    input  wire        app_clk,
    input  wire        app_rst_n,
    input  wire [15:0] sold_mask,
    input  wire [2:0]  ad_index,            // 1..4
    input  wire [2:0]  applied_slogan,
    input  wire [2:0]  front_line,          // front ticker text 0..7
    input  wire [7:0]  front_no,            // order number shown in it
    input  wire [2:0]  weather_kind,        // weather card: 0 晴天 .. 5 雪天
    input  wire [2:0]  weather_band,        // feel 0 炎热 .. 4 寒冷
    input  wire        weather_neg,         // temperature sign and digits
    input  wire [3:0]  weather_tens,
    input  wire [3:0]  weather_ones,
    input  wire        stats_clear,         // one app_clk pulse
    output wire        link_up,
    output wire        order_req,           // toggles when a front order waits
    input  wire        order_taken,         // toggle back once it is on the board
    output reg  [2:0]  order_count,
    output reg  [31:0] order_items,         // item 0 in [7:0]
    output reg  [15:0] stat_status,         // front status frames received
    output reg  [15:0] stat_seq,            // last front order sequence
    output reg  [15:0] stat_retx,           // ticker resend rounds
    output reg  [15:0] stat_rx,             // good frames received
    output reg  [15:0] stat_tx,             // frames sent
    output wire        led_rx,
    output wire        led_tx
);
`include "kitchen_front_ticker.vh"

    localparam [7:0] MAGIC = 8'hA7, ID_FRONT = 8'h46, ID_KITCHEN = 8'h4B;
    reg        clear_req;                  // toggles in app_clk on stats_clear
    reg [7:0]  hold_count;                 // order handed to the app
    reg [31:0] hold_items;

    wire        clk125, tx_rst_n, rx_clk, rx_rst_n;
    reg         tx_start;
    reg  [10:0] tx_length;
    wire        tx_busy;
    wire [10:0] tx_index;
    reg  [7:0]  tx_byte3;
    wire        rx_valid, rx_end, rx_good;
    wire [7:0]  rx_byte;
    wire [10:0] rx_index;
    eth_node #(.SRC_MAC(48'h02_4B_49_54_43_48)) u_node (
        .clk50(clk50), .rst_n(rst_n),
        .rgmii_txd(rgmii_txd), .rgmii_tx_ctl(rgmii_tx_ctl), .rgmii_txc(rgmii_txc),
        .rgmii_rxd(rgmii_rxd), .rgmii_rx_ctl(rgmii_rx_ctl), .rgmii_rxc(rgmii_rxc),
        .clk125(clk125), .tx_rst_n(tx_rst_n), .tx_start(tx_start), .tx_length(tx_length),
        .tx_busy(tx_busy), .tx_index(tx_index), .tx_data(tx_byte3),
        .rx_clk(rx_clk), .rx_rst_n(rx_rst_n), .rx_valid(rx_valid), .rx_byte(rx_byte),
        .rx_index(rx_index), .rx_end(rx_end), .rx_good(rx_good));

    // ================================================================ receive (rx_clk)
    reg        hdr_ok;
    reg [7:0]  sh_seq, sh_flags, sh_count, sh_have, sh_mode, sh_card;
    reg [31:0] sh_items;
    reg [7:0]  rx_seq, rx_flags, rx_count, rx_have, rx_card;
    reg [31:0] rx_items;
    reg        rx_toggle;                  // a front status was committed
    reg        rx_frame_toggle;            // any good frame
    always @(posedge rx_clk or negedge rx_rst_n) begin
        if (!rx_rst_n) begin
            hdr_ok <= 1'b0; sh_seq <= 8'd0; sh_flags <= 8'd0; sh_count <= 8'd0; sh_have <= 8'd0;
            sh_mode <= 8'd0; sh_items <= 32'd0; rx_seq <= 8'd0; rx_flags <= 8'd0; rx_count <= 8'd0;
            sh_card <= 8'd0; rx_card <= 8'd0;
            rx_have <= 8'd0; rx_items <= 32'd0; rx_toggle <= 1'b0; rx_frame_toggle <= 1'b0;
        end else begin
            if (rx_valid) begin
                case (rx_index)
                    11'd12: hdr_ok <= rx_byte == 8'h88;
                    11'd13: hdr_ok <= hdr_ok && rx_byte == 8'hB5;
                    11'd14: hdr_ok <= hdr_ok && rx_byte == MAGIC;
                    11'd15: hdr_ok <= hdr_ok && rx_byte == ID_FRONT;
                    11'd16: hdr_ok <= hdr_ok && rx_byte == 8'd1;
                    11'd18: sh_seq <= rx_byte;
                    11'd19: sh_flags <= rx_byte;
                    11'd20: sh_count <= rx_byte;
                    11'd21: sh_items[7:0] <= rx_byte;
                    11'd22: sh_items[15:8] <= rx_byte;
                    11'd23: sh_items[23:16] <= rx_byte;
                    11'd24: sh_items[31:24] <= rx_byte;
                    11'd25: sh_have <= rx_byte;
                    11'd26: sh_mode <= rx_byte;
                    11'd27: sh_card <= rx_byte;
                    default: ;
                endcase
            end
            if (rx_end && rx_good) begin
                rx_frame_toggle <= ~rx_frame_toggle;
                if (hdr_ok) begin
                    rx_seq <= sh_seq; rx_flags <= sh_flags; rx_count <= sh_count;
                    rx_items <= sh_items; rx_have <= sh_have; rx_card <= sh_card;
                    rx_toggle <= ~rx_toggle;
                end
            end
        end
    end

    // ================================================================ link state (clk125)
    // The rx fields are stable for a millisecond after each toggle.
    (* async_reg = "true" *) reg [2:0] rx_toggle_sync, rx_frame_sync;
    reg [7:0]  front_seq, front_count, front_have, front_card;
    reg        front_pending;
    reg [31:0] front_items;
    reg [23:0] silence;
    reg        up;
    reg [7:0]  ack_seq;                    // last order the kitchen has taken
    reg [7:0]  take_seq;                   // order handed to the core
    reg        req_toggle;
    (* async_reg = "true" *) reg [1:0] taken_sync;
    reg        taken_seen;
    reg [15:0] cnt_status, cnt_retx, cnt_rx, cnt_tx;
    (* async_reg = "true" *) reg [1:0] clear_sync;
    reg        clear_seen;
    always @(posedge clk125 or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            rx_toggle_sync <= 3'd0; rx_frame_sync <= 3'd0;
            front_seq <= 8'd0; front_count <= 8'd0; front_have <= 8'd0; front_pending <= 1'b0;
            front_card <= 8'd0;
            front_items <= 32'd0; silence <= LINK_TIMEOUT; up <= 1'b0;
            ack_seq <= 8'd0; take_seq <= 8'd0; req_toggle <= 1'b0;
            hold_count <= 8'd0; hold_items <= 32'd0;
            taken_sync <= 2'd0; taken_seen <= 1'b0;
            cnt_status <= 16'd0; cnt_rx <= 16'd0; clear_sync <= 2'd0; clear_seen <= 1'b0;
        end else begin
            rx_toggle_sync <= {rx_toggle_sync[1:0], rx_toggle};
            rx_frame_sync <= {rx_frame_sync[1:0], rx_frame_toggle};
            taken_sync <= {taken_sync[0], order_taken};
            clear_sync <= {clear_sync[0], clear_req};
            if (rx_frame_sync[2] != rx_frame_sync[1])
                cnt_rx <= cnt_rx + 1'b1;
            if (rx_toggle_sync[2] != rx_toggle_sync[1]) begin
                front_seq <= rx_seq; front_pending <= rx_flags[0];
                front_count <= rx_count; front_items <= rx_items; front_have <= rx_have;
                front_card <= rx_card;
                cnt_status <= cnt_status + 1'b1;
                silence <= 24'd0;
                up <= 1'b1;
            end else if (silence != LINK_TIMEOUT) begin
                silence <= silence + 1'b1;
            end else begin
                up <= 1'b0;
            end
            // A new pending order goes to the core once; it is acknowledged
            // after the core reports it on the board.
            if (up && front_pending && front_seq != ack_seq && front_seq != take_seq &&
                req_toggle == taken_seen) begin
                take_seq <= front_seq;
                hold_count <= front_count;
                hold_items <= front_items;
                req_toggle <= ~req_toggle;
            end
            if (taken_sync[1] != taken_seen) begin
                taken_seen <= taken_sync[1];
                ack_seq <= take_seq;
            end
            if (clear_sync[1] != clear_seen) begin
                clear_seen <= clear_sync[1];
                cnt_status <= 16'd0; cnt_rx <= 16'd0;
            end
        end
    end

    // ================================================================ app inputs (clk125)
    // Stable-sample the application values: take them once two samples agree.
    (* async_reg = "true" *) reg [32:0] app_s0, app_s1;
    (* async_reg = "true" *) reg [14:0] wx_s0, wx_s1;
    reg [14:0] k_wx;                        // {kind, band, neg, tens, ones}
    reg [7:0]  card_version;
    reg [15:0] k_sold;
    reg [2:0]  k_ad;
    reg [2:0]  k_slogan, k_line;
    reg [7:0]  k_no;
    reg [7:0]  ticker_version;
    always @(posedge clk125 or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            app_s0 <= 33'd0; app_s1 <= 33'd0;
            k_sold <= 16'd0; k_ad <= 3'd1; k_slogan <= 3'd1; k_line <= 3'd0; k_no <= 8'd0;
            ticker_version <= 8'd1;
            wx_s0 <= 15'd0; wx_s1 <= 15'd0; k_wx <= 15'd0; card_version <= 8'd1;
        end else begin
            wx_s0 <= {weather_kind, weather_band, weather_neg, weather_tens, weather_ones};
            wx_s1 <= wx_s0;
            if (wx_s0 == wx_s1 && wx_s1 != k_wx) begin
                k_wx <= wx_s1;
                card_version <= (card_version == 8'd255) ? 8'd1 : card_version + 1'b1;
            end
            app_s0 <= {sold_mask, ad_index, applied_slogan, front_line, front_no};
            app_s1 <= app_s0;
            if (app_s0 == app_s1) begin
                {k_sold, k_ad, k_slogan} <= app_s1[32:11];
                if (app_s1[10:8] != k_line || app_s1[7:0] != k_no) begin
                    k_line <= app_s1[10:8];
                    k_no <= app_s1[7:0];
                    ticker_version <= (ticker_version == 8'd255) ? 8'd1 : ticker_version + 1'b1;
                end
            end
        end
    end

    // ================================================================ transmit (clk125)
    reg [17:0] status_timer, chunk_timer;
    reg        status_due, chunk_due;
    reg [1:0]  chunk, chunk_sent;           // chunk being sent / next chunk
    reg        sending_chunk;
    reg        sending_card;                // the chunk belongs to the weather card
    reg        round_card;                  // stream of the round in progress
    reg [14:0] tx_wx;                       // weather of the card in flight
    reg [7:0]  tx_seq;
    reg [2:0]  tx_line;                     // ticker content of the frame in flight
    reg [7:0]  tx_no, tx_version;
    reg [7:0]  status_ack;
    reg [7:0]  round_version;               // version of the last round started
    always @(posedge clk125 or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            status_timer <= 18'd0; chunk_timer <= 18'd0; status_due <= 1'b0; chunk_due <= 1'b0;
            chunk <= 2'd0; chunk_sent <= 2'd0; sending_chunk <= 1'b0; tx_seq <= 8'd0;
            tx_start <= 1'b0; tx_length <= 11'd46; tx_line <= 3'd0; tx_no <= 8'd0;
            tx_version <= 8'd0; status_ack <= 8'd0; cnt_retx <= 16'd0; cnt_tx <= 16'd0;
            round_version <= 8'd0;
            sending_card <= 1'b0; round_card <= 1'b0; tx_wx <= 15'd0;
        end else begin
            tx_start <= 1'b0;
            if (status_timer == STATUS_PERIOD - 1) begin
                status_timer <= 18'd0;
                status_due <= 1'b1;
            end else begin
                status_timer <= status_timer + 1'b1;
            end
            if (chunk_timer == CHUNK_PERIOD - 1) begin
                chunk_timer <= 18'd0;
                chunk_due <= up && (front_have != ticker_version || front_card != card_version);
            end else begin
                chunk_timer <= chunk_timer + 1'b1;
            end
            if (!tx_busy && !tx_start) begin
                if (status_due) begin
                    status_due <= 1'b0;
                    sending_chunk <= 1'b0;
                    status_ack <= ack_seq;
                    tx_length <= 11'd46;
                    tx_start <= 1'b1;
                    tx_seq <= tx_seq + 1'b1;
                    cnt_tx <= cnt_tx + 1'b1;
                end else if (chunk_due) begin
                    chunk_due <= 1'b0;
                    sending_chunk <= 1'b1;
                    chunk <= chunk_sent;
                    chunk_sent <= chunk_sent + 1'b1;
                    // A round is four chunks of one stream: the ticker when the
                    // front's copy is old, else the weather card.
                    if (chunk_sent == 2'd0) begin
                        round_card <= front_have == ticker_version;
                        sending_card <= front_have == ticker_version;
                        // Another round of the same text: the last one was lost.
                        if (front_have != ticker_version && round_version == ticker_version)
                            cnt_retx <= cnt_retx + 1'b1;
                        if (front_have != ticker_version)
                            round_version <= ticker_version;
                    end else begin
                        sending_card <= round_card;
                    end
                    tx_line <= k_line;
                    tx_no <= k_no;
                    tx_wx <= k_wx;
                    tx_version <= (chunk_sent == 2'd0 ? front_have == ticker_version : round_card) ?
                                  card_version : ticker_version;
                    tx_length <= 11'd1032;
                    tx_start <= 1'b1;
                    tx_seq <= tx_seq + 1'b1;
                    cnt_tx <= cnt_tx + 1'b1;
                end
            end
            if (clear_sync[1] != clear_seen)
                cnt_retx <= 16'd0;
        end
    end

    // Payload bytes, four clocks after tx_index.
    // Stage 1: header byte, glyph word index. Stage 2: ROM address.
    // Stage 3: ROM. Stage 4: output byte.
    reg [7:0]  hdr1;
    reg [11:0] rom_addr;
    reg        row_blank;                               // rows 28-31 of a cell are empty
    wire [10:0] data_pos = tx_index - 11'd8;
    reg  [9:0]  word;                                   // chunk * 256 + word (stage 1)
    // Cell code in two stages ahead of stage 1: the cell of the word two
    // clocks ahead (tx_index steps by one per clock), then its code.
    wire [10:0] pos_ahead = tx_index - 11'd6;           // data_pos two clocks later
    reg  [4:0]  card_cell_no;                           // cell, two clocks ahead
    wire [8:0]  ticker_code = front_ticker_code(tx_line, card_cell_no);
    reg  [7:0]  card_code;
    wire [8:0]  code_next = sending_card ? {1'b0, card_code} : ticker_code;
    reg  [8:0]  code_ahead;                             // code, one clock ahead
    reg  [8:0]  code;                                   // cell code of the word (stage 1)
    always @(posedge clk125) begin
        card_cell_no <= {chunk, pos_ahead[9:7]};
        code_ahead <= code_next;
    end
    reg  [7:0]  glyph;
    // Weather card cells: 0, 1, 16, 17 icon quarters; 3-4 weather; 6-8
    // temperature and ℃; 10-13 体感 + feel; 19-20 推荐; 22-30 dishes.
    wire [2:0]  wx_kind = tx_wx[14:12];
    wire [2:0]  wx_band = tx_wx[11:9];
    wire        wx_neg = tx_wx[8];
    wire [3:0]  wx_tens = tx_wx[7:4];
    wire [3:0]  wx_ones = tx_wx[3:0];
    always @* begin
        card_code = 8'd0;
        case (card_cell_no)
            5'd0:  card_code = card_icon(wx_kind, 2'd0);
            5'd1:  card_code = card_icon(wx_kind, 2'd1);
            5'd16: card_code = card_icon(wx_kind, 2'd2);
            5'd17: card_code = card_icon(wx_kind, 2'd3);
            5'd3:  card_code = card_weather(wx_kind, 1'b0);
            5'd4:  card_code = card_weather(wx_kind, 1'b1);
            5'd6:  card_code = wx_neg ? CARD_MINUS :
                               (wx_tens != 4'd0) ? TICKER_DIGIT0 + wx_tens : 8'd0;
            5'd7:  card_code = TICKER_DIGIT0 + wx_ones;
            5'd8:  card_code = CARD_DEGREE;
            5'd10: card_code = CARD_TI;
            5'd11: card_code = CARD_GAN;
            5'd12: card_code = card_band(wx_band, 1'b0);
            5'd13: card_code = card_band(wx_band, 1'b1);
            5'd19: card_code = CARD_TUI;
            5'd20: card_code = CARD_JIAN;
            default:
                if (card_cell_no >= 5'd22)
                    card_code = card_recommend(wx_band, card_cell_no - 5'd22);
        endcase
    end
    reg  [3:0]  digit2, digit1, digit0;              // order number, decimal
    always @(posedge clk125) begin
        digit2 <= tx_no / 8'd100;
        digit1 <= (tx_no / 8'd10) % 8'd10;
        digit0 <= tx_no % 8'd10;
    end
    always @* begin
        if (code[8]) begin                                // order number digit
            case (code[1:0])
                2'd0: glyph = TICKER_DIGIT0 + digit2;
                2'd1: glyph = TICKER_DIGIT0 + digit1;
                default: glyph = TICKER_DIGIT0 + digit0;
            endcase
        end else begin
            glyph = code[7:0];
        end
    end
    always @* begin
        hdr1 = 8'd0;
        case (tx_index)
            11'd0: hdr1 = MAGIC;
            11'd1: hdr1 = ID_KITCHEN;
            11'd2: hdr1 = sending_chunk ? (sending_card ? 8'd4 : 8'd3) : 8'd2;
            11'd3: hdr1 = tx_seq;
            11'd4: hdr1 = sending_chunk ? tx_version : status_ack;
            11'd5: hdr1 = sending_chunk ? {6'd0, chunk} : k_sold[15:8];
            11'd6: hdr1 = sending_chunk ? 8'd0 : k_sold[7:0];
            11'd7: hdr1 = sending_chunk ? 8'd0 : {5'd0, k_ad};
            11'd8: hdr1 = sending_chunk ? 8'd0 : ticker_version;
            11'd9: hdr1 = sending_chunk ? 8'd0 : {5'd0, k_slogan};
            11'd10: hdr1 = sending_chunk ? 8'd0 : {5'd0, k_line};
            11'd11: hdr1 = sending_chunk ? 8'd0 : k_no;
            11'd12: hdr1 = sending_chunk ? 8'd0 : card_version;
            11'd13: hdr1 = sending_chunk ? 8'd0 : {5'd0, k_wx[14:12]};
            default: hdr1 = 8'd0;
        endcase
    end
    reg [7:0]  hdr_q1, hdr_q2, hdr_q3;
    reg        use_rom1, use_rom2, use_rom3, blank3;
    reg [1:0]  sel_q1, sel_q2, sel_q3;
    wire [31:0] rom_word;
    always @(posedge clk125 or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            hdr_q1 <= 8'd0; hdr_q2 <= 8'd0; hdr_q3 <= 8'd0;
            use_rom1 <= 1'b0; use_rom2 <= 1'b0; use_rom3 <= 1'b0; blank3 <= 1'b0; row_blank <= 1'b0;
            sel_q1 <= 2'd0; sel_q2 <= 2'd0; sel_q3 <= 2'd0;
            word <= 10'd0; rom_addr <= 12'd0; tx_byte3 <= 8'd0; code <= 9'd0;
        end else begin
            // stage 1
            hdr_q1 <= hdr1;
            use_rom1 <= sending_chunk && tx_index >= 11'd8;
            sel_q1 <= data_pos[1:0];
            word <= {chunk, data_pos[9:2]};
            code <= code_ahead;
            // stage 2
            hdr_q2 <= hdr_q1; use_rom2 <= use_rom1; sel_q2 <= sel_q1;
            rom_addr <= {glyph, 5'd0} - {glyph, 2'd0} + word[4:0];     // glyph * 28 + row
            row_blank <= word[4:2] == 3'd7 || glyph == 8'd0;
            // stage 3 (ROM)
            hdr_q3 <= hdr_q2; use_rom3 <= use_rom2; sel_q3 <= sel_q2; blank3 <= row_blank;
            // stage 4: big-endian words; the 28-pixel row is in [27:0], leftmost in bit 27
            if (use_rom3 && blank3)
                tx_byte3 <= 8'd0;
            else if (use_rom3)
                case (sel_q3)
                    2'd0: tx_byte3 <= rom_word[31:24];
                    2'd1: tx_byte3 <= rom_word[23:16];
                    2'd2: tx_byte3 <= rom_word[15:8];
                    default: tx_byte3 <= rom_word[7:0];
                endcase
            else
                tx_byte3 <= hdr_q3;
        end
    end
    kitchen_rom #(.WIDTH(32), .DEPTH(4096), .ADDR_W(12), .FILE("kitchen_front_ticker"),
                  .IMPLEMENT("32K")) u_font (.clk(clk125), .addr(rom_addr), .data(rom_word));

    // ================================================================ app outputs
    // Toggle-handshaked order data and stable-sampled statistics.
    (* async_reg = "true" *) reg [2:0] req_sync_app;
    (* async_reg = "true" *) reg [1:0] up_sync_app;
    (* async_reg = "true" *) reg [79:0] stat_s0, stat_s1;
    always @(posedge app_clk or negedge app_rst_n) begin
        if (!app_rst_n) begin
            req_sync_app <= 3'd0; up_sync_app <= 2'd0; order_count <= 3'd0; order_items <= 32'd0;
            stat_s0 <= 80'd0; stat_s1 <= 80'd0; stat_status <= 16'd0; stat_seq <= 16'd0;
            stat_retx <= 16'd0; stat_rx <= 16'd0; stat_tx <= 16'd0; clear_req <= 1'b0;
        end else begin
            req_sync_app <= {req_sync_app[1:0], req_toggle};
            up_sync_app <= {up_sync_app[0], up};
            // The order data is stable once the toggle has crossed.
            if (req_sync_app[2] != req_sync_app[1]) begin
                order_count <= hold_count[2:0];
                order_items <= hold_items;
            end
            stat_s0 <= {cnt_status, {8'd0, ack_seq}, cnt_retx, cnt_rx, cnt_tx};
            stat_s1 <= stat_s0;
            if (stat_s0 == stat_s1)
                {stat_status, stat_seq, stat_retx, stat_rx, stat_tx} <= stat_s1;
            if (stats_clear)
                clear_req <= ~clear_req;
        end
    end
    // order_req follows the toggle one clock after the data is latched.
    reg req_out;
    always @(posedge app_clk or negedge app_rst_n)
        if (!app_rst_n) req_out <= 1'b0;
        else if (req_sync_app[2] != req_sync_app[1]) req_out <= req_sync_app[1];
    assign order_req = req_out;
    assign link_up = up_sync_app[1];

    // Activity lights: stretch each frame to about 30 ms.
    reg [21:0] rx_light, tx_light;
    always @(posedge clk125 or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            rx_light <= 22'd0; tx_light <= 22'd0;
        end else begin
            rx_light <= (rx_frame_sync[2] != rx_frame_sync[1]) ? 22'h3FFFFF :
                        (rx_light != 0) ? rx_light - 1'b1 : 22'd0;
            tx_light <= tx_start ? 22'h3FFFFF : (tx_light != 0) ? tx_light - 1'b1 : 22'd0;
        end
    end
    assign led_rx = rx_light[21];
    assign led_tx = tx_light[21];
endmodule
