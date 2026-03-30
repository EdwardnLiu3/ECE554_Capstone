module Order_Generator 
#(parameter ORDER_ID_LEN = 32, parameter QUANTITY_LEN = 32, parameter PRICE_LEN = 64, parameter SYMBOL_LEN = 64)
(
    input                       i_clk,
    input                       i_rst_n,
    input [SYMBOL_LEN-1:0]      i_symbol,
    input [ORDER_ID_LEN-1:0]    i_old_order_num_buy,
    input [ORDER_ID_LEN-1:0]    i_old_order_num_sell,
    input                       i_old_order_executed_buy, //1 is executed, 0 is not
    input                       i_old_order_executed_sell, //1 is executed, 0 is not
    input [SYMBOL_LEN-1:0]      i_old_symbol_buy,
    input [SYMBOL_LEN-1:0]      i_old_symbol_sell,
    input [PRICE_LEN-1:0]       i_price_buy,
    input [PRICE_LEN-1:0]       i_price_sell,
    input [QUANTITY_LEN-1:0]    i_quantity_buy,
    input [QUANTITY_LEN-1:0]    i_quantity_sell,
    input                       i_valid_buy,
    input                       i_valid_sell,
    output [QUANTITY_LEN-1:0]   o_quantity_buy,
    output [QUANTITY_LEN-1:0]   o_quantity_sell,
    output [PRICE_LEN-1:0]      o_price_buy,
    output [PRICE_LEN-1:0]      o_price_sell,
    output [ORDER_ID_LEN-1:0]   o_new_order_num_buy,
    output [ORDER_ID_LEN-1:0]   o_new_order_num_sell,
    output [751:0]              o_payload
);



logic [QUANTITY_LEN-1:0] quantity_buy_ff;
logic [QUANTITY_LEN-1:0] quantity_sell_ff;
logic [PRICE_LEN-1:0] price_buy_ff;
logic [PRICE_LEN-1:0] price_sell_ff;
logic [ORDER_ID_LEN-1:0] new_order_num_buy_ff;
logic [ORDER_ID_LEN-1:0] new_order_num_sell_ff;
logic [751:0] payload_ff;

assign o_quantity_buy = quantity_buy_ff;
assign o_quantity_sell = quantity_sell_ff;
assign o_price_buy = price_buy_ff;
assign o_price_sell = price_sell_ff;
assign o_new_order_num_buy = new_order_num_buy_ff;
assign o_new_order_num_sell = new_order_num_sell_ff;
assign o_payload = payload_ff;

logic [30:0] new_order_counter; //buy ends in 0 sell ends in 1

always @(posedge i_clk, negedge i_rst_n) begin //counter for new orders
    if(!i_rst_n)begin
        new_order_counter = '0;
    end
    else begin
        new_order_counter = new_order_counter + 1'b1;
    end
end

