`timescale 1ns/1ps

// RGMII interface to the on-board RTL8211E, configured like the official
// gigabit reference design (HX4S20_Ethernet_test, 1000 Mbps):
//   - transmit: data DDR on the 125 MHz clock, TXC forwarded from a 90 degree
//     copy of it (and OUTDEL = 3 on the TXC pin in the constraints)
//   - receive: RXC passes through a PLL (deskew) before clocking the IDDRs
// ETH_SIM replaces the PLLs with behavioural clocks for simulation.
//
// Shared by both projects: keep the copies identical.

// 50 MHz -> 125 MHz (0 degrees) and 125 MHz (90 degrees).
module eth_tx_pll (
    input  wire refclk,
    input  wire reset,
    output wire extlock,
    output wire clk125,
    output wire clk125_90
);
`ifdef ETH_SIM
    reg c0 = 1'b0, c90 = 1'b0;
    always #4 c0 = ~c0;
    initial begin #2; forever #4 c90 = ~c90; end
    assign clk125 = c0;
    assign clk125_90 = c90;
    assign extlock = 1'b1;
`else
    wire clk0_buf;
    wire [2:0] unused;
    EG_LOGIC_BUFG bufg_feedback (.i(clk0_buf), .o(clk125));
    EG_PHY_PLL #(
        .DPHASE_SOURCE("DISABLE"), .DYNCFG("DISABLE"), .FIN("50.000"),
        .FEEDBK_MODE("NORMAL"), .FEEDBK_PATH("CLKC0_EXT"), .STDBY_ENABLE("DISABLE"),
        .PLLRST_ENA("ENABLE"), .SYNC_ENABLE("DISABLE"),
        .GMC_GAIN(2), .ICP_CURRENT(9), .KVCO(2), .LPF_CAPACITOR(1), .LPF_RESISTOR(8),
        .REFCLK_DIV(2), .FBCLK_DIV(5),
        .CLKC0_ENABLE("ENABLE"), .CLKC0_DIV(8), .CLKC0_CPHASE(7), .CLKC0_FPHASE(0),
        .CLKC1_ENABLE("ENABLE"), .CLKC1_DIV(8), .CLKC1_CPHASE(7), .CLKC1_FPHASE(0),
        .CLKC2_ENABLE("ENABLE"), .CLKC2_DIV(80), .CLKC2_CPHASE(79), .CLKC2_FPHASE(0),
        .CLKC3_ENABLE("ENABLE"), .CLKC3_DIV(40), .CLKC3_CPHASE(39), .CLKC3_FPHASE(0),
        .CLKC4_ENABLE("ENABLE"), .CLKC4_DIV(8), .CLKC4_CPHASE(1), .CLKC4_FPHASE(0)
    ) pll_inst (
        .refclk(refclk), .reset(reset), .stdby(1'b0), .extlock(extlock),
        .load_reg(1'b0), .psclk(1'b0), .psdown(1'b0), .psstep(1'b0), .psclksel(3'b000),
        .psdone(), .dclk(1'b0), .dcs(1'b0), .dwe(1'b0), .di(8'b00000000), .daddr(6'b000000),
        .do(), .fbclk(clk125), .clkc({clk125_90, unused, clk0_buf})
    );
`endif
endmodule

