`timescale 1ns/1ps

// Minimal gigabit Ethernet MAC for a point-to-point link between the two
// boards. Frames are standard Ethernet II frames with a private EtherType;
// no IP stack is needed because the boards talk to each other directly.
//
// Shared by the front-end (交互端) and kitchen (后厨端) projects: keep the
// copies in both repositories identical.

// CRC-32 (IEEE 802.3, reflected) over one byte.
module eth_crc32_byte (
    input  wire [31:0] crc_in,
    input  wire [7:0]  data,
    output wire [31:0] crc_out
);
    function [31:0] step;
        input [31:0] c;
        input [7:0]  d;
        integer i;
        reg [31:0] r;
        begin
            r = c;
            for (i = 0; i < 8; i = i + 1)
                r = (r[0] ^ d[i]) ? (r >> 1) ^ 32'hEDB88320 : (r >> 1);
            step = r;
        end
    endfunction
    assign crc_out = step(crc_in, data);
endmodule

// Transmitter. When idle, a pulse on `start` sends one frame:
//   preamble, SFD, destination, source, EtherType, `length` payload bytes
//   (padded to the 46-byte minimum), FCS, then at least 12 idle bytes.
// Payload bytes are fetched four clocks ahead: the MAC drives pay_index and
// expects the matching byte on pay_data four clocks later, so the client can
// use two address stages, a synchronous ROM and an output register.
module eth_tx_mac #(
    parameter [47:0] SRC_MAC = 48'h02_00_00_00_00_01,
    parameter [47:0] DST_MAC = 48'hFF_FF_FF_FF_FF_FF,
    parameter [15:0] ETHERTYPE = 16'h88B5
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [10:0] length,
    output wire        busy,
    output reg  [10:0] pay_index,
    input  wire [7:0]  pay_data,
    output reg  [7:0]  gmii_txd,
    output reg         gmii_tx_en
);
    localparam [2:0] S_IDLE = 3'd0, S_PRE = 3'd1, S_HDR = 3'd2, S_PAY = 3'd3,
                     S_FCS = 3'd4, S_IFG = 3'd5;
    reg [2:0]  state;
    reg [10:0] count;          // position inside the current section
    reg [10:0] pay_len;        // payload bytes including padding
    reg [10:0] data_len;       // bytes the client supplies
    reg [31:0] crc;
    wire [31:0] crc_next;
    reg [7:0]  out_byte;
    reg        out_crc;        // include out_byte in the CRC
    wire [111:0] header = {DST_MAC, SRC_MAC, ETHERTYPE};

    assign busy = state != S_IDLE;
    eth_crc32_byte u_crc (.crc_in(crc), .data(out_byte), .crc_out(crc_next));

    always @* begin
        out_byte = 8'h00;
        out_crc = 1'b0;
        case (state)
            S_PRE: out_byte = (count == 11'd7) ? 8'hD5 : 8'h55;
            S_HDR: begin out_byte = header[8'd111 - {count[3:0], 3'b000} -: 8]; out_crc = 1'b1; end
            S_PAY: begin out_byte = (count < data_len) ? pay_data : 8'h00; out_crc = 1'b1; end
            S_FCS: begin
                case (count[1:0])
                    2'd0: out_byte = ~crc[7:0];
                    2'd1: out_byte = ~crc[15:8];
                    2'd2: out_byte = ~crc[23:16];
                    default: out_byte = ~crc[31:24];
                endcase
            end
            default: ;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; count <= 11'd0; pay_len <= 11'd0; data_len <= 11'd0;
            crc <= 32'hFFFFFFFF; pay_index <= 11'd0; gmii_txd <= 8'd0; gmii_tx_en <= 1'b0;
        end else begin
            gmii_txd <= out_byte;
            gmii_tx_en <= state == S_PRE || state == S_HDR || state == S_PAY || state == S_FCS;
            if (out_crc)
                crc <= crc_next;
            count <= count + 1'b1;
            // The payload byte for position k is needed in S_PAY at count k;
            // its index is on pay_index four clocks earlier (index 0 is
            // driven while the header is at count 10).
            if (state == S_HDR && count == 11'd9)
                pay_index <= 11'd0;
            else
                pay_index <= pay_index + 1'b1;
            case (state)
                S_IDLE: begin
                    count <= 11'd0;
                    if (start) begin
                        state <= S_PRE;
                        data_len <= length;
                        pay_len <= (length < 11'd46) ? 11'd46 : length;
                        crc <= 32'hFFFFFFFF;
                    end
                end
                S_PRE: if (count == 11'd7) begin state <= S_HDR; count <= 11'd0; end
                S_HDR: if (count == 11'd13) begin state <= S_PAY; count <= 11'd0; end
                S_PAY: if (count == pay_len - 1'b1) begin state <= S_FCS; count <= 11'd0; end
                S_FCS: if (count == 11'd3) begin state <= S_IFG; count <= 11'd0; end
                S_IFG: if (count == 11'd15) state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

// Receiver. Bytes after the SFD stream out on rx_valid / rx_byte with their
// position rx_index (0 = first destination byte; the payload starts at 14).
// When the frame ends, rx_end pulses with rx_good set if the FCS matched,
// the frame was long enough and no error was flagged.
module eth_rx_mac (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  gmii_rxd,
    input  wire        gmii_rx_dv,
    input  wire        gmii_rx_er,
    output reg         rx_valid,
    output reg  [7:0]  rx_byte,
    output reg  [10:0] rx_index,
    output reg         rx_end,
    output reg         rx_good
);
    localparam [1:0] S_IDLE = 2'd0, S_PRE = 2'd1, S_DATA = 2'd2, S_DROP = 2'd3;
    reg [1:0]  state;
    reg [31:0] crc;
    wire [31:0] crc_next;
    reg        error_seen;
    reg [10:0] count;
    eth_crc32_byte u_crc (.crc_in(crc), .data(gmii_rxd), .crc_out(crc_next));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; crc <= 32'hFFFFFFFF; error_seen <= 1'b0; count <= 11'd0;
            rx_valid <= 1'b0; rx_byte <= 8'd0; rx_index <= 11'd0; rx_end <= 1'b0; rx_good <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            rx_end <= 1'b0;
            case (state)
                S_IDLE: if (gmii_rx_dv) begin
                    state <= (gmii_rxd == 8'hD5) ? S_DATA : S_PRE;
                    crc <= 32'hFFFFFFFF;
                    error_seen <= gmii_rx_er;
                    count <= 11'd0;
                end
                S_PRE: begin
                    if (!gmii_rx_dv)
                        state <= S_IDLE;
                    else if (gmii_rxd == 8'hD5)
                        state <= S_DATA;
                    else if (gmii_rxd != 8'h55)
                        state <= S_DROP;
                end
                S_DATA: begin
                    if (gmii_rx_dv) begin
                        rx_valid <= 1'b1;
                        rx_byte <= gmii_rxd;
                        rx_index <= count;
                        crc <= crc_next;
                        if (gmii_rx_er) error_seen <= 1'b1;
                        if (count != 11'h7FF) count <= count + 1'b1;
                        else error_seen <= 1'b1;
                    end else begin
                        rx_end <= 1'b1;
                        // CRC over data and FCS leaves the fixed residue.
                        rx_good <= !error_seen && crc == 32'hDEBB20E3 && count >= 11'd64;
                        state <= S_IDLE;
                    end
                end
                default: if (!gmii_rx_dv) state <= S_IDLE;      // S_DROP
            endcase
        end
    end
endmodule
