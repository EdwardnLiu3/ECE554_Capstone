import ob_pkg::*;
module flb_refill_engine_bid(
    input logic                           i_clk,
    input logic                           i_rst_n,
    input logic [NUM_LEVELS-1:0]          i_valid_table,
    input logic [NUM_LEVELS-1:0]          i_cache_valid_table,
    input logic [FLB_CACHE_LEVEL:0]       i_epoch,
    output logic [FLB_CACHE_LEVEL:0]      o_epoch,
    output logic [V_TABLE_IDX-1:0]        o_idx,
    output logic                          o_found
);

logic [NUM_LEVELS-1:0]mask_data0, mask_data1;
logic [127:0] grouped_data0, grouped_data1;
logic found_group1, found_inner2, found_inner3;
logic [127:0] group_idx1, group_idx2, idx;
logic [127:0] selected_group1, selected_group2;
logic [127:0] inner_idx2;
logic [FLB_CACHE_LEVEL:0] epoch1, epoch2, epoch3;


pe_msb128 findGroup(
    .i_data(grouped_data1),
    .o_found(found_group1),
    .o_idx(group_idx1)
);

pe_msb128 findIndex(
    .i_data(selected_group2),
    .o_found(found_inner2),
    .o_idx(inner_idx2)
);


//find which group have the msb
always_comb begin
    mask_data0 = i_valid_table & (~i_cache_valid_table);
    grouped_data0 = '0;
    for(int i = 0; i < NUM_LEVELS/128; i++) begin
        grouped_data0[i] = |mask_data0[i*128+:128];
    end
end

// find the msb of the msgroup
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        grouped_data1 <= '0;
        mask_data1 <= '0;
        epoch1 <= '0;
    end else begin
        grouped_data1 <= grouped_data0;
        mask_data1 <= mask_data0;
        epoch1 <= i_epoch;
    end
end

always_comb begin
    selected_group1 = '0;
    if(found_group1) begin
        selected_group1 = mask_data1[group_idx1*128+:128];
    end
end


always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        selected_group2 <= '0;
        group_idx2 <= '0;
        epoch2 <= '0;
    end else begin
        selected_group2 <= selected_group1;
        group_idx2 <= group_idx1;
        epoch2 <= epoch1;
    end
end

always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        found_inner3 <= 0;
        idx <= '0;
        epoch3 <= '0;
    end else begin
        found_inner3 <= found_inner2;
        idx <= {group_idx2, inner_idx2};
        epoch3 <= epoch2;
    end
end

assign o_idx = idx;
assign o_found = found_inner3;
assign o_epoch = epoch3;

endmodule
