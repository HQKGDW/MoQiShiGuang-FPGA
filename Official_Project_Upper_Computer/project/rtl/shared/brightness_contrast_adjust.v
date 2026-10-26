`timescale 1ns/1ps

module brightness_contrast_adjust (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_vs,
    input  wire        in_de,
    input  wire [23:0] rgb_in,
    input  wire [7:0]  brightness,
    input  wire [7:0]  contrast,
    output reg         out_vs,
    output reg         out_de,
    output reg  [23:0] rgb_out
);
    wire [16:0] bright_mul_r = rgb_in[23:16] * (brightness + 1'b1);
    wire [16:0] bright_mul_g = rgb_in[15:8]  * (brightness + 1'b1);
    wire [16:0] bright_mul_b = rgb_in[7:0]   * (brightness + 1'b1);
    wire [7:0] bright_r = bright_mul_r[15:8];
    wire [7:0] bright_g = bright_mul_g[15:8];
    wire [7:0] bright_b = bright_mul_b[15:8];
    reg [7:0] bright_r_q;
    reg [7:0] bright_g_q;
    reg [7:0] bright_b_q;
    reg [7:0] contrast_q;
    reg       vs_q;
    reg       de_q;

    wire signed [8:0] center_r = $signed({1'b0, bright_r_q}) - 9'sd128;
    wire signed [8:0] center_g = $signed({1'b0, bright_g_q}) - 9'sd128;
    wire signed [8:0] center_b = $signed({1'b0, bright_b_q}) - 9'sd128;
    wire signed [16:0] scaled_r = (center_r * $signed({1'b0, contrast_q})) >>> 7;
    wire signed [16:0] scaled_g = (center_g * $signed({1'b0, contrast_q})) >>> 7;
    wire signed [16:0] scaled_b = (center_b * $signed({1'b0, contrast_q})) >>> 7;
    wire signed [17:0] result_r = scaled_r + 18'sd128;
    wire signed [17:0] result_g = scaled_g + 18'sd128;
    wire signed [17:0] result_b = scaled_b + 18'sd128;
    wire [7:0] final_r = (result_r < 18'sd0) ? 8'd0 :
                         (result_r > 18'sd255) ? 8'd255 : result_r[7:0];
    wire [7:0] final_g = (result_g < 18'sd0) ? 8'd0 :
                         (result_g > 18'sd255) ? 8'd255 : result_g[7:0];
    wire [7:0] final_b = (result_b < 18'sd0) ? 8'd0 :
                         (result_b > 18'sd255) ? 8'd255 : result_b[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bright_r_q <= 8'd0;
            bright_g_q <= 8'd0;
            bright_b_q <= 8'd0;
            contrast_q <= 8'd0;
            vs_q       <= 1'b0;
            de_q       <= 1'b0;
            out_vs  <= 1'b0;
            out_de  <= 1'b0;
            rgb_out <= 24'd0;
        end else begin
            bright_r_q <= bright_r;
            bright_g_q <= bright_g;
            bright_b_q <= bright_b;
            contrast_q <= contrast;
            vs_q       <= in_vs;
            de_q       <= in_de;
            out_vs  <= vs_q;
            out_de  <= de_q;
            rgb_out <= {final_r, final_g, final_b};
        end
    end
endmodule
