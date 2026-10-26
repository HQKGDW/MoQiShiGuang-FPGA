`timescale 1ns/1ps

module fat32_bmp_reader #(
    parameter integer CLK_FREQ_HZ        = 100_000_000,
    parameter integer SD_READ_TIMEOUT_MS = 500,
    parameter integer EXPECTED_PIXELS    = 921_600,
    parameter integer ASSET_WIDTH        = 400,
    parameter integer ASSET_HEIGHT       = 1184,
    parameter [2:0]   ASSET_RESOURCE     = 3'd4
)(
    input                       clk,
    input                       rst,
    output                      ready,
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [3:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [3:0]            scan_found_total,
    input                       load_start,
    input                       load_abort,
    input  [31:0]               load_sector,
    output reg                  load_done,
    output reg                  load_error,
    output reg [2:0]            bmp_error,
    output reg [6:0]            load_progress,
    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  write_req,
    input                       write_req_ack,
    output                      sd_sec_read,
    output [31:0]               sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,
    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data,
    // Advert posters: which files exist, and the geometry of the poster being
    // loaded (valid from ad_stream_start, a pulse just before its pixels).
    output wire [3:0]           ad_found,
    output wire [10:0]          ad_width,
    output wire [10:0]          ad_height,
    output reg                  ad_stream_start,
    input                       ad_source_go,     // scaler ready for the poster's pixels
    output reg                  audio_available,
    output reg [31:0]           audio_start_lba,
    output reg [31:0]           audio_total_sectors,
    input  wire                 audio_start,
    output wire                 audio_byte_valid,
    output wire [7:0]           audio_byte,
    output wire                 audio_done,
    output wire [7:0]           audio_error
);

localparam [2:0] ERR_NONE      = 3'd0;
localparam [2:0] ERR_HEADER    = 3'd1;
localparam [2:0] ERR_TIMEOUT   = 3'd2;
localparam [2:0] ERR_TRUNCATED = 3'd3;
localparam [2:0] ERR_FAT       = 3'd4;

localparam [3:0] ST_IDLE       = 4'd0;
localparam [3:0] ST_SCAN       = 4'd1;
localparam [3:0] ST_SCAN_EMIT  = 4'd2;
localparam [3:0] ST_HEADER_REQ = 4'd3;
localparam [3:0] ST_HEADER     = 4'd4;
localparam [3:0] ST_WRITE_WAIT = 4'd5;
localparam [3:0] ST_FILE_START = 4'd6;
localparam [3:0] ST_FILE       = 4'd7;
localparam [3:0] ST_HEADER_DELTA = 4'd8;
localparam [3:0] ST_HEADER_SHIFT = 4'd9;
localparam [3:0] ST_AUDIO       = 4'd10;
localparam [3:0] ST_HEADER_VALIDATE = 4'd11;
localparam [3:0] ST_AD_GEOM0    = 4'd12;
localparam [3:0] ST_AD_GEOM1    = 4'd13;

localparam [1:0] OWNER_SCAN   = 2'd0;
localparam [1:0] OWNER_HEADER = 2'd1;
localparam [1:0] OWNER_FILE   = 2'd2;
localparam [1:0] OWNER_AUDIO  = 2'd3;

localparam [31:0] EXPECTED_DATA_BYTES = EXPECTED_PIXELS * 3;
localparam [31:0] ASSET_PIXELS        = ASSET_WIDTH * ASSET_HEIGHT;
localparam [31:0] ASSET_DATA_BYTES    = ASSET_PIXELS * 3;

reg [3:0] state;
reg [1:0] owner;
reg scanner_start;
reg streamer_start;
reg header_sector_req;
reg [31:0] header_sector_lba;
reg [3:0] emit_index;
reg [2:0] emit_count;
reg [31:0] selected_cluster;
reg [31:0] selected_file_size;
reg [31:0] selected_cluster_delta;
reg [31:0] selected_sector_offset;
reg [1:0] pixel_byte_index;
reg [31:0] pixel_count;
reg [13:0] progress_pixel_count;
reg [31:0] expected_pixels;
reg [31:0] expected_data_bytes;
reg [31:0] expected_width;
reg [31:0] expected_height;
reg [31:0] selected_pixel_limit;
reg        selected_size_valid;
reg        header_invalid;

reg        load_is_ad;
reg        ad_geometry_known;     // second header pass of an advert
reg        ad_range_ok;
reg [20:0] ad_pixels;
wire [3:0] ad_valid;
wire [31:0] ad0_cluster, ad1_cluster, ad2_cluster, ad3_cluster;
wire [31:0] ad0_size, ad1_size, ad2_size, ad3_size;
reg [15:0] header_signature;
reg [31:0] header_file_size;
reg [31:0] header_pixel_offset;
reg [31:0] header_dib_size;
reg [31:0] header_width;
reg [31:0] header_height;
reg [15:0] header_planes;
reg [15:0] header_bit_count;
reg [31:0] header_compression;

reg subsystem_rst_n;
reg volume_rst_n;
// write_req_ack comes from the SDRAM (ext_mem_clk) domain. Sampling it raw
// let one edge reach state and owner on different clocks: state moved to
// ST_FILE_START while owner stayed OWNER_HEADER, so the file streamer saw a
// permanently busy sector port and the load stalled with the SD bus idle.
(* async_reg = "true" *) reg write_req_ack_sync0;
(* async_reg = "true" *) reg write_req_ack_sync1;
wire scanner_busy;
wire scanner_done;
wire [7:0] scanner_error;
wire [7:0] sectors_per_cluster;
wire [2:0] sectors_per_cluster_shift;
wire [31:0] fat_start_lba;
wire [31:0] data_start_lba;
wire [31:0] max_cluster;
wire [7:0] resource_valid;
wire [31:0] resource0_cluster;
wire [31:0] resource1_cluster;
wire [31:0] resource2_cluster;
wire [31:0] resource3_cluster;
wire [31:0] resource0_size;
wire [31:0] resource1_size;
wire [31:0] resource2_size;
wire [31:0] resource3_size;
wire [31:0] resource4_cluster;
wire [31:0] resource5_cluster;
wire [31:0] resource6_cluster;
wire [31:0] resource7_cluster;
wire [31:0] resource4_size;
wire [31:0] resource5_size;
wire [31:0] resource6_size;
wire [31:0] resource7_size;
wire audio_file_valid;
wire [31:0] audio_file_cluster;
wire [31:0] audio_file_size;
wire scanner_sector_req;
wire [31:0] scanner_sector_lba;
wire scanner_sector_busy;
wire scanner_sector_valid;
wire [7:0] scanner_sector_byte;
wire [8:0] scanner_sector_byte_index;
wire scanner_sector_done;
wire [7:0] scanner_sector_error;

wire streamer_busy;
wire streamer_done;
wire streamer_valid;
wire [7:0] streamer_byte;
wire [31:0] streamer_byte_offset;
wire [7:0] streamer_error;
wire streamer_sector_req;
wire [31:0] streamer_sector_lba;
wire streamer_sector_busy;
wire streamer_sector_valid;
wire [7:0] streamer_sector_byte;
wire [8:0] streamer_sector_byte_index;
wire streamer_sector_done;
wire [7:0] streamer_sector_error;

reg arb_sector_req;
reg [31:0] arb_sector_lba;
wire adapter_busy;
wire adapter_valid;
wire [7:0] adapter_byte;
wire [8:0] adapter_byte_index;
wire adapter_done;
wire [7:0] adapter_error;
reg adapter_valid_q;
reg [7:0] adapter_byte_q;
reg [8:0] adapter_byte_index_q;
reg adapter_done_q;
reg [7:0] adapter_error_q;

reg [31:0] pixel_data_end;
reg        file_q_valid;          // streamer output, one clock later
reg [7:0]  file_q_byte;
reg        file_q_pixel;          // the byte lies in the pixel array
reg        file_q_done;
reg [7:0]  file_q_error;
wire unused_scan_limits;
reg [31:0] audio_cluster_delta;
reg [31:0] audio_sector_offset;
reg [2:0] audio_address_valid;

// load_abort only cancels the file being streamed. The scanned resource
// table, FAT32 geometry and AUDIO.PCM extent stay valid until the card is
// re-initialised; clearing them on abort made every later load fail with a
// FAT error, so one stalled or key-cancelled load poisoned the whole session.
always @(posedge clk or posedge rst) begin
    if (rst)
        subsystem_rst_n <= 1'b0;
    else if (!sd_init_done || load_abort)
        subsystem_rst_n <= 1'b0;
    else
        subsystem_rst_n <= 1'b1;
end

always @(posedge clk or posedge rst) begin
    if (rst)
        volume_rst_n <= 1'b0;
    else
        volume_rst_n <= sd_init_done;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        write_req_ack_sync0 <= 1'b0;
        write_req_ack_sync1 <= 1'b0;
    end else begin
        write_req_ack_sync0 <= write_req_ack;
        write_req_ack_sync1 <= write_req_ack_sync0;
    end
end
assign ready = (state == ST_IDLE) && !adapter_busy && !scanner_busy && !streamer_busy;
assign audio_byte_valid = (state == ST_AUDIO) && streamer_valid;
assign audio_byte = streamer_byte;
assign audio_done = (state == ST_AUDIO) && streamer_done;
assign audio_error = (state == ST_AUDIO) ? streamer_error : 8'd0;
assign unused_scan_limits = scan_start_sector[0] ^ scan_max_sector[0] ^ scanner_error[0];
assign ad_found = ad_valid;
assign ad_width = expected_width[10:0];
assign ad_height = expected_height[10:0];

assign scanner_sector_busy = adapter_busy;
assign scanner_sector_valid = adapter_valid_q;
assign scanner_sector_byte = adapter_byte_q;
assign scanner_sector_byte_index = adapter_byte_index_q;
assign scanner_sector_done = adapter_done_q;
assign scanner_sector_error = adapter_error_q;

assign streamer_sector_busy = ((owner == OWNER_FILE) || (owner == OWNER_AUDIO)) ? adapter_busy : 1'b1;
assign streamer_sector_valid = ((owner == OWNER_FILE) || (owner == OWNER_AUDIO)) && adapter_valid;
assign streamer_sector_byte = adapter_byte;
assign streamer_sector_byte_index = adapter_byte_index;
assign streamer_sector_done = ((owner == OWNER_FILE) || (owner == OWNER_AUDIO)) && adapter_done;
assign streamer_sector_error = ((owner == OWNER_FILE) || (owner == OWNER_AUDIO)) ? adapter_error : 8'd0;

always @(posedge clk or negedge volume_rst_n) begin
    if (!volume_rst_n) begin
        audio_available <= 1'b0;
        audio_start_lba <= 32'd0;
        audio_total_sectors <= 32'd0;
        audio_cluster_delta <= 32'd0;
        audio_sector_offset <= 32'd0;
        audio_address_valid <= 3'b000;
    end else begin
        audio_address_valid <= {audio_address_valid[1:0],
                                audio_file_valid && (audio_file_size != 0)};
        if (audio_file_valid && audio_file_size != 0) begin
            audio_cluster_delta <= audio_file_cluster - 32'd2;
            audio_total_sectors <= (audio_file_size + 32'd511) >> 9;
        end
        if (audio_address_valid[0])
            audio_sector_offset <= audio_cluster_delta << sectors_per_cluster_shift;
        if (audio_address_valid[1])
            audio_start_lba <= data_start_lba + audio_sector_offset;
        if (audio_address_valid[2])
            audio_available <= 1'b1;
    end
end

always @(*) begin
    arb_sector_req = 1'b0;
    arb_sector_lba = 32'd0;
    case (owner)
        OWNER_SCAN: begin
            arb_sector_req = scanner_sector_req;
            arb_sector_lba = scanner_sector_lba;
        end
        OWNER_HEADER: begin
            arb_sector_req = header_sector_req;
            arb_sector_lba = header_sector_lba;
        end
        OWNER_AUDIO: begin
            arb_sector_req = streamer_sector_req;
            arb_sector_lba = streamer_sector_lba;
        end
        default: begin
            arb_sector_req = streamer_sector_req;
            arb_sector_lba = streamer_sector_lba;
        end
    endcase
end

function [31:0] cluster_lut;
    input [2:0] index;
    begin
        case (index)
            3'd0: cluster_lut = resource0_cluster;
            3'd1: cluster_lut = resource1_cluster;
            3'd2: cluster_lut = resource2_cluster;
            3'd3: cluster_lut = resource3_cluster;
            3'd4: cluster_lut = resource4_cluster;
            3'd5: cluster_lut = resource5_cluster;
            3'd6: cluster_lut = resource6_cluster;
            default: cluster_lut = resource7_cluster;
        endcase
    end
endfunction

function [31:0] size_lut;
    input [2:0] index;
    begin
        case (index)
            3'd0: size_lut = resource0_size;
            3'd1: size_lut = resource1_size;
            3'd2: size_lut = resource2_size;
            3'd3: size_lut = resource3_size;
            3'd4: size_lut = resource4_size;
            3'd5: size_lut = resource5_size;
            3'd6: size_lut = resource6_size;
            default: size_lut = resource7_size;
        endcase
    end
endfunction

fat32_volume_scanner u_volume_scanner (
    .clk(clk),
    .rst_n(volume_rst_n),
    .scan_start(scanner_start),
    .scan_busy(scanner_busy),
    .scan_done(scanner_done),
    .fs_error(scanner_error),
    .partition_lba(),
    .sectors_per_cluster(sectors_per_cluster),
    .sectors_per_cluster_shift(sectors_per_cluster_shift),
    .fat_start_lba(fat_start_lba),
    .data_start_lba(data_start_lba),
    .max_cluster(max_cluster),
    .resource_valid(resource_valid),
    .resource0_cluster(resource0_cluster),
    .resource1_cluster(resource1_cluster),
    .resource2_cluster(resource2_cluster),
    .resource3_cluster(resource3_cluster),
    .resource0_size(resource0_size),
    .resource1_size(resource1_size),
    .resource2_size(resource2_size),
    .resource3_size(resource3_size),
    .resource4_cluster(resource4_cluster),
    .resource5_cluster(resource5_cluster),
    .resource6_cluster(resource6_cluster),
    .resource7_cluster(resource7_cluster),
    .resource4_size(resource4_size),
    .resource5_size(resource5_size),
    .resource6_size(resource6_size),
    .resource7_size(resource7_size),
    .audio_valid(audio_file_valid),
    .audio_cluster(audio_file_cluster),
    .audio_size(audio_file_size),
    .ad_valid(ad_valid),
    .ad0_cluster(ad0_cluster),
    .ad1_cluster(ad1_cluster),
    .ad2_cluster(ad2_cluster),
    .ad3_cluster(ad3_cluster),
    .ad0_size(ad0_size),
    .ad1_size(ad1_size),
    .ad2_size(ad2_size),
    .ad3_size(ad3_size),
    .sector_req(scanner_sector_req),
    .sector_lba(scanner_sector_lba),
    .sector_busy(scanner_sector_busy),
    .sector_valid(scanner_sector_valid),
    .sector_byte(scanner_sector_byte),
    .sector_byte_index(scanner_sector_byte_index),
    .sector_done(scanner_sector_done),
    .sector_error(scanner_sector_error)
);

fat32_file_streamer u_file_streamer (
    .clk(clk),
    .rst_n(subsystem_rst_n),
    .file_start(streamer_start),
    .first_cluster(selected_cluster),
    .file_size(selected_file_size),
    .sectors_per_cluster(sectors_per_cluster),
    .sectors_per_cluster_shift(sectors_per_cluster_shift),
    .fat_start_lba(fat_start_lba),
    .data_start_lba(data_start_lba),
    .max_cluster(max_cluster),
    .file_busy(streamer_busy),
    .file_done(streamer_done),
    .file_valid(streamer_valid),
    .file_byte(streamer_byte),
    .file_byte_offset(streamer_byte_offset),
    .fs_error(streamer_error),
    .sector_req(streamer_sector_req),
    .sector_lba(streamer_sector_lba),
    .sector_busy(streamer_sector_busy),
    .sector_valid(streamer_sector_valid),
    .sector_byte(streamer_sector_byte),
    .sector_byte_index(streamer_sector_byte_index),
    .sector_done(streamer_sector_done),
    .sector_error(streamer_sector_error)
);

sd_sector_adapter #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .READ_TIMEOUT_MS(SD_READ_TIMEOUT_MS)
) u_sector_adapter (
    .clk(clk),
    .rst_n(subsystem_rst_n),
    .sector_req(arb_sector_req),
    .sector_lba(arb_sector_lba),
    .sector_busy(adapter_busy),
    .sector_valid(adapter_valid),
    .sector_byte(adapter_byte),
    .sector_byte_index(adapter_byte_index),
    .sector_done(adapter_done),
    .sector_error(adapter_error),
    .sd_sec_read(sd_sec_read),
    .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_end(sd_sec_read_end)
);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= ST_IDLE;
        owner <= OWNER_SCAN;
        scanner_start <= 1'b0;
        streamer_start <= 1'b0;
        header_sector_req <= 1'b0;
        header_sector_lba <= 32'd0;
        emit_index <= 3'd0;
        emit_count <= 3'd0;
        scan_done <= 1'b0;
        scan_found_valid <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total <= 4'd0;
        selected_cluster <= 32'd0;
        selected_file_size <= 32'd0;
        selected_cluster_delta <= 32'd0;
        selected_sector_offset <= 32'd0;
        expected_pixels <= EXPECTED_PIXELS;
        expected_data_bytes <= EXPECTED_DATA_BYTES;
        expected_width <= {16'd0, bmp_width};
        expected_height <= {16'd0, bmp_height};
        selected_pixel_limit <= 32'd0;
        selected_size_valid <= 1'b0;
        header_invalid <= 1'b0;
        load_done <= 1'b0;
        load_error <= 1'b0;
        bmp_error <= ERR_NONE;
        state_code <= 4'd1;
        write_req <= 1'b0;
        bmp_data_wr_en <= 1'b0;
        bmp_data <= 24'd0;
        pixel_byte_index <= 2'd0;
        pixel_count <= 32'd0;
        progress_pixel_count <= 14'd0;
        load_progress <= 7'd0;
        header_signature <= 16'd0;
        header_file_size <= 32'd0;
        header_pixel_offset <= 32'd0;
        pixel_data_end <= 32'd0;
        file_q_valid <= 1'b0;
        file_q_byte <= 8'd0;
        file_q_pixel <= 1'b0;
        file_q_done <= 1'b0;
        file_q_error <= 8'd0;
        load_is_ad <= 1'b0;
        ad_geometry_known <= 1'b0;
        ad_range_ok <= 1'b0;
        ad_pixels <= 21'd0;
        ad_stream_start <= 1'b0;
        header_dib_size <= 32'd0;
        header_width <= 32'd0;
        header_height <= 32'd0;
        header_planes <= 16'd0;
        header_bit_count <= 16'd0;
        header_compression <= 32'd0;
        adapter_valid_q <= 1'b0;
        adapter_byte_q <= 8'd0;
        adapter_byte_index_q <= 9'd0;
        adapter_done_q <= 1'b0;
        adapter_error_q <= 8'd0;
    end else if (!sd_init_done || load_abort) begin
        state <= ST_IDLE;
        owner <= OWNER_SCAN;
        scanner_start <= 1'b0;
        streamer_start <= 1'b0;
        header_sector_req <= 1'b0;
        emit_index <= 3'd0;
        emit_count <= 3'd0;
        scan_done <= 1'b0;
        scan_found_valid <= 1'b0;
        scan_found_total <= 4'd0;
        load_done <= 1'b0;
        load_error <= 1'b0;
        bmp_error <= ERR_NONE;
        state_code <= 4'd1;
        write_req <= 1'b0;
        bmp_data_wr_en <= 1'b0;
        pixel_byte_index <= 2'd0;
        pixel_count <= 32'd0;
        progress_pixel_count <= 14'd0;
        load_progress <= 7'd0;
        pixel_data_end <= 32'd0;
        selected_pixel_limit <= 32'd0;
        selected_size_valid <= 1'b0;
        header_invalid <= 1'b0;
        file_q_valid <= 1'b0;
        file_q_done <= 1'b0;
        load_is_ad <= 1'b0;
        ad_geometry_known <= 1'b0;
        ad_stream_start <= 1'b0;
        adapter_valid_q <= 1'b0;
        adapter_byte_q <= 8'd0;
        adapter_byte_index_q <= 9'd0;
        adapter_done_q <= 1'b0;
        adapter_error_q <= 8'd0;
    end else begin
        adapter_valid_q <= adapter_valid;
        adapter_byte_q <= adapter_byte;
        adapter_byte_index_q <= adapter_byte_index;
        adapter_done_q <= adapter_done;
        adapter_error_q <= adapter_error;
        scanner_start <= 1'b0;
        streamer_start <= 1'b0;
        header_sector_req <= 1'b0;
        scan_done <= 1'b0;
        scan_found_valid <= 1'b0;
        load_done <= 1'b0;
        load_error <= 1'b0;
        bmp_data_wr_en <= 1'b0;
        ad_stream_start <= 1'b0;

        if (state == ST_HEADER && adapter_valid_q) begin
            case (adapter_byte_index_q)
                9'd0:  header_signature[7:0] <= adapter_byte_q;
                9'd1:  header_signature[15:8] <= adapter_byte_q;
                9'd2:  header_file_size[7:0] <= adapter_byte_q;
                9'd3:  header_file_size[15:8] <= adapter_byte_q;
                9'd4:  header_file_size[23:16] <= adapter_byte_q;
                9'd5:  header_file_size[31:24] <= adapter_byte_q;
                9'd10: header_pixel_offset[7:0] <= adapter_byte_q;
                9'd11: header_pixel_offset[15:8] <= adapter_byte_q;
                9'd12: header_pixel_offset[23:16] <= adapter_byte_q;
                9'd13: begin
                    header_pixel_offset[31:24] <= adapter_byte_q;
                    pixel_data_end <= {adapter_byte_q, header_pixel_offset[23:0]} +
                                      expected_data_bytes;
                end
                9'd14: header_dib_size[7:0] <= adapter_byte_q;
                9'd15: header_dib_size[15:8] <= adapter_byte_q;
                9'd16: header_dib_size[23:16] <= adapter_byte_q;
                9'd17: header_dib_size[31:24] <= adapter_byte_q;
                9'd18: header_width[7:0] <= adapter_byte_q;
                9'd19: header_width[15:8] <= adapter_byte_q;
                9'd20: header_width[23:16] <= adapter_byte_q;
                9'd21: header_width[31:24] <= adapter_byte_q;
                9'd22: header_height[7:0] <= adapter_byte_q;
                9'd23: header_height[15:8] <= adapter_byte_q;
                9'd24: header_height[23:16] <= adapter_byte_q;
                9'd25: header_height[31:24] <= adapter_byte_q;
                9'd26: header_planes[7:0] <= adapter_byte_q;
                9'd27: header_planes[15:8] <= adapter_byte_q;
                9'd28: header_bit_count[7:0] <= adapter_byte_q;
                9'd29: header_bit_count[15:8] <= adapter_byte_q;
                9'd30: header_compression[7:0] <= adapter_byte_q;
                9'd31: header_compression[15:8] <= adapter_byte_q;
                9'd32: header_compression[23:16] <= adapter_byte_q;
                9'd33: header_compression[31:24] <= adapter_byte_q;
                default: begin end
            endcase
        end

        file_q_valid <= state == ST_FILE && streamer_valid;
        file_q_byte <= streamer_byte;
        file_q_pixel <= streamer_byte_offset >= header_pixel_offset &&
                        streamer_byte_offset < pixel_data_end;
        file_q_done <= state == ST_FILE && streamer_done;
        file_q_error <= streamer_error;

        if (state == ST_FILE && file_q_valid && file_q_pixel) begin
            case (pixel_byte_index)
                2'd0: begin
                    bmp_data[7:0] <= file_q_byte;
                    pixel_byte_index <= 2'd1;
                end
                2'd1: begin
                    bmp_data[15:8] <= file_q_byte;
                    pixel_byte_index <= 2'd2;
                end
                default: begin
                    bmp_data[23:16] <= file_q_byte;
                    bmp_data_wr_en <= 1'b1;
                    pixel_byte_index <= 2'd0;
                    pixel_count <= pixel_count + 1'b1;
                    if (progress_pixel_count == 14'd14_399) begin
                        progress_pixel_count <= 14'd0;
                        if (load_progress < 7'd64)
                            load_progress <= load_progress + 1'b1;
                    end else begin
                        progress_pixel_count <= progress_pixel_count + 1'b1;
                    end
                end
            endcase
        end

        case (state)
            ST_IDLE: begin
                state_code <= 4'd1;
                write_req <= 1'b0;
                if (scan_start) begin
                    owner <= OWNER_SCAN;
                    scanner_start <= 1'b1;
                    scan_found_total <= 4'd0;
                    emit_index <= 3'd0;
                    emit_count <= 3'd0;
                    state <= ST_SCAN;
                end else if (load_start) begin
                    load_is_ad <= load_sector[31:4] == 0 && load_sector[3];
                    ad_geometry_known <= 1'b0;
                    if (load_sector[31:4] == 0 && load_sector[3]) begin
                        expected_pixels <= 32'd0;
                        expected_data_bytes <= 32'd0;
                        expected_width <= 32'd0;
                        expected_height <= 32'd0;
                    end else if (load_sector[31:3] == 0 &&
                        load_sector[2:0] >= ASSET_RESOURCE) begin
                        expected_pixels <= ASSET_PIXELS;
                        expected_data_bytes <= ASSET_DATA_BYTES;
                        expected_width <= ASSET_WIDTH;
                        expected_height <= ASSET_HEIGHT;
                    end else begin
                        expected_pixels <= EXPECTED_PIXELS;
                        expected_data_bytes <= EXPECTED_DATA_BYTES;
                        expected_width <= {16'd0, bmp_width};
                        expected_height <= {16'd0, bmp_height};
                    end
                    bmp_error <= ERR_NONE;
                    pixel_byte_index <= 2'd0;
                    pixel_count <= 32'd0;
                    header_signature <= 16'd0;
                    header_file_size <= 32'd0;
                    header_pixel_offset <= 32'd0;
                    header_dib_size <= 32'd0;
                    header_width <= 32'd0;
                    header_height <= 32'd0;
                    header_planes <= 16'd0;
                    header_bit_count <= 16'd0;
                    header_compression <= 32'd0;
                if (load_sector[31:4] == 0 && load_sector[3] ?
                        (load_sector[2] || !ad_valid[load_sector[1:0]]) :
                        (load_sector[31:3] != 0 || !resource_valid[load_sector[2:0]])) begin
                        bmp_error <= ERR_FAT;
                        load_error <= 1'b1;
                    end else if (load_sector[3]) begin
                        selected_cluster <= (load_sector[1:0] == 2'd0) ? ad0_cluster :
                                            (load_sector[1:0] == 2'd1) ? ad1_cluster :
                                            (load_sector[1:0] == 2'd2) ? ad2_cluster : ad3_cluster;
                        selected_file_size <= (load_sector[1:0] == 2'd0) ? ad0_size :
                                              (load_sector[1:0] == 2'd1) ? ad1_size :
                                              (load_sector[1:0] == 2'd2) ? ad2_size : ad3_size;
                        owner <= OWNER_HEADER;
                        state <= ST_HEADER_DELTA;
                    end else begin
                        selected_cluster <= cluster_lut(load_sector[2:0]);
                        selected_file_size <= size_lut(load_sector[2:0]);
                        owner <= OWNER_HEADER;
                        state <= ST_HEADER_DELTA;
                    end
                end else if (audio_start && audio_available) begin
                    selected_cluster <= audio_file_cluster;
                    selected_file_size <= audio_file_size;
                    owner <= OWNER_AUDIO;
                    streamer_start <= 1'b1;
                    state <= ST_AUDIO;
                end
            end

            ST_SCAN: begin
                state_code <= 4'd2;
                if (scanner_done) begin
                    emit_index <= 3'd0;
                    emit_count <= 3'd0;
                    state <= ST_SCAN_EMIT;
                end
            end

            ST_SCAN_EMIT: begin
                state_code <= 4'd2;
                if (emit_index < 8) begin
                    if (resource_valid[emit_index[2:0]] &&
                        emit_count < scan_target_count) begin
                        scan_found_valid <= 1'b1;
                        scan_found_sector <= {29'd0, emit_index[2:0]};
                        emit_count <= emit_count + 1'b1;
                        scan_found_total <= emit_count + 1'b1;
                    end
                    emit_index <= emit_index + 1'b1;
                end else begin
                    scan_done <= 1'b1;
                    state <= ST_IDLE;
                end
            end

            ST_HEADER_DELTA: begin
                state_code <= 4'd2;
                selected_cluster_delta <= selected_cluster - 2;
                selected_pixel_limit <= selected_file_size - expected_data_bytes;
                selected_size_valid <= selected_file_size >= expected_data_bytes;
                state <= ST_HEADER_SHIFT;
            end

            ST_HEADER_SHIFT: begin
                state_code <= 4'd2;
                selected_sector_offset <= selected_cluster_delta << sectors_per_cluster_shift;
                state <= ST_HEADER_REQ;
            end

            ST_HEADER_REQ: begin
                state_code <= 4'd2;
                if (!adapter_busy) begin
                    header_sector_lba <= data_start_lba + selected_sector_offset;
                    header_sector_req <= 1'b1;
                    state <= ST_HEADER;
                end
            end

            ST_HEADER: begin
                state_code <= 4'd2;
                if (adapter_done) begin
                    if (adapter_error != 0) begin
                        bmp_error <= ERR_TIMEOUT;
                        load_error <= 1'b1;
                        state <= ST_IDLE;
                    end else if (load_is_ad && !ad_geometry_known) begin
                        state <= ST_AD_GEOM0;
                    end else begin
                        header_invalid <= (load_is_ad && !ad_range_ok) ||
                                          header_signature != 16'h4d42 ||
                                          header_dib_size < 32'd40 ||
                                          header_width != expected_width ||
                                          header_height != expected_height ||
                                          header_planes != 16'd1 ||
                                          header_bit_count != 16'd24 ||
                                          header_compression != 32'd0 ||
                                          header_pixel_offset < 32'd54 ||
                                          !selected_size_valid ||
                                          header_pixel_offset > selected_pixel_limit ||
                                          header_file_size < pixel_data_end ||
                                          header_file_size > selected_file_size;
                        state <= ST_HEADER_VALIDATE;
                    end
                end
            end

            ST_AD_GEOM0: begin
                state_code <= 4'd2;
                ad_range_ok <= header_width[31:11] == 0 && header_height[31:11] == 0 &&
                               header_width[1:0] == 2'd0 &&
                               header_width[10:0] >= 11'd320 && header_width[10:0] <= 11'd1024 &&
                               header_height[10:0] >= 11'd180 && header_height[10:0] <= 11'd1024;
                ad_pixels <= header_width[10:0] * header_height[10:0];
                state <= ST_AD_GEOM1;
            end

            ST_AD_GEOM1: begin
                state_code <= 4'd2;
                expected_width <= {21'd0, header_width[10:0]};
                expected_height <= {21'd0, header_height[10:0]};
                expected_pixels <= {11'd0, ad_pixels};
                expected_data_bytes <= {10'd0, ad_pixels, 1'b0} + {11'd0, ad_pixels};
                ad_geometry_known <= 1'b1;
                state <= ST_HEADER_DELTA;
            end

            ST_HEADER_VALIDATE: begin
                state_code <= 4'd2;
                if (header_invalid) begin
                    bmp_error <= ERR_HEADER;
                    load_error <= 1'b1;
                    state <= ST_IDLE;
                end else begin
                    write_req <= 1'b1;
                    state <= ST_WRITE_WAIT;
                end
            end

            ST_WRITE_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack_sync1) begin
                    write_req <= 1'b0;
                    owner <= OWNER_FILE;
                    state <= ST_FILE_START;
                    ad_stream_start <= load_is_ad;
                end
            end

            ST_FILE_START: begin
                state_code <= 4'd4;
                owner <= OWNER_FILE;
                pixel_byte_index <= 2'd0;
                pixel_count <= 32'd0;
                progress_pixel_count <= 14'd0;
                load_progress <= 7'd0;
                // A poster waits until the scaler can take its pixels. The
                // scaler clears ad_source_go when it sees ad_stream_start, so
                // a go left over from the previous poster is ignored then.
                if (!load_is_ad || (ad_source_go && !ad_stream_start)) begin
                    streamer_start <= 1'b1;
                    state <= ST_FILE;
                end
            end

            ST_FILE: begin
                state_code <= 4'd4;
                if (file_q_done) begin
                    if (file_q_error != 0) begin
                        bmp_error <= (file_q_error == 8'h10) ? ERR_TIMEOUT : ERR_FAT;
                        load_error <= 1'b1;
                    end else if (pixel_count != expected_pixels || pixel_byte_index != 0) begin
                        bmp_error <= ERR_TRUNCATED;
                        load_error <= 1'b1;
                    end else begin
                        bmp_error <= ERR_NONE;
                        load_progress <= 7'd64;
                        load_done <= 1'b1;
                    end
                    state <= ST_IDLE;
                end
            end

            ST_AUDIO: begin
                state_code <= 4'd5;
                if (streamer_done)
                    state <= ST_IDLE;
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
