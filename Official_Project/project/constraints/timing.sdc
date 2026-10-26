
# ============================================================
# merged_top_tf_hdmi_audio.sdc
# 用于：TF 图片轮播 + HDMI(视频+音频) 整合工程
#
# 合并原则：
# 1) 保留 top.sdc 里的系统主时钟与 derive_clocks
# 2) 把 timing(2).sdc 里的 pixel/serial 时钟改成整合工程实际名字
# 3) 增加 hdmi_5x_clk / audio_mclk 的命名
# 4) 不再对内部 net 直接 create_clock，避免和 derive_clocks 重复
# ============================================================

# ------------------------------------------------------------
# 1. 板级输入主时钟
#    你的原 top.sdc 里 clk=50MHz，所以这里仍然用 20ns
# ------------------------------------------------------------
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
# RXC from the PHY: 125 MHz at 1000 Mbps.
create_clock -name eth_rxc -period 8 -waveform {0 4} [get_ports {phy1_rgmii_rx_clk}]

# ------------------------------------------------------------
# 2. 自动推导 PLL 输出时钟
# ------------------------------------------------------------
derive_clocks

# ------------------------------------------------------------
# 3. 给关键 PLL 输出命名
#    下面这些路径是按你当前工程实例名写的：
#      sys_pll      -> sys_pll_m0
#      video_pll    -> video_pll_m0
#      音频 PLL     -> u_audio_pll
#
#    如果综合后实例路径略有不同，就按 Timing Analyzer 里的实际 pin 路径改。
# ------------------------------------------------------------
rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {ext_mem_clk_sft} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[2]}]
rename_clock -name {video_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {eth_tx_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {u_front_link/u_node/u_tx_pll/pll_inst.clkc[0]}]
rename_clock -name {eth_tx_clk90} -source [get_ports {clk}] -master_clock {clk} [get_pins {u_front_link/u_node/u_tx_pll/pll_inst.clkc[4]}]


# ------------------------------------------------------------
# 4. 从原 timing(2).sdc 迁移过来的 HDMI 像素/串行时钟约束
#
#    原文件是：
#      create_clock -name pixel_clk  ... [get_nets {S_pixel_clk}]
#      create_clock -name serial_clk ... [get_nets {S_serial_clk}]
#      set_clock_groups -exclusive ...
#
#    在整合工程里，这两个时钟已经由 video_pll 产生，并通过 derive_clocks 建出来了，
#    所以这里只保留“组关系”，不再重复 create_clock。
#
#    这里沿用原作者的写法，把 video_clk 和 hdmi_5x_clk 设成 exclusive。
#    如果后面 Timing Analyzer 明确显示两者之间需要做同步时序分析，再把这一条去掉。
# ------------------------------------------------------------
set_clock_groups -exclusive \
    -group [get_clocks {video_clk}] \
    -group [get_clocks {hdmi_5x_clk}]

set_clock_groups -asynchronous \
    -group [get_clocks {sd_card_clk}] \
    -group [get_clocks {ext_mem_clk ext_mem_clk_sft}] \
    -group [get_clocks {video_clk}]

# The board link: every crossing goes through a synchroniser or a toggle
# handshake (front_link.v).
set_clock_groups -asynchronous -group [get_clocks {eth_tx_clk eth_tx_clk90}] -group [get_clocks -include_generated_clocks {eth_rxc}] -group [get_clocks {clk sd_card_clk ext_mem_clk ext_mem_clk_sft video_clk hdmi_5x_clk}]



# ------------------------------------------------------------
# 6. 可选：如果你的 frame_read_write 内部异步 FIFO 已经完全处理好了跨域，
#    且报告里总出现 video_clk / sd_card_clk / ext_mem_clk 之间的大量伪违例，
#    可以打开下面这组异步分组。
#
#    建议先不要开，先看报告；
#    只有确认这些跨域都只经过 FIFO / 同步器时再开。
# ------------------------------------------------------------
# set_clock_groups -asynchronous \
#     -group [get_clocks {sd_card_clk}] \
#     -group [get_clocks {ext_mem_clk}] \
#     -group [get_clocks {video_clk}] \
#     -group [get_clocks {hdmi_5x_clk}]

# ------------------------------------------------------------
# 7. 其余 Input/Output delay 先保持空白
#    你当前两个原始 sdc 也都没有写这部分。
# ------------------------------------------------------------

# Reset requests and the first stage of each synchronizer are asynchronous.
# Legacy external rst_n port was removed when physical K1 was reassigned.
# set_false_path -from [get_ports {rst_n}]
set_false_path -to [get_regs -hier {*/s1}]
set_false_path -to [get_regs -hier {*parameter_popup_*_sync0*}]
set_false_path -to [get_regs -hier {*ticker_speed_video_sync0*}]
set_false_path -to [get_regs -hier {*sold_out_video_sync0*}]
set_false_path -to [get_regs -hier {*sold_out_sync0*}]
# Advert player and auto-play interval crossings (two-stage synchronisers).
set_false_path -to [get_regs -hier {*interval_video_sync0*}]
set_false_path -to [get_regs -hier {*wave_color_video_sync0*}]
set_false_path -to [get_regs -hier {*auto_interval_sync0*}]
set_false_path -to [get_regs -hier {*ad_bank_sync0*}]
set_false_path -to [get_regs -hier {*ad_key_mask_sync0*}]
# Music following the screen: on / off into the video clock, track back.
set_false_path -to [get_regs -hier {*music_want_sync0*}]
set_false_path -to [get_regs -hier {*music_target_ctrl_sync0*}]
set_false_path -to [get_regs -hier {*kitchen_event_video_sync0*}]
# rst_all only drives asynchronous reset pins. Each domain releases reset
# through its local two-stage reset_sync instance.
set_false_path -through [get_nets -hier {rst_all}]

# Bound the fabric-to-TMDS output path without timing unrelated clock domains.
set_max_delay -from [get_clocks {hdmi_5x_clk}] \
    -to [get_ports {HDMI_CLK_P HDMI_D0_P HDMI_D1_P HDMI_D2_P}] \
    8.000 -datapath_only

# The shifted SDRAM clock is constrained by the memory I/O window.
set_false_path -from [get_clocks {ext_mem_clk}] -to [get_clocks {ext_mem_clk_sft}]
set_false_path -from [get_clocks {ext_mem_clk_sft}] -to [get_clocks {ext_mem_clk}]
