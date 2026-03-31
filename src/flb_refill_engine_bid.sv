module flb_refill_engine_bid(
    input                           i_clk,
    input                           i_rst_n,
    input [NUM_LEVELS-1:0]          i_valid_table,
    input [NUM_LEVELS-1:0]          i_cache_valid_table,
    input [FLB_CACHE_LEVEL:0]       i_epoch,
    output [FLB_CACHE_LEVEL:0]      o_epoch,
    output [$clog2(NUM_LEVELS)-1:0] o_idx
);

pe_msb findGroup(
    .i_data(),
    .o_found(),
    .o_idx()
)

pe_msb findIndex(
    .i_data(),
    .o_found(),
    .o_idx()
)

endmodule