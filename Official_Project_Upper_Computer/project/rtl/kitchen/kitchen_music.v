`timescale 1ns/1ps

// Background music of the kitchen console from the TF card. It runs in the
// 50 MHz board clock: SD card in SPI mode, a FAT32 scan for AUDIO.PCM in the
// root directory, then wav_stream_player streams the selected track (the
// same file and format as the front end, see tools/audio/build_music.py of
// the front-end project). Samples leave through the player's FIFO in the
// video clock. Without a card or file the music stays silent and the scan
// is retried every second.
module kitchen_music #(
    parameter integer CLK_HZ = 50_000_000
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire [2:0]         track_async,    // track 1..6 (another clock)
    input  wire               enable_async,   // play while the console is live
    output wire               sd_ncs,
    output wire               sd_dclk,
    output wire               sd_mosi,
    input  wire               sd_miso,
    // Sample side.
    input  wire               rd_clk,
    input  wire               rd_rst_n,
    input  wire               sample_tick,
    output wire signed [15:0] sample,
    output wire               sample_valid,
    output wire               file_found      // clk domain
);
    // ------------------------------------------------------------ inputs
    (* async_reg = "true" *) reg [2:0] music_track_sync0;
    (* async_reg = "true" *) reg [2:0] music_track_sync1;
    (* async_reg = "true" *) reg [1:0] music_enable_sync0;
    reg [2:0] track_request;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            music_track_sync0 <= 3'd0;
            music_track_sync1 <= 3'd0;
            music_enable_sync0 <= 2'b00;
            track_request <= 3'd0;
        end else begin
            music_track_sync0 <= track_async - 3'd1;
            music_track_sync1 <= music_track_sync0;
            if (music_track_sync0 == music_track_sync1)
                track_request <= music_track_sync1;
            music_enable_sync0 <= {music_enable_sync0[0], enable_async};
        end
    end
    wire enable = music_enable_sync0[1];

    // ------------------------------------------------------------ SD card
    wire        sd_init_done;
    wire        sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    wire [7:0]  sd_sec_read_data;
    wire        sd_sec_read_data_valid;
    wire        sd_sec_read_end;
    sd_card_top #(
        .SPI_LOW_SPEED_DIV  (248),           // 100 kHz while initialising
        .SPI_HIGH_SPEED_DIV (0)              // 12.5 MHz
    ) u_sd (
        .clk(clk), .rst(!rst_n),
        .SD_nCS(sd_ncs), .SD_DCLK(sd_dclk), .SD_MOSI(sd_mosi), .SD_MISO(sd_miso),
        .sd_init_done(sd_init_done),
        .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
        .sd_sec_read_data(sd_sec_read_data), .sd_sec_read_data_valid(sd_sec_read_data_valid),
        .sd_sec_read_end(sd_sec_read_end),
        .sd_sec_write(1'b0), .sd_sec_write_addr(32'd0), .sd_sec_write_data(8'd0),
        .sd_sec_write_data_req(), .sd_sec_write_end(), .debug_state());

    // One sector reader, owned by the scanner until AUDIO.PCM is found.
    reg         owner_player;
    wire        scan_sector_req, player_sector_req;
    wire [31:0] scan_sector_lba, player_sector_lba;
    wire        sector_busy, sector_valid, sector_done;
    wire [7:0]  sector_byte, sector_error;
    wire [8:0]  sector_byte_index;
    sd_sector_adapter #(.CLK_FREQ_HZ(CLK_HZ), .READ_TIMEOUT_MS(500)) u_sector (
        .clk(clk), .rst_n(rst_n),
        .sector_req(owner_player ? player_sector_req : scan_sector_req),
        .sector_lba(owner_player ? player_sector_lba : scan_sector_lba),
        .sector_busy(sector_busy), .sector_valid(sector_valid), .sector_byte(sector_byte),
        .sector_byte_index(sector_byte_index), .sector_done(sector_done), .sector_error(sector_error),
        .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
        .sd_sec_read_data_valid(sd_sec_read_data_valid), .sd_sec_read_data(sd_sec_read_data),
        .sd_sec_read_end(sd_sec_read_end));

    // ------------------------------------------------------------ FAT32 scan
    reg         scan_start;
    wire        scan_busy, scan_done;
    wire [7:0]  fs_error;
    wire [2:0]  spc_shift;
    wire [31:0] data_start_lba;
    wire        audio_valid;
    wire [31:0] audio_cluster, audio_size;
    fat32_volume_scanner u_scan (
        .clk(clk), .rst_n(rst_n), .scan_start(scan_start), .scan_busy(scan_busy),
        .scan_done(scan_done), .fs_error(fs_error),
        .partition_lba(), .sectors_per_cluster(), .sectors_per_cluster_shift(spc_shift),
        .fat_start_lba(), .data_start_lba(data_start_lba), .max_cluster(),
        .resource_valid(),
        .resource0_cluster(), .resource1_cluster(), .resource2_cluster(), .resource3_cluster(),
        .resource0_size(), .resource1_size(), .resource2_size(), .resource3_size(),
        .resource4_cluster(), .resource5_cluster(), .resource6_cluster(), .resource7_cluster(),
        .resource4_size(), .resource5_size(), .resource6_size(), .resource7_size(),
        .audio_valid(audio_valid), .audio_cluster(audio_cluster), .audio_size(audio_size),
        .ad_valid(),
        .ad0_cluster(), .ad1_cluster(), .ad2_cluster(), .ad3_cluster(),
        .ad0_size(), .ad1_size(), .ad2_size(), .ad3_size(),
        .sector_req(scan_sector_req), .sector_lba(scan_sector_lba),
        .sector_busy(sector_busy), .sector_valid(sector_valid), .sector_byte(sector_byte),
        .sector_byte_index(sector_byte_index), .sector_done(sector_done),
        .sector_error(sector_error));

    // Scan after the card is initialised; retry every second until the file
    // is found. The file is contiguous: LBA = data start + (cluster - 2) << shift.
    localparam [2:0] M_INIT = 3'd0, M_SCAN = 3'd1, M_SHIFT = 3'd2, M_ADD = 3'd3,
                     M_PLAY = 3'd4, M_RETRY = 3'd5;
    reg [2:0]  mstate;
    reg [31:0] retry_count;
    reg [31:0] file_offset;
    reg [31:0] file_lba;
    reg [31:0] file_sectors;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstate <= M_INIT;
            scan_start <= 1'b0;
            owner_player <= 1'b0;
            retry_count <= 32'd0;
            file_offset <= 32'd0;
            file_lba <= 32'd0;
            file_sectors <= 32'd0;
        end else begin
            scan_start <= 1'b0;
            case (mstate)
                M_INIT: if (sd_init_done && !scan_busy) begin
                    scan_start <= 1'b1;
                    mstate <= M_SCAN;
                end
                M_SCAN: if (scan_done) begin
                    if (audio_valid && audio_size >= 32'd1024 && audio_cluster >= 32'd2) begin
                        file_offset <= audio_cluster - 32'd2;
                        file_sectors <= (audio_size + 32'd511) >> 9;
                        mstate <= M_SHIFT;
                    end else begin
                        retry_count <= 32'd0;
                        mstate <= M_RETRY;
                    end
                end
                M_SHIFT: begin
                    file_offset <= file_offset << spc_shift;
                    mstate <= M_ADD;
                end
                M_ADD: begin
                    file_lba <= data_start_lba + file_offset;
                    mstate <= M_PLAY;
                end
                M_PLAY: owner_player <= 1'b1;
                M_RETRY: begin
                    if (retry_count >= CLK_HZ - 1)
                        mstate <= M_INIT;
                    else
                        retry_count <= retry_count + 1'b1;
                end
                default: mstate <= M_INIT;
            endcase
        end
    end
    assign file_found = owner_player;

    // ------------------------------------------------------------ player
    wire       play_enable;
    wire [2:0] active_track;
    wire [31:0] track_lba, track_sectors;
    audio_track_control u_track (
        .clk(clk), .rst(!rst_n), .audio_available(owner_player), .display_ready(enable),
        .requested_track(track_request), .file_start_lba(file_lba),
        .file_total_sectors(file_sectors), .play_enable(play_enable),
        .active_track(active_track), .track_start_lba(track_lba),
        .track_total_sectors(track_sectors));

    wav_stream_player #(.ADDR_WIDTH(11)) u_player (
        .wr_clk(clk), .wr_rst_n(rst_n), .play_enable(play_enable),
        .start_lba(track_lba), .total_sectors(track_sectors), .track(active_track),
        .sd_req(player_sector_req), .sd_lba(player_sector_lba), .sd_busy(sector_busy),
        .sd_valid(sector_valid), .sd_byte(sector_byte), .sd_byte_index(sector_byte_index),
        .sd_done(sector_done), .sd_error(sector_error),
        .rd_clk(rd_clk), .rd_rst_n(rd_rst_n), .sample_tick(sample_tick),
        .sample_out(sample), .sample_valid(sample_valid), .sample_ready(1'b1),
        .sample_counter(), .stream_active(), .stream_end(), .buffer_low());
endmodule
