module pcm_media_tone #(
    parameter integer CLOCK_HZ     = 74_242_424,
    parameter integer SAMPLE_HZ    = 48_000,
    parameter integer BLIP_SAMPLES = 4_800,
    parameter integer NOTE_SAMPLES = 12_000
)(
    input  wire               clk,
    input  wire               rst,
    input  wire               enable,
    input  wire [1:0]         media_id,
    output reg                sample_valid,
    output reg signed [23:0]  sample_left,
    output reg signed [23:0]  sample_right
);

reg [31:0] sample_accumulator;
reg [31:0] phase_accumulator;
reg [31:0] blip_samples_remaining;
reg [31:0] note_sample_count;
reg [2:0]  note_index;
reg [1:0]  media_id_d;
wire [31:0] phase_increment;
wire signed [15:0] sine_value;

function [31:0] note_increment;
    input [1:0] media;
    input [2:0] note;
    begin
        case (media)
            2'd0: begin
                case (note)
                    3'd0: note_increment = 32'd46_819_617;
                    3'd1: note_increment = 32'd58_988_691;
                    3'd2: note_increment = 32'd70_150_238;
                    3'd3: note_increment = 32'd93_639_235;
                    3'd4: note_increment = 32'd70_150_238;
                    default: note_increment = 32'd58_988_691;
                endcase
            end
            2'd1: begin
                case (note)
                    3'd0: note_increment = 32'd39_370_534;
                    3'd1: note_increment = 32'd46_819_617;
                    3'd2: note_increment = 32'd58_988_691;
                    3'd3: note_increment = 32'd78_741_067;
                    3'd4: note_increment = 32'd58_988_691;
                    default: note_increment = 32'd46_819_617;
                endcase
            end
            2'd2: begin
                case (note)
                    3'd0: note_increment = 32'd52_553_399;
                    3'd1: note_increment = 32'd62_497_143;
                    3'd2: note_increment = 32'd70_150_238;
                    3'd3: note_increment = 32'd78_741_067;
                    3'd4: note_increment = 32'd93_639_235;
                    default: note_increment = 32'd78_741_067;
                endcase
            end
            default: begin
                case (note)
                    3'd0: note_increment = 32'd23_410_256;
                    3'd1: note_increment = 32'd35_075_566;
                    3'd2: note_increment = 32'd46_819_617;
                    3'd3: note_increment = 32'd70_150_238;
                    3'd4: note_increment = 32'd93_639_235;
                    default: note_increment = 32'd70_150_238;
                endcase
            end
        endcase
    end
endfunction

function signed [15:0] sine_sample;
    input [3:0] index;
    begin
        case (index)
            4'd0:    sine_sample = 16'sd0;
            4'd1:    sine_sample = 16'sd4592;
            4'd2:    sine_sample = 16'sd8485;
            4'd3:    sine_sample = 16'sd11087;
            4'd4:    sine_sample = 16'sd12000;
            4'd5:    sine_sample = 16'sd11087;
            4'd6:    sine_sample = 16'sd8485;
            4'd7:    sine_sample = 16'sd4592;
            4'd8:    sine_sample = 16'sd0;
            4'd9:    sine_sample = -16'sd4592;
            4'd10:   sine_sample = -16'sd8485;
            4'd11:   sine_sample = -16'sd11087;
            4'd12:   sine_sample = -16'sd12000;
            4'd13:   sine_sample = -16'sd11087;
            4'd14:   sine_sample = -16'sd8485;
            default: sine_sample = -16'sd4592;
        endcase
    end
endfunction

assign phase_increment = (blip_samples_remaining != 0) ? 32'd134_217_728 :
                         note_increment(media_id, note_index);
assign sine_value = sine_sample(phase_accumulator[31:28]);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sample_accumulator     <= 32'd0;
        phase_accumulator      <= 32'd0;
        blip_samples_remaining <= 32'd0;
        note_sample_count      <= 32'd0;
        note_index             <= 3'd0;
        media_id_d             <= 2'd0;
        sample_valid           <= 1'b0;
        sample_left            <= 24'sd0;
        sample_right           <= 24'sd0;
    end else begin
        sample_valid <= 1'b0;
        if (!enable) begin
            sample_accumulator     <= 32'd0;
            phase_accumulator      <= 32'd0;
            blip_samples_remaining <= 32'd0;
            note_sample_count      <= 32'd0;
            note_index             <= 3'd0;
            media_id_d             <= media_id;
            sample_left            <= 24'sd0;
            sample_right           <= 24'sd0;
        end else begin
            if (sample_accumulator >= (CLOCK_HZ - SAMPLE_HZ)) begin
                sample_accumulator <= sample_accumulator + SAMPLE_HZ - CLOCK_HZ;
                sample_valid       <= 1'b1;

                if (media_id != media_id_d) begin
                    phase_accumulator      <= 32'd0;
                    blip_samples_remaining <= BLIP_SAMPLES;
                    note_sample_count      <= 32'd0;
                    note_index             <= 3'd0;
                    media_id_d             <= media_id;
                end else begin
                    phase_accumulator <= phase_accumulator + phase_increment;
                    sample_left       <= {{1{sine_value[15]}}, sine_value, 7'd0};
                    sample_right      <= {{1{sine_value[15]}}, sine_value, 7'd0};

                    if (blip_samples_remaining != 0) begin
                        blip_samples_remaining <= blip_samples_remaining - 32'd1;
                        if (blip_samples_remaining == 1)
                            phase_accumulator <= 32'd0;
                    end else if (note_sample_count >= NOTE_SAMPLES - 1) begin
                        note_sample_count <= 32'd0;
                        if (note_index == 3'd5)
                            note_index <= 3'd0;
                        else
                            note_index <= note_index + 3'd1;
                    end else begin
                        note_sample_count <= note_sample_count + 32'd1;
                    end
                end
            end else begin
                sample_accumulator <= sample_accumulator + SAMPLE_HZ;
                if (media_id != media_id_d) begin
                    phase_accumulator      <= 32'd0;
                    blip_samples_remaining <= BLIP_SAMPLES;
                    note_sample_count      <= 32'd0;
                    note_index             <= 3'd0;
                    media_id_d             <= media_id;
                end
            end
        end
    end
end

endmodule
