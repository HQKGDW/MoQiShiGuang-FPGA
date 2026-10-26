


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

// Parenthesize both macros: textual substitution must preserve division order.
// The unparenthesized form expanded to 64000000/1000000000/... = 0, which
// silently disabled every auto-refresh and let idle frame banks decay.
// 125 MHz, 4096 refresh commands per 64 ms: 8 ns per clock, 1953 clocks per slot.
`define   SDR_REFRESH_COMMANDS             4096
`define   SDR_CLK_PERIOD                   (1000000000 / 125000000)
`define   SELF_REFRESH_INTERVAL            (64000000 / `SDR_CLK_PERIOD / `SDR_REFRESH_COMMANDS)

