`timescale 1ns/1ps

module key_click_sound #(
    parameter integer CLICK_SAMPLES = 2400
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               trigger,
    input  wire [1:0]         key_code,
    input  wire               sample_tick,
    output reg                active,
    output reg signed [23:0]  sample_left,
    output reg signed [23:0]  sample_right
);
    reg [11:0] sample_count;
    reg [31:0] phase_accumulator;
    reg [31:0] phase_increment;
    reg [7:0] envelope_gain;
    wire signed [15:0] sine_value;
    wire signed [23:0] scaled_sample;

    function signed [15:0] sine_sample;
        input [3:0] index;
        begin
            case (index)
                4'd0: sine_sample = 16'sd0;
                4'd1: sine_sample = 16'sd1913;
                4'd2: sine_sample = 16'sd3536;
                4'd3: sine_sample = 16'sd4619;
                4'd4: sine_sample = 16'sd5000;
                4'd5: sine_sample = 16'sd4619;
                4'd6: sine_sample = 16'sd3536;
                4'd7: sine_sample = 16'sd1913;
                4'd8: sine_sample = 16'sd0;
                4'd9: sine_sample = -16'sd1913;
                4'd10: sine_sample = -16'sd3536;
                4'd11: sine_sample = -16'sd4619;
                4'd12: sine_sample = -16'sd5000;
                4'd13: sine_sample = -16'sd4619;
                4'd14: sine_sample = -16'sd3536;
                default: sine_sample = -16'sd1913;
            endcase
        end
    endfunction

    assign sine_value = sine_sample(phase_accumulator[31:28]);
    assign scaled_sample = ($signed(sine_value) * $signed({1'b0, envelope_gain})) <<< 1;

    always @* begin
        if (sample_count < 12'd128)
            envelope_gain = sample_count[6:0] << 1;
        else if (sample_count >= CLICK_SAMPLES - 512)
            envelope_gain = (CLICK_SAMPLES - sample_count) >> 1;
        else
            envelope_gain = 8'd255;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            sample_count <= 12'd0;
            phase_accumulator <= 32'd0;
            phase_increment <= 32'd0;
            sample_left <= 24'sd0;
            sample_right <= 24'sd0;
        end else begin
            if (trigger) begin
                active <= 1'b1;
                sample_count <= 12'd0;
                phase_accumulator <= 32'd0;
                case (key_code)
                    2'd0: phase_increment <= 32'd107_374_182;
                    2'd1: phase_increment <= 32'd80_530_636;
                    2'd2: phase_increment <= 32'd95_443_717;
                    default: phase_increment <= 32'd127_131_032;
                endcase
            end else if (active && sample_tick) begin
                phase_accumulator <= phase_accumulator + phase_increment;
                sample_left <= scaled_sample;
                sample_right <= scaled_sample;
                if (sample_count == CLICK_SAMPLES - 1) begin
                    active <= 1'b0;
                    sample_left <= 24'sd0;
                    sample_right <= 24'sd0;
                end else begin
                    sample_count <= sample_count + 1'b1;
                end
            end else if (!active) begin
                sample_left <= 24'sd0;
                sample_right <= 24'sd0;
            end
        end
    end
endmodule
