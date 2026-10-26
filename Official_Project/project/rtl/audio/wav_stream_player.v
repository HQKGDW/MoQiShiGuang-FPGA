`timescale 1ns/1ps

// Background music from the TF card into the HDMI audio chain. This module
// sits between the SD sector-read infrastructure and the PCM sample
// interface, using a dual-port BRAM circular buffer to absorb the rate
// mismatch between TF reads (byte bursts) and audio consumption (96 KB/s at
// 48 kHz 16-bit mono).
//
// AUDIO.PCM (tools/audio/build_music.py) holds several looping tracks:
//   sector 0   header: bytes 0-3 "MQAU", then from byte 16 eight bytes per
//              track: first sector (from the file start) and sector count,
//              both u32 little-endian
//   sector 1.. the tracks, raw 16-bit signed little-endian mono PCM
// On play_enable the player reads the header, takes the entry of `track`
// and streams that track, looping from its last sector straight back to its
// first one (seamless). A file without the header, or a track whose entry is
// empty, is played as one raw PCM track covering the whole file.
//
// The write side issues one sector read at a time (sd_req only while the
// buffer has room for a sector), pairs bytes into samples and writes the
// buffer. The read side consumes at the audio sample rate. Pointer crossing
// is in the vendor FIFO (gray-coded). Buffer underflow outputs silence with
// sample_valid still asserted, so the downstream HDMI chain never stalls.
module wav_stream_player #(
    parameter integer ADDR_WIDTH = 12,         // 4096 x 16-bit = 8 KB
    parameter integer SAMPLES_PER_SECTOR = 256 // 512 bytes / 2
) (
    // write side: SD clock domain
    input  wire        wr_clk,
    input  wire        wr_rst_n,
    input  wire        play_enable,        // level: stream active
    input  wire [31:0] start_lba,          // first sector of AUDIO.PCM (its header)
    input  wire [31:0] total_sectors,      // file length in sectors
    input  wire [2:0]  track,              // track index 0..7 (track number - 1)
    output wire        sd_req,             // request a sector read
    output reg  [31:0] sd_lba,
    input  wire        sd_busy,
    input  wire        sd_valid,           // one byte per valid pulse
    input  wire [7:0]  sd_byte,
    input  wire [8:0]  sd_byte_index,      // 0..511 within sector
    input  wire        sd_done,
    input  wire [7:0]  sd_error,

    // read side: audio chain clock
    input  wire        rd_clk,
    input  wire        rd_rst_n,
    input  wire        sample_tick,        // ~48 kHz pulse: consume one sample
    output reg  signed [15:0] sample_out,
    output reg         sample_valid,
    input  wire        sample_ready,       // from downstream (always 1 in our chain)

    // status (read side)
    output reg  [31:0] sample_counter,     // samples consumed (for OSD)
    output wire        stream_active,      // play_enable and PCM flowing
    output wire        stream_end,         // stopped by a read error, buffer drained
    output wire        buffer_low          // < 1 sector buffered
);
    wire [15:0] fifo_data_out;
    wire fifo_valid;
    wire fifo_full;
    wire fifo_empty;
    wire fifo_almost_full;
    wire fifo_almost_empty;
    wire [ADDR_WIDTH-1:0] fifo_write_level;
    wire [ADDR_WIDTH-1:0] fifo_read_level;
    wire fifo_write_enable;
    wire fifo_read_enable;
    wire fifo_reset;

    reg [2:0] wstate_sync1, wstate_sync2;
    reg stream_failed;
    reg stream_failed_sync1, stream_failed_sync2;
    reg stream_started;

    // ---------------- write side state machine ----------------
    localparam [2:0] WS_IDLE     = 3'd0;
    localparam [2:0] WS_REQ      = 3'd1;
    localparam [2:0] WS_FILL     = 3'd2;
    localparam [2:0] WS_HDR_REQ  = 3'd3;
    localparam [2:0] WS_END      = 3'd4;
    localparam [2:0] WS_HDR_FILL = 3'd5;
    localparam [31:0] MAGIC = {"U", "A", "Q", "M"};   // "MQAU", little-endian
    reg [2:0]  wstate;
    reg [31:0] cur_lba;
    reg [31:0] sectors_remaining;
    reg [31:0] track_lba;           // first sector of the track
    reg [31:0] track_sectors;
    reg [31:0] magic;
    reg [63:0] entry;               // {sector count, first sector} of `track`
    reg [7:0]  lo_byte;             // little-endian pair assembly
    reg        lo_pending;

    wire       header_room = !fifo_almost_full;
    wire       entry_byte = sd_byte_index[8:3] == {3'd0, track} + 6'd2;   // bytes 16 + 8 * track ..
    assign sd_req = (wstate == WS_HDR_REQ) || (wstate == WS_REQ && header_room);
    assign stream_active = play_enable && stream_started && !stream_failed_sync2;
    assign stream_end = (wstate == WS_END) && fifo_empty;
    assign buffer_low = fifo_almost_empty;
    assign fifo_reset = !wr_rst_n || !rd_rst_n || !play_enable;
    assign fifo_write_enable = wstate == WS_FILL && sd_valid && lo_pending && !fifo_full;
    assign fifo_read_enable = sample_tick && sample_ready &&
                              ((fifo_read_level >= SAMPLES_PER_SECTOR) ||
                               (wstate_sync2 == WS_END && !fifo_empty));

    afifo_32_16_256 #(
        .DATA_WIDTH_W  (16),
        .DATA_WIDTH_R  (16),
        .ADDR_WIDTH_W  (ADDR_WIDTH),
        .ADDR_WIDTH_R  (ADDR_WIDTH),
        .AL_FULL_NUM   ((1 << ADDR_WIDTH) - SAMPLES_PER_SECTOR),
        .AL_EMPTY_NUM  (SAMPLES_PER_SECTOR)
    ) u_audio_fifo (
        .rst        (fifo_reset),
        .clkw       (wr_clk),
        .clkr       (rd_clk),
        .we         (fifo_write_enable),
        .di         ({sd_byte, lo_byte}),
        .re         (fifo_read_enable),
        .dout       (fifo_data_out),
        .valid      (fifo_valid),
        .full_flag  (fifo_full),
        .empty_flag (fifo_empty),
        .afull      (fifo_almost_full),
        .aempty     (fifo_almost_empty),
        .wrusedw    (fifo_write_level),
        .rdusedw    (fifo_read_level)
    );

    // Registered every clock; the inputs settle long before sd_done.
    reg        entry_ok_q, last_sector_q;
    reg [31:0] entry_lba_q, next_lba_q;
    always @(posedge wr_clk) begin
        entry_ok_q <= magic == MAGIC && entry[63:32] != 32'd0 &&
                      entry[31:0] != 32'd0 && entry[31:0] < total_sectors;
        entry_lba_q <= start_lba + entry[31:0];
        last_sector_q <= sectors_remaining <= 32'd1;
        next_lba_q <= cur_lba + 1'b1;
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wstate            <= WS_IDLE;
            cur_lba           <= 32'd0;
            sd_lba            <= 32'd0;
            sectors_remaining <= 32'd0;
            track_lba         <= 32'd0;
            track_sectors     <= 32'd0;
            magic             <= 32'd0;
            entry             <= 64'd0;
            lo_pending        <= 1'b0;
            lo_byte           <= 8'd0;
            stream_failed     <= 1'b0;
        end else if (!play_enable) begin
            wstate            <= WS_IDLE;
            sectors_remaining <= 32'd0;
            lo_pending        <= 1'b0;
            stream_failed     <= 1'b0;
        end else begin
            case (wstate)
            WS_IDLE: begin
                if (start_lba != 32'd0 && total_sectors != 32'd0) begin
                    sd_lba <= start_lba;
                    magic  <= 32'd0;
                    entry  <= 64'd0;
                    wstate <= WS_HDR_REQ;
                end
            end
            WS_HDR_REQ: begin
                if (!sd_busy)
                    wstate <= WS_HDR_FILL;
            end
            WS_HDR_FILL: begin
                if (sd_valid) begin
                    if (sd_byte_index[8:2] == 7'd0)
                        magic <= {sd_byte, magic[31:8]};
                    if (entry_byte)
                        entry <= {sd_byte, entry[63:8]};
                end
                if (sd_done) begin
                    if (sd_error != 8'd0) begin
                        stream_failed <= 1'b1;
                        wstate <= WS_END;
                    end else begin
                        // A valid entry selects the track, else the whole file.
                        if (entry_ok_q) begin
                            track_lba     <= entry_lba_q;
                            track_sectors <= entry[63:32];
                            cur_lba       <= entry_lba_q;
                            sd_lba        <= entry_lba_q;
                            sectors_remaining <= entry[63:32];
                        end else begin
                            track_lba     <= start_lba;
                            track_sectors <= total_sectors;
                            cur_lba       <= start_lba;
                            sd_lba        <= start_lba;
                            sectors_remaining <= total_sectors;
                        end
                        lo_pending <= 1'b0;
                        wstate <= WS_REQ;
                    end
                end
            end
            WS_REQ: begin
                if (!sd_busy && header_room) begin
                    sd_lba  <= cur_lba;
                    wstate  <= WS_FILL;
                end
            end
            WS_FILL: begin
                if (sd_valid) begin
                    if (!lo_pending) begin
                        lo_byte    <= sd_byte;
                        lo_pending <= 1'b1;
                    end else begin
                        lo_pending <= 1'b0;
                    end
                end
                if (sd_done) begin
                    if (sd_error != 8'd0) begin
                        stream_failed <= 1'b1;
                        wstate <= WS_END;  // sector error: stop streaming
                    end else begin
                        // After the last sector go straight back to the first.
                        if (last_sector_q) begin
                            cur_lba <= track_lba;
                            sd_lba <= track_lba;
                            sectors_remaining <= track_sectors;
                        end else begin
                            cur_lba <= next_lba_q;
                            sd_lba <= next_lba_q;
                            sectors_remaining <= sectors_remaining - 1'b1;
                        end
                        wstate <= WS_REQ;
                    end
                end
            end
            WS_END: ;                  // stays here until play_enable drops
            default: wstate <= WS_IDLE;
            endcase
        end
    end

    // ---------------- read side ----------------
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            sample_out     <= 16'sd0;
            sample_valid   <= 1'b0;
            sample_counter <= 32'd0;
            wstate_sync1   <= 3'd0;
            wstate_sync2   <= 3'd0;
            stream_failed_sync1 <= 1'b0;
            stream_failed_sync2 <= 1'b0;
            stream_started <= 1'b0;
        end else begin
            wstate_sync1 <= wstate;
            wstate_sync2 <= wstate_sync1;
            stream_failed_sync1 <= stream_failed;
            stream_failed_sync2 <= stream_failed_sync1;

            sample_valid <= 1'b0;

            if (sample_tick && sample_ready && !fifo_read_enable) begin
                sample_out   <= 16'sd0;
                sample_valid <= 1'b1;
            end

            if (fifo_valid) begin
                sample_out <= fifo_data_out;
                sample_valid <= 1'b1;
                sample_counter <= sample_counter + 1'b1;
                stream_started <= 1'b1;
            end

            if (!play_enable) begin
                sample_counter <= 32'd0;
                stream_started <= 1'b0;
            end
        end
    end
endmodule
