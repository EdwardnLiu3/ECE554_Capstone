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
    logic [$clog2(NUM_LEVELS)-1:0] index2;
    logic [PRICE_LEN-1:0] price_diff;
    flb_cache_packet_t cache [0:FLB_CACHE_LEVEL-1];
    (* ram_style = "block" *) logic [QUANTITY_LEN-1:0] FLB [0:NUM_LEVELS];
    logic [NUM_LEVELS:0] valid_table;
    logic [1:0] action1, action2, action3;
    logic [QUANTITY_LEN-1:0] quantity1, quantity2;
    logic [QUANTITY_LEN-1:0] old_qty2, new_qty3;
    logic valid1, valid2, valid3;
    

    always_ff @(posedge i_clk, negedge i_rst_n) begin
        if(!i_rst_n) begin
            old_qty2 <= '0;
            new_qty2 <= '0;
        end else begin
            old_qty2 <= FLB[index2];
            if(action2 == ADD) 
                new_qty3 <= old_qty2 + quantity2;
            else 
                new_qty3 <= old_qty2 - quantity2;
        end
    end

    always_ff @(posedge i_clk, negedge i_rst_n) begin
        if(!i_rst_n) begin
            price_diff <= '0;
            index2 <= '0;
            index3 <= '0;
        end else begin
            price_diff <= i_price - BASE_PRICE;  // pipe1
            index2 <= price_diff / 10 + 1; // pipe2
            index3 <= index2;
        end
    end

    always_ff @(posedge i_clk, negedge i_rst_n) begin
        if(!i_rst_n) begin
            valid1 <= 0;
            valid2 <= 0;
            valid3 <= 0;
        end else begin
            valid1 <= i_valid;
            valid2 <= valid1;
            valid3 <= valid2;
        end
    end

    always_ff @(posedge i_clk, negedge i_rst_n) begin
        if(!i_rst_n) begin
            action1 <= '0;
            action2 <= '0;
        end else begin
            aciton1 <= i_action; // pipe1
            action2 <= action1; // pipe2
            action3 <= action2;
        end
    end

    always_ff @(posedge i_clk, negedge i_rst_n) begin
        if(!rst_n) begin
            quantity1 <= '0;
            quantity2 <= '0;
        end else begin
            quantity1 <= i_quantity;
            quantity2 <= quantity1;
        end
    end
    
    always_ff @(posedge i_clk, negedge i_rst_n) begin
        if(valid3) begin
            FLB[index3] <= new_qty3;
        end
    end

    always_ff @(posedge i_clk, negedge i_rst_n) begin
        if(!i_rst_n) begin
            valid_table <= '0;
        end else if(action3 == ADD && valid3)begin
            valid_table[index3] <= 1;
        end else if(action3 != ADD && new_qty3 == 0 && valid3) begin
            valid_table[index3] <= 0;
        end
    end

endmodule