`timescale 1ns/1ps

// Front-end (交互端) side of the board-to-board link. The frame layout and
// protocol are described in kitchen_link.v of the kitchen project.
//
// The front sends its status every millisecond: the pending order (repeated
// until the kitchen acknowledges its sequence number), the ticker and weather
// card versions it holds and its switch mode. It receives the kitchen status
// (order ack, sold-out mask, advert, ticker and card versions) and the glyph
// chunks of the ticker (type 3) and of the weather card (type 4), which are
// written straight into the ticker RAM and the card RAM.
module front_link #(
    parameter integer STATUS_PERIOD = 125_000,       // 1 ms at 125 MHz
    parameter integer LINK_TIMEOUT = 12_500_000      // 100 ms
) (
    input  wire        clk50,
    input  wire        rst_n,
    output wire [3:0]  rgmii_txd,
    output wire        rgmii_tx_ctl,
    output wire        rgmii_txc,
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rx_ctl,
    input  wire        rgmii_rxc,
    // Order submission (toggle handshake from the cart's clock domain; the
    // data must be stable when the toggle changes).
    input  wire        submit_toggle,
    input  wire [2:0]  submit_count,
    input  wire [31:0] submit_items,      // {qty, dish} per byte, item 0 in [7:0]
    output wire        order_pending,     // clk125: an order waits for the kitchen
    input  wire [3:0]  front_mode,        // asynchronous switch levels {SW4..SW1}
    // From the kitchen (rx_clk registers; consumers synchronise them).
    output reg  [15:0] sold_mask,
    output reg  [2:0]  ad_index,          // advert 1..4
    output reg  [10:0] kitchen_event,     // {front ticker line, order no} of the kitchen
    output reg         kitchen_seen,      // a kitchen status frame has arrived
    output wire        link_up,           // clk125
    // Ticker RAM write port (rx_clk).
    output wire        ticker_clk,
    output reg         ticker_we,
    output reg  [9:0]  ticker_addr,
    output reg  [27:0] ticker_data,
    output reg         card_we,           // weather card RAM, port B (ticker_clk)
    output reg  [2:0]  card_kind,         // weather of the card shown, 0 晴天 .. 5 雪天 (ticker_clk)
    output wire        led_rx,
    output wire        led_tx
);
    localparam [7:0] MAGIC = 8'hA7, ID_FRONT = 8'h46, ID_KITCHEN = 8'h4B;

    wire        clk125, tx_rst_n, rx_clk, rx_rst_n;
    reg         tx_start;
    wire        tx_busy;
    wire [10:0] tx_index;
    reg  [7:0]  tx_byte3;
    wire        rx_valid, rx_end, rx_good;
    wire [7:0]  rx_byte;
    wire [10:0] rx_index;
    eth_node #(.SRC_MAC(48'h02_46_52_4F_4E_54)) u_node (
        .clk50(clk50), .rst_n(rst_n),
        .rgmii_txd(rgmii_txd), .rgmii_tx_ctl(rgmii_tx_ctl), .rgmii_txc(rgmii_txc),
        .rgmii_rxd(rgmii_rxd), .rgmii_rx_ctl(rgmii_rx_ctl), .rgmii_rxc(rgmii_rxc),
        .clk125(clk125), .tx_rst_n(tx_rst_n), .tx_start(tx_start), .tx_length(11'd46),
        .tx_busy(tx_busy), .tx_index(tx_index), .tx_data(tx_byte3),
        .rx_clk(rx_clk), .rx_rst_n(rx_rst_n), .rx_valid(rx_valid), .rx_byte(rx_byte),
        .rx_index(rx_index), .rx_end(rx_end), .rx_good(rx_good));
    assign ticker_clk = rx_clk;

    // ================================================================ receive (rx_clk)
    reg        hdr_ok, is_status, is_chunk, is_card;
    reg [7:0]  sh_ack, sh_sold_hi, sh_sold_lo, sh_ad, sh_ver, sh_chunk_ver, sh_line, sh_no;
    reg [1:0]  sh_chunk;
    reg [23:0] word_acc;
    reg [7:0]  rx_ack, want_version, have_version;
    reg [3:0]  chunk_mask;
    reg [7:0]  sh_card_ver, want_card, have_card;
    reg [2:0]  sh_card_kind, want_kind;
    reg [3:0]  card_mask;
    reg        rx_toggle, rx_frame_toggle;
    wire [10:0] data_pos = rx_index - 11'd22;          // chunk data starts at payload byte 8
    always @(posedge rx_clk or negedge rx_rst_n) begin
        if (!rx_rst_n) begin
            hdr_ok <= 1'b0; is_status <= 1'b0; is_chunk <= 1'b0; is_card <= 1'b0;
            sh_card_ver <= 8'd0; want_card <= 8'd0; have_card <= 8'd0; card_mask <= 4'd0;
            sh_card_kind <= 3'd0; want_kind <= 3'd0; card_kind <= 3'd0;
            card_we <= 1'b0;
            sh_ack <= 8'd0; sh_sold_hi <= 8'd0; sh_sold_lo <= 8'd0; sh_ad <= 8'd0; sh_ver <= 8'd0;
            sh_chunk_ver <= 8'd0; sh_chunk <= 2'd0; word_acc <= 24'd0;
            rx_ack <= 8'd0; want_version <= 8'd0; have_version <= 8'd0; chunk_mask <= 4'd0;
            rx_toggle <= 1'b0; rx_frame_toggle <= 1'b0;
            sold_mask <= 16'd0; ad_index <= 3'd1;
            sh_line <= 8'd0; sh_no <= 8'd0; kitchen_event <= 11'd0; kitchen_seen <= 1'b0;
            ticker_we <= 1'b0; ticker_addr <= 10'd0; ticker_data <= 28'd0;
        end else begin
            ticker_we <= 1'b0;
            card_we <= 1'b0;
            if (rx_valid) begin
                case (rx_index)
                    11'd12: hdr_ok <= rx_byte == 8'h88;
                    11'd13: hdr_ok <= hdr_ok && rx_byte == 8'hB5;
                    11'd14: hdr_ok <= hdr_ok && rx_byte == MAGIC;
                    11'd15: hdr_ok <= hdr_ok && rx_byte == ID_KITCHEN;
                    11'd16: begin
                        is_status <= hdr_ok && rx_byte == 8'd2;
                        is_chunk <= hdr_ok && rx_byte == 8'd3;
                        is_card <= hdr_ok && rx_byte == 8'd4;
                    end
                    11'd18: begin sh_ack <= rx_byte; sh_chunk_ver <= rx_byte; end
                    11'd19: begin sh_sold_hi <= rx_byte; sh_chunk <= rx_byte[1:0]; end
                    11'd20: sh_sold_lo <= rx_byte;
                    11'd21: sh_ad <= rx_byte;
                    11'd22: sh_ver <= rx_byte;
                    11'd24: sh_line <= rx_byte;
                    11'd25: sh_no <= rx_byte;
                    11'd26: sh_card_ver <= rx_byte;
                    11'd27: sh_card_kind <= rx_byte[2:0];
                    default: ;
                endcase
                // Glyph words: four bytes, most significant first.
                if ((is_chunk || is_card) && rx_index >= 11'd22 && data_pos < 11'd1024) begin
                    if (data_pos[1:0] == 2'd3) begin
                        ticker_we <= is_chunk;
                        card_we <= is_card;
                        ticker_addr <= {sh_chunk, data_pos[9:2]};
                        ticker_data <= {word_acc[19:0], rx_byte};
                    end else begin
                        word_acc <= {word_acc[15:0], rx_byte};
                    end
                end
            end
            if (rx_end && rx_good) begin
                rx_frame_toggle <= ~rx_frame_toggle;
                if (is_status) begin
                    rx_ack <= sh_ack;
                    sold_mask <= {sh_sold_hi, sh_sold_lo};
                    if (sh_ad >= 8'd1 && sh_ad <= 8'd4) ad_index <= sh_ad[2:0];
                    kitchen_event <= {sh_line[2:0], sh_no};
                    kitchen_seen <= 1'b1;
                    if (sh_ver != want_version) begin
                        want_version <= sh_ver;
                        chunk_mask <= 4'd0;
                    end
                    if (sh_card_ver != want_card) begin
                        want_card <= sh_card_ver;
                        want_kind <= sh_card_kind;
                        card_mask <= 4'd0;
                    end
                    rx_toggle <= ~rx_toggle;
                end
                if (is_card && sh_chunk_ver == want_card) begin
                    card_mask <= card_mask | (4'd1 << sh_chunk);
                    if ((card_mask | (4'd1 << sh_chunk)) == 4'hF) begin
                        have_card <= want_card;
                        card_kind <= want_kind;
                    end
                end
                if (is_chunk && sh_chunk_ver == want_version) begin
                    chunk_mask <= chunk_mask | (4'd1 << sh_chunk);
                    if ((chunk_mask | (4'd1 << sh_chunk)) == 4'hF)
                        have_version <= want_version;
                end
            end
            if (rx_end) begin
                is_status <= 1'b0;
                is_chunk <= 1'b0;
                is_card <= 1'b0;
            end
        end
    end

    // ================================================================ link state (clk125)
    (* async_reg = "true" *) reg [2:0] rx_toggle_sync, rx_frame_sync, submit_sync;
    (* async_reg = "true" *) reg [7:0] have_s0, have_s1;
    (* async_reg = "true" *) reg [7:0] card_s0, card_s1;
    reg [7:0]  card_q;
    (* async_reg = "true" *) reg [3:0] mode_s0, mode_s1;
    reg [7:0]  kitchen_ack, have_q, order_seq;
    reg [3:0]  mode_q;
    reg        pending, up;
    reg [23:0] silence;
    reg [2:0]  order_cnt;
    reg [31:0] order_items;
    always @(posedge clk125 or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            rx_toggle_sync <= 3'd0; rx_frame_sync <= 3'd0; submit_sync <= 3'd0;
            have_s0 <= 8'd0; have_s1 <= 8'd0; mode_s0 <= 4'd0; mode_s1 <= 4'd0;
            card_s0 <= 8'd0; card_s1 <= 8'd0; card_q <= 8'd0;
            kitchen_ack <= 8'd0; have_q <= 8'd0; order_seq <= 8'd0; mode_q <= 4'd0;
            pending <= 1'b0; up <= 1'b0; silence <= LINK_TIMEOUT;
            order_cnt <= 3'd0; order_items <= 32'd0;
        end else begin
            rx_toggle_sync <= {rx_toggle_sync[1:0], rx_toggle};
            rx_frame_sync <= {rx_frame_sync[1:0], rx_frame_toggle};
            submit_sync <= {submit_sync[1:0], submit_toggle};
            have_s0 <= have_version; have_s1 <= have_s0;
            if (have_s0 == have_s1) have_q <= have_s1;
            card_s0 <= have_card; card_s1 <= card_s0;
            if (card_s0 == card_s1) card_q <= card_s1;
            mode_s0 <= front_mode; mode_s1 <= mode_s0;
            if (mode_s0 == mode_s1) mode_q <= mode_s1;
            if (rx_toggle_sync[2] != rx_toggle_sync[1]) begin
                kitchen_ack <= rx_ack;
                silence <= 24'd0;
                up <= 1'b1;
            end else if (silence != LINK_TIMEOUT) begin
                silence <= silence + 1'b1;
            end else begin
                up <= 1'b0;
            end
            // One order at a time; the cart refuses a new one while pending.
            if (submit_sync[2] != submit_sync[1] && !pending) begin
                order_seq <= (order_seq == 8'd255) ? 8'd1 : order_seq + 1'b1;
                order_cnt <= submit_count;
                order_items <= submit_items;
                pending <= 1'b1;
            end else if (pending && up && kitchen_ack == order_seq) begin
                pending <= 1'b0;
            end
        end
    end
    assign order_pending = pending;
    assign link_up = up;

    // ================================================================ transmit (clk125)
    reg [17:0] status_timer;
    reg [7:0]  tx_seq;
    always @(posedge clk125 or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            status_timer <= 18'd0; tx_seq <= 8'd0; tx_start <= 1'b0;
        end else begin
            tx_start <= 1'b0;
            if (status_timer == STATUS_PERIOD - 1) begin
                status_timer <= 18'd0;
                if (!tx_busy) begin
                    tx_start <= 1'b1;
                    tx_seq <= tx_seq + 1'b1;
                end
            end else begin
                status_timer <= status_timer + 1'b1;
            end
        end
    end
    reg [7:0] hdr1, byte_q1, byte_q2, byte_q3;
    always @* begin
        case (tx_index)
            11'd0:  hdr1 = MAGIC;
            11'd1:  hdr1 = ID_FRONT;
            11'd2:  hdr1 = 8'd1;
            11'd3:  hdr1 = tx_seq;
            11'd4:  hdr1 = order_seq;
            11'd5:  hdr1 = {7'd0, pending};
            11'd6:  hdr1 = {5'd0, order_cnt};
            11'd7:  hdr1 = order_items[7:0];
            11'd8:  hdr1 = order_items[15:8];
            11'd9:  hdr1 = order_items[23:16];
            11'd10: hdr1 = order_items[31:24];
            11'd11: hdr1 = have_q;
            11'd12: hdr1 = {4'd0, mode_q};
            11'd13: hdr1 = card_q;
            default: hdr1 = 8'd0;
        endcase
    end
    always @(posedge clk125 or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            byte_q1 <= 8'd0; byte_q2 <= 8'd0; byte_q3 <= 8'd0; tx_byte3 <= 8'd0;
        end else begin
            // Four clocks from tx_index to the byte (see eth_tx_mac).
            byte_q1 <= hdr1; byte_q2 <= byte_q1; byte_q3 <= byte_q2; tx_byte3 <= byte_q3;
        end
    end

    // Activity lights, about 30 ms per frame.
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