always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n)begin
        payload_ff <= '0;
        quantity_buy_ff <= '0;
        quantity_sell_ff <= '0;
        price_buy_ff <= '0;
        price_sell_ff <= '0;
        new_order_num_buy_ff <= '0;
        new_order_num_sell_ff <= '0;
    end
    else if((!i_valid_buy || i_old_order_executed_buy) && (!i_valid_sell || i_old_order_executed_sell))begin //both new orders
        payload_ff <= {
            8'h4F,                                                          //Type  
            new_order_counter, 1'b0,                                        //UserRefNum
            8'h42,                                                          //Side
            32'h0000_0064,                                                  //Quantity
            i_symbol,                                                       //Symbol
            i_price_buy,                                                    //Price
            168'h00_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000,      //Padding
            8'h4f,                                                          //Type
            new_order_counter, 1'b1,                                        //UserRefNum
            8'h53,                                                          //Side
            32'h0000_0064,                                                  //Quantity
            i_symbol,                                                       //Symobol
            i_price_sell,                                                   //Price
            168'h00_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000       //Padding
            };
        quantity_buy_ff <= 32'h0000_0064;
        quantity_sell_ff <= 32'h0000_0064;
        price_buy_ff <= i_price_buy;
        price_sell_ff <= i_price_sell;
        new_order_num_buy_ff <= {new_order_counter, 1'b0};
        new_order_num_sell_ff <= {new_order_counter, 1'b1};
    end
    else if((!i_valid_buy || i_old_order_executed_buy) && (i_valid_sell && !i_old_order_executed_sell))begin //new buy old sell
        payload_ff <= {
            8'h4F,                                                          //Type  
            new_order_counter, 1'b0,                                        //UserRefNum
            8'h42,                                                          //Side
            32'h0000_0064,                                                  //Quantity
            i_symbol,                                                       //Symbol
            i_price_buy,                                                    //Price
            168'h00_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000,      //Padding
            8'h55,                                                          //Type
            i_old_order_num_sell,                                           //OrigUserRefNum
            new_order_counter, 1'b1,                                        //UserRefNum
            32'h0000_0064,                                                  //Quantity
            i_price_sell,                                                   //Price
            152'h00_0000_0000_0000_0000_0000_0000_0000_0000_0000            //Padding
        };
        quantity_buy_ff <= 32'h0000_0064;
        quantity_sell_ff <= 32'h0000_0064;
        price_buy_ff <= i_price_buy;
        price_sell_ff <= i_price_sell;
        new_order_num_buy_ff <= {new_order_counter, 1'b0};
        new_order_num_sell_ff <= {new_order_counter, 1'b1};
    end
    else if((i_valid_buy && !i_old_order_executed_buy) && (!i_valid_sell || i_old_order_executed_sell))begin //old buy new sell
        payload_ff <= {
            8'h55,                                                          //Type
            i_old_order_num_buy,                                           //OrigUserRefNum
            new_order_counter, 1'b1,                                        //UserRefNum
            32'h0000_0064,                                                  //Quantity
            i_price_buy,                                                    //Price
            152'h00_0000_0000_0000_0000_0000_0000_0000_0000_0000,           //Padding
            8'h4f,                                                          //Type
            new_order_counter, 1'b1,                                        //UserRefNum
            8'h53,                                                          //Side
            32'h0000_0064,                                                  //Quantity
            i_symbol,                                                       //Symobol
            i_price_sell,                                                   //Price
            168'h00_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000       //Padding
        };
        quantity_buy_ff <= 32'h0000_0064;
        quantity_sell_ff <= 32'h0000_0064;
        price_buy_ff <= i_price_buy;
        price_sell_ff <= i_price_sell;
        new_order_num_buy_ff <= {new_order_counter, 1'b0};
        new_order_num_sell_ff <= {new_order_counter, 1'b1};
    end
    else if((i_valid_buy && !i_old_order_executed_buy) && (i_valid_sell && !i_old_order_executed_sell))begin//both old
        payload_ff <= {
            8'h55,                                                          //Type
            i_old_order_num_buy,                                           //OrigUserRefNum
            new_order_counter, 1'b1,                                        //UserRefNum
            32'h0000_0064,                                                  //Quantity
            i_price_buy,                                                    //Price
            152'h00_0000_0000_0000_0000_0000_0000_0000_0000_0000,           //Padding
            8'h55,                                                          //Type
            i_old_order_num_sell,                                           //OrigUserRefNum
            new_order_counter, 1'b1,                                        //UserRefNum
            32'h0000_0064,                                                  //Quantity
            i_price_sell,                                                   //Price
            152'h00_0000_0000_0000_0000_0000_0000_0000_0000_0000            //Padding
        };
        quantity_buy_ff <= 32'h0000_0064;
        quantity_sell_ff <= 32'h0000_0064;
        price_buy_ff <= i_price_buy;
        price_sell_ff <= i_price_sell;
        new_order_num_buy_ff <= {new_order_counter, 1'b0};
        new_order_num_sell_ff <= {new_order_counter, 1'b1};
    end
end

endmodule