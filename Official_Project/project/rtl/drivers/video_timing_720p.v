module video_timing_720p
(
    input  wire video_clk,
    input  wire rst,
    output reg  read_req,
    input  wire read_req_ack,
    output wire hs,
    output wire vs,
    output wire de
);

localparam H_ACTIVE = 12'd1280;
localparam H_FP     = 12'd110;
localparam H_SYNC   = 12'd40;
localparam H_BP     = 12'd220;
localparam V_ACTIVE = 12'd720;
localparam V_FP     = 12'd5;
localparam V_SYNC   = 12'd5;
localparam V_BP     = 12'd20;
localparam H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;
localparam V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;

reg [11:0] h_cnt;
reg [11:0] v_cnt;
reg        vs_d;

assign hs = (h_cnt >= H_FP) && (h_cnt < H_FP + H_SYNC);
assign vs = (v_cnt >= V_FP) && (v_cnt < V_FP + V_SYNC);
assign de = (h_cnt >= H_FP + H_SYNC + H_BP) &&
            (h_cnt < H_TOTAL) &&
            (v_cnt >= V_FP + V_SYNC + V_BP) &&
            (v_cnt < V_TOTAL);

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        h_cnt <= 12'd0;
        v_cnt <= 12'd0;
        vs_d  <= 1'b0;
    end else begin
        if (h_cnt == H_TOTAL - 1) begin
            h_cnt <= 12'd0;
            if (v_cnt == V_TOTAL - 1)
                v_cnt <= 12'd0;
            else
                v_cnt <= v_cnt + 12'd1;
        end else begin
            h_cnt <= h_cnt + 12'd1;
        end
        vs_d <= vs;
    end
end

always @(posedge video_clk or posedge rst) begin
    if (rst)
        read_req <= 1'b0;
    else if (vs_d && !vs)
        read_req <= 1'b1;
    else if (read_req_ack)
        read_req <= 1'b0;
end

endmodule
