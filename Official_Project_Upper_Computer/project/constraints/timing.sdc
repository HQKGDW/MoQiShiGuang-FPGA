# Kitchen console timing constraints.

# 50 MHz board clock and RXC from the PHY (125 MHz at 1000 Mbps).
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
create_clock -name eth_rxc -period 8 -waveform {0 4} [get_ports {phy1_rgmii_rx_clk}]
derive_clocks
rename_clock -name {video_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {u_video_pll/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {u_video_pll/pll_inst.clkc[1]}]
rename_clock -name {eth_tx_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {u_link/u_node/u_tx_pll/pll_inst.clkc[0]}]
rename_clock -name {eth_tx_clk90} -source [get_ports {clk}] -master_clock {clk} [get_pins {u_link/u_node/u_tx_pll/pll_inst.clkc[4]}]

# Every crossing between the video, Ethernet transmit and Ethernet receive
# domains goes through a synchroniser or a toggle handshake.
set_clock_groups -asynchronous -group [get_clocks {clk}] -group [get_clocks {video_clk hdmi_5x_clk}] -group [get_clocks {eth_tx_clk eth_tx_clk90}] -group [get_clocks -include_generated_clocks {eth_rxc}]

# The TMDS serialiser takes the pixel clock and the 5x clock in fixed phase.
set_clock_groups -exclusive \
    -group [get_clocks {video_clk}] \
    -group [get_clocks {hdmi_5x_clk}]

# Reset request (board clock) and the first stage of every synchroniser.
set_false_path -from [get_regs {rst_all*}]
set_false_path -to [get_regs -hier {*/s1}]
set_false_path -to [get_regs -hier {*mode_sync0*}]
set_false_path -to [get_regs -hier {*music_track_sync0*}]
set_false_path -to [get_regs -hier {*music_enable_sync0*}]
set_false_path -to [get_regs -hier {*wstate_sync1*}]

# Bound the fabric-to-TMDS output path.
set_max_delay -from [get_clocks {hdmi_5x_clk}] \
    -to [get_ports {HDMI_CLK_P HDMI_D0_P HDMI_D1_P HDMI_D2_P}] \
    8.000 -datapath_only
