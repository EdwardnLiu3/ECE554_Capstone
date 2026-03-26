import ob_pkg::*; 
module ob_flb #(parameter int BASE_PRICE = 0)(
    input logic i_clk,
    input logic i_rst_n,
    input logic [QUANTITY_LEN-1:0] i_quantity,
    input logic [1:0] i_action,
    input logic i_valid,
    input logic [PRICE_LEN-1:0] i_price,
    input logic i_side, // 1 = bid, 0 = ask
    output logic o_valid,
    output logic [1:0]o_action,
    output logic [PRICE_LEN-1:0]o_current_price,
    output logic [QUANTITY_LEN-1:0]o_current_quant,
    output logic [PRICE_LEN-1:0]o_best_price,
    output logic [TOT_QUATITY_LEN-1:0]o_best_price_quant,
    output logic [TOT_QUATITY_LEN-1:0]o_total_quant
);

// index setup
logic [$clog2(NUM_LEVELS)-1:0]  index2, index3, index4;
logic [PRICE_LEN-1:0]           price_diff;

// pipeline val
logic                       valid1, valid2, valid3, valid4;
logic [1:0]                 action1, action2, action3, action4;
logic [QUANTITY_LEN-1:0]    quantity1, quantity2, quantity3;

// FLB update
(* ram_style = "block" *) logic [QUANTITY_LEN-1:0]  FLB [0:NUM_LEVELS-1];
logic [QUANTITY_LEN-1:0]                            old_qty3, new_qty4;

// cache
flb_cache_packet_t          cache [0:FLB_CACHE_LEVEL-1];
logic [NUM_LEVELS-1:0]      valid_table, cache_valid_table;
logic                       cache_hit4;
logic [CACHE_POS-1:0]       hit_pos4, last_valid5, add_pos4;
logic [FLB_CACHE_LEVEL:0]   epoch5;
logic                       add_2_cache;
flb_cache_packet_t          tmp, carry;

// pipeline valid bit
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        valid1 <= 0;
        valid2 <= 0;
        valid3 <= 0;
        valid4 <= 0;
    end else begin
        valid1 <= i_valid;
        valid2 <= valid1;
        valid3 <= valid2;
        valid4 <= valid3;
    end
end

// pipeline action
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        action1 <= '0;
        action2 <= '0;
        action3 <= '0;
        action4 <= '0;
    end else begin
        action1 <= i_action; 
        action2 <= action1; 
        action3 <= action2;
        action4 <= action3;
    end
end

// pipeline quantity
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        quantity1 <= '0;
        quantity2 <= '0;
        quantity3 <= '0;
    end else begin
        quantity1 <= i_quantity;
        quantity2 <= quantity1;
        quantity3 <= quantity2;
    end
end

// INDEX SETUP
// Cycle: Action
// 1: set the price diff
// 2: set the index
// NOTE: cycle 1 and 2 is for setup, so starting 3 is where everything start
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        price_diff <= '0;
        index2 <= '0;
        index3 <= '0;
        index4 <= '0;
    end else begin
        price_diff <= i_price - BASE_PRICE;  
        index2 <= price_diff / 100; 
        index3 <= index2;
        index4 <= index3;
    end
end

// FLB SETUP - PRICE
// cycle: action
// 3: get the old_qty from the FLB
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        old_qty3 <= '0;
        new_qty4 <= '0;
    end else begin
        if(valid_table[index2])
            old_qty3 <= FLB[index2];
        else 
            old_qty3 <= '0;
        if(valid4 && (index4 == index3))begin
            if(action3 == ADD)
                new_qty4 <= new_qty4 + quantity3;
            else 
                new_qty4 <= new_qty4 - quantity3;
        end else begin
            if(action3 == ADD)
                new_qty4 <= old_qty3 + quantity3;
            else 
                new_qty4 <= old_qty3 - quantity3;
        end
    end
end

always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(valid4) begin
        FLB[index4] <= new_qty4;
    end
end


// VALID TABLE
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        valid_table <= '0;
    end else if(action4 == ADD && valid4) begin
        valid_table[index4] <= 1;
    end else if(action4 != ADD && new_qty4 == 0 && valid4) begin
        valid_table[index4] <= 0;
    end
end

//TODO: above are correct and tested 
//TODO: think splittig the flb into 2 different module (bid&ask) above can stay the same
// make this one bid

// CACHE
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        for(int i = 0; i < FLB_CACHE_LEVEL; i++) begin
            cache[i].valid <= 1'b0;
            cache[i].index <= '0;
            cache[i].quantity <= '0;
        end
    end else if(cache_hit4) begin
        if(new_qty4 == 0) begin
            for(int i = hit_pos4; i < FLB_CACHE_LEVEL-1; i++) begin
                cache[i] <= cache[i+1];
            end 
            cache[FLB_CACHE_LEVEL-1].valid <= 1'b0;
            cache_valid_table[index4] <= 1'b0;
            last_valid5 <= last_valid5 - 1'b1;
            epoch5 <= epoch5 + 1'b1;
        end else begin
            cache[hit_pos4].valid <= 1'b1;
            cache[hit_pos4].quantity <= new_qty4;
        end
    end else if(add_2_cache) begin
        for(int i = FLB_CACHE_LEVEL-1; i > add_pos4; i--) begin
            cache[i] <= cache[i-1];
        end
        cache[add_pos4].valid <= 1'b1;
        cache[add_pos4].index <= index4;
        cache[add_pos4].quantity <= new_qty4;
    end
end

// cache hit
always_comb begin
    cache_hit4 = 0;
    hit_pos4 = '0;
    add_2_cache = valid4 && ((!cache[FLB_CACHE_LEVEL-1].valid)
                            ||(index4 > cache[FLB_CACHE_LEVEL-1].index));
    add_pos4 = FLB_CACHE_LEVEL-1;
    for(int i = 0; i < FLB_CACHE_LEVEL; i++) begin
        if(cache[i].valid && (cache[i].index == index4) && valid4) begin
            cache_hit4 = 1'b1;
            hit_pos4 = i;
        end
    end
    for(int i = FLB_CACHE_LEVEL-2; i >= 0; i--) begin
        if(!cache[i].valid || (index4 > cache[i].index))
            add_pos4 = i;
    end
end

endmodule