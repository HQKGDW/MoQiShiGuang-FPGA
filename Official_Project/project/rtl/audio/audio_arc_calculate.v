`include "pcm_media_tone.v"

module audio_arc_calculate #(
    parameter integer ACR_N = 6144
)(
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_audio_valid,
    output reg         O_acr_valid,
    output reg [19:0]  O_acr_cts,
    output reg [19:0]  O_acr_n
);

localparam integer AUDIO_DIV = ACR_N >> 7;

reg [7:0]  audio_div_cnt;
reg [19:0] acr_cts_cnt;
wire       audio_valid_div;

assign audio_valid_div = I_audio_valid && (audio_div_cnt == AUDIO_DIV - 1);

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        audio_div_cnt <= 8'd0;
        acr_cts_cnt   <= 20'd0;
        O_acr_valid   <= 1'b0;
        O_acr_cts     <= 20'd0;
        O_acr_n       <= 20'd0;
    end else begin
        O_acr_valid <= 1'b0;
        O_acr_cts   <= 20'd0;
        O_acr_n     <= 20'd0;

        if (I_audio_valid) begin
            if (audio_valid_div)
                audio_div_cnt <= 8'd0;
            else
                audio_div_cnt <= audio_div_cnt + 8'd1;
        end

        if (audio_valid_div) begin
            acr_cts_cnt <= 20'd0;
            O_acr_valid <= 1'b1;
            O_acr_cts   <= acr_cts_cnt + 20'd1;
            O_acr_n     <= ACR_N;
        end else begin
            acr_cts_cnt <= acr_cts_cnt + 20'd1;
        end
    end
end

endmodule