// RXC (125 MHz from the PHY) through a PLL for deskew.
module eth_rx_pll (
    input  wire refclk,
    output wire clk_out
);
`ifdef ETH_SIM
    assign clk_out = refclk;
`else
    wire clk0_buf;
    wire clk0_out;
    wire [2:0] unused;
    EG_LOGIC_BUFG bufg_feedback (.i(clk0_buf), .o(clk0_out));
    EG_PHY_PLL #(
        .DPHASE_SOURCE("DISABLE"), .DYNCFG("DISABLE"), .FIN("125.000"),
        .FEEDBK_MODE("NORMAL"), .FEEDBK_PATH("CLKC0_EXT"), .STDBY_ENABLE("DISABLE"),
        .PLLRST_ENA("ENABLE"), .SYNC_ENABLE("DISABLE"),
        .GMC_GAIN(6), .GMC_TEST(15), .ICP_CURRENT(13), .KVCO(4), .LPF_CAPACITOR(1),
        .LPF_RESISTOR(2), .REFCLK_DIV(1), .FBCLK_DIV(1),
        .CLKC0_ENABLE("ENABLE"), .CLKC0_DIV(8), .CLKC0_CPHASE(7), .CLKC0_FPHASE(0),
        .CLKC1_ENABLE("ENABLE"), .CLKC1_DIV(8), .CLKC1_CPHASE(7), .CLKC1_FPHASE(0),
        .CLKC2_ENABLE("ENABLE"), .CLKC2_DIV(4), .CLKC2_CPHASE(3), .CLKC2_FPHASE(0)
    ) pll_inst (
        .refclk(refclk), .reset(1'b0), .stdby(1'b0), .extlock(),
        .load_reg(1'b0), .psclk(1'b0), .psdown(1'b0), .psstep(1'b0), .psclksel(3'b000),
        .psdone(), .dclk(1'b0), .dcs(1'b0), .dwe(1'b0), .di(8'b00000000), .daddr(6'b000000),
        .do(), .fbclk(clk0_out), .clkc({unused[2:1], unused[0], clk_out, clk0_buf})
    );
`endif
endmodule

// DDR conversion between the 8-bit GMII-style buses and the 4-bit RGMII pins.
module eth_rgmii (
    input  wire       tx_clk,         // 125 MHz
    input  wire       tx_clk90,       // 125 MHz, 90 degrees later
    input  wire [7:0] gmii_txd,
    input  wire       gmii_tx_en,
    output wire [3:0] rgmii_txd,
    output wire       rgmii_tx_ctl,
    output wire       rgmii_txc,
    input  wire       rx_clk,         // deskewed RXC
    input  wire [3:0] rgmii_rxd,
    input  wire       rgmii_rx_ctl,
    output wire [7:0] gmii_rxd,
    output wire       gmii_rx_dv,
    output wire       gmii_rx_er
);
    wire rx_ctl_fall;
    genvar i;
    generate for (i = 0; i < 4; i = i + 1) begin : g_lane
        // Low nibble on the rising edge, high nibble on the falling edge.
        EG_LOGIC_ODDR #(.ASYNCRST("ENABLE")) u_txd (
            .q(rgmii_txd[i]), .clk(tx_clk), .d0(gmii_txd[i]), .d1(gmii_txd[i + 4]), .rst(1'b0));
        EG_LOGIC_IDDR #(.ASYNCRST("ENABLE"), .PIPEMODE("PIPED")) u_rxd (
            .q0(gmii_rxd[i]), .q1(gmii_rxd[i + 4]), .clk(rx_clk), .d(rgmii_rxd[i]), .rst(1'b0));
    end endgenerate
    // TX_CTL carries TX_EN on both edges (TX_ER is never used).
    EG_LOGIC_ODDR #(.ASYNCRST("ENABLE")) u_tx_ctl (
        .q(rgmii_tx_ctl), .clk(tx_clk), .d0(gmii_tx_en), .d1(gmii_tx_en), .rst(1'b0));
    EG_LOGIC_ODDR #(.ASYNCRST("ENABLE")) u_txc (
        .q(rgmii_txc), .clk(tx_clk90), .d0(1'b1), .d1(1'b0), .rst(1'b0));
    EG_LOGIC_IDDR #(.ASYNCRST("ENABLE"), .PIPEMODE("PIPED")) u_rx_ctl (
        .q0(gmii_rx_dv), .q1(rx_ctl_fall), .clk(rx_clk), .d(rgmii_rx_ctl), .rst(1'b0));
    assign gmii_rx_er = gmii_rx_dv ^ rx_ctl_fall;
endmodule

// One network port: PLLs, RGMII and the MAC, with a transmit interface in
// the 125 MHz clock and a receive stream in the recovered RX clock.
module eth_node #(
    parameter [47:0] SRC_MAC = 48'h02_00_00_00_00_01
) (
    input  wire        clk50,
    input  wire        rst_n,             // asynchronous, active low
    output wire [3:0]  rgmii_txd,
    output wire        rgmii_tx_ctl,
    output wire        rgmii_txc,
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rx_ctl,
    input  wire        rgmii_rxc,
    // Transmit side (clk125).
    output wire        clk125,
    output wire        tx_rst_n,
    input  wire        tx_start,
    input  wire [10:0] tx_length,
    output wire        tx_busy,
    output wire [10:0] tx_index,
    input  wire [7:0]  tx_data,
    // Receive side (rx_clk).
    output wire        rx_clk,
    output wire        rx_rst_n,
    output wire        rx_valid,
    output wire [7:0]  rx_byte,
    output wire [10:0] rx_index,
    output wire        rx_end,
    output wire        rx_good
);
    wire clk125_90, pll_lock;
    eth_tx_pll u_tx_pll (.refclk(clk50), .reset(1'b0), .extlock(pll_lock),
                         .clk125(clk125), .clk125_90(clk125_90));
    eth_rx_pll u_rx_pll (.refclk(rgmii_rxc), .clk_out(rx_clk));
    reset_sync u_tx_reset (.clk(clk125), .ext_rst_n(rst_n && pll_lock), .rst_n_sync(tx_rst_n));
    reset_sync u_rx_reset (.clk(rx_clk), .ext_rst_n(rst_n), .rst_n_sync(rx_rst_n));

    wire [7:0] gmii_txd, gmii_rxd;
    wire       gmii_tx_en, gmii_rx_dv, gmii_rx_er;
    eth_rgmii u_rgmii (
        .tx_clk(clk125), .tx_clk90(clk125_90), .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en),
        .rgmii_txd(rgmii_txd), .rgmii_tx_ctl(rgmii_tx_ctl), .rgmii_txc(rgmii_txc),
        .rx_clk(rx_clk), .rgmii_rxd(rgmii_rxd), .rgmii_rx_ctl(rgmii_rx_ctl),
        .gmii_rxd(gmii_rxd), .gmii_rx_dv(gmii_rx_dv), .gmii_rx_er(gmii_rx_er));
    eth_tx_mac #(.SRC_MAC(SRC_MAC)) u_tx (
        .clk(clk125), .rst_n(tx_rst_n), .start(tx_start), .length(tx_length), .busy(tx_busy),
        .pay_index(tx_index), .pay_data(tx_data), .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en));
    eth_rx_mac u_rx (
        .clk(rx_clk), .rst_n(rx_rst_n), .gmii_rxd(gmii_rxd), .gmii_rx_dv(gmii_rx_dv),
        .gmii_rx_er(gmii_rx_er), .rx_valid(rx_valid), .rx_byte(rx_byte), .rx_index(rx_index),
        .rx_end(rx_end), .rx_good(rx_good));
endmodule
