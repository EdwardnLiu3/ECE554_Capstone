`timescale 1ns/1ps
import ob_pkg::*;
module tb_refill_engine();
    logic i_clk;
    logic i_rst_n;
    logic [NUM_LEVELS-1:0]          i_valid_table;
    logic [NUM_LEVELS-1:0]          i_cache_valid_table;
    logic [FLB_CACHE_LEVEL:0]       i_epoch;
    logic [FLB_CACHE_LEVEL:0]       o_epoch;
    logic [V_TABLE_IDX-1:0]         o_idx;
    logic o_found;

    flb_refill_engine_bid iDUT(
        .i_clk(i_clk),
        .i_rst_n(i_rst_n),
        .i_valid_table(i_valid_table),
        .i_cache_valid_table(i_cache_valid_table),
        .i_epoch(i_epoch),
        .o_epoch(o_epoch),
        .o_idx(o_idx),
        .o_found(o_found)
    );

    //CLOCK
    initial begin 
        i_clk = 0;
        forever #5 i_clk = ~i_clk;
    end

    //TASK:update cache and valid table
    task automatic update(
        input logic [NUM_LEVELS-1:0]          valid_table,
        input logic [NUM_LEVELS-1:0]          cache_valid_table,
        input logic [FLB_CACHE_LEVEL:0]       epoch
    );
    begin
        @(posedge i_clk);
        i_valid_table <= valid_table;
        i_cache_valid_table <= cache_valid_table;
        i_epoch <= epoch;
    end
    endtask

    initial begin
        i_rst_n = 0;
        i_valid_table = '0;
        i_cache_valid_table = '0;
        i_epoch = '0;

        repeat (5) @(posedge i_clk);
        i_rst_n = 1;

        update(16384'b111111111100, 16384'b111111111100, 4'd10);
        update(16384'b1_111111111100, 16384'b1_111111111000, 4'd11);
        update(16384'b11_111111111100, 16384'b11_111111110000, 4'd12);
        update(16384'b10_111111111100, 16384'b10_111111110000, 4'd13);

        repeat(10) @(posedge i_clk);
        $stop;
    end


endmodule