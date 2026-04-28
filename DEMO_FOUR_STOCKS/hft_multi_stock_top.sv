import ob_pkg::*;
module hft_multi_stock_top #(
    parameter int MARKET_PAYLOAD_LEN = 288,
    parameter int OUCH_PAYLOAD_LEN   = 752,
    parameter int SYMBOL_LEN         = 64,
    parameter int POSITION_LEN       = 16,
    parameter int PNL_LEN            = 64,
    parameter int STOCK_LEN          = 16,
    parameter int MARKET_QTY_LEN     = 32,
    parameter int AAPL_BOOK_BASE_PRICE = 32'd5_820_000,
    parameter int AMZN_BOOK_BASE_PRICE = 32'd2_220_000,
    parameter int INTC_BOOK_BASE_PRICE = 32'd265_000,
    parameter int MSFT_BOOK_BASE_PRICE = 32'd303_000,
    parameter logic [SYMBOL_LEN-1:0] AAPL_SYMBOL = {"A","A","P","L"," "," "," "," "},
    parameter logic [SYMBOL_LEN-1:0] AMZN_SYMBOL = {"A","M","Z","N"," "," "," "," "},
    parameter logic [SYMBOL_LEN-1:0] INTC_SYMBOL = {"I","N","T","C"," "," "," "," "},
    parameter logic [SYMBOL_LEN-1:0] MSFT_SYMBOL = {"M","S","F","T"," "," "," "," "}
) (
    input  logic                            i_clk,
    input  logic                            i_rst_n,
    input  logic [ORDERID_LEN-1:0]          i_order_id,
    input  logic [QUANTITY_LEN-1:0]         i_quantity,
    input  logic                            i_side,
    input  logic [PRICE_LEN-1:0]            i_price,
    input  logic [1:0]                      i_action,
    input  logic                            i_valid,
    input  logic [STOCK_LEN-1:0]            i_stock_id,
    input  logic [47:0]                     i_timestamp,
    input  logic [TOT_QUATITY_LEN-1:0]      i_bid_quote_quantity,
    input  logic [TOT_QUATITY_LEN-1:0]      i_ask_quote_quantity,
    input  logic                            i_trading_enable,
    input  logic                            i_kill_switch,
    input  logic                            i_price_band_enable,
    input  logic                            i_pnl_check_enable,

    output logic [STOCK_LEN-1:0]            o_stock_id,
    output logic [FULL_PRICE_LEN-1:0]       o_best_bid_price,
    output logic [FULL_PRICE_LEN-1:0]       o_best_ask_price,
    output logic                            o_best_bid_valid,
    output logic                            o_best_ask_valid,
    output logic [FULL_PRICE_LEN-1:0]       o_trading_bid_price,
    output logic [FULL_PRICE_LEN-1:0]       o_trading_ask_price,
    output logic [1:0]                      o_trading_order_type,
    output logic                            o_trading_valid,
    output logic                            o_bid_reject_valid,
    output logic [3:0]                      o_bid_reject_reason,
    output logic                            o_ask_reject_valid,
    output logic [3:0]                      o_ask_reject_reason,
    output logic                            o_order_payload_valid,
    output logic [OUCH_PAYLOAD_LEN-1:0]     o_order_payload,
    output logic                            o_exec_valid,
    output logic                            o_exec_side,
    output logic [FULL_PRICE_LEN-1:0]       o_exec_price,
    output logic [TOT_QUATITY_LEN-1:0]      o_exec_quantity,
    output logic [ORDERID_LEN-1:0]          o_exec_order_id,
    output logic signed [POSITION_LEN-1:0]  o_position,
    output logic signed [PNL_LEN-1:0]       o_day_pnl,
    output logic [TOT_QUATITY_LEN-1:0]      o_live_bid_qty,
    output logic [TOT_QUATITY_LEN-1:0]      o_live_ask_qty,

    output logic [63:0]                     o_debug_parser_order_id,
    output logic [31:0]                     o_debug_parser_quantity,
    output logic                            o_debug_parser_side,
    output logic [31:0]                     o_debug_parser_price,
    output logic [1:0]                      o_debug_parser_action,
    output logic                            o_debug_parser_valid,
    output logic [STOCK_LEN-1:0]            o_debug_parser_stock_id,
    output logic [47:0]                     o_debug_parser_timestamp,
    output logic [ORDERID_LEN-1:0]          o_debug_ob_in_order_id,
    output logic [PRICE_LEN-1:0]            o_debug_ob_in_price,
    output logic [QUANTITY_LEN-1:0]         o_debug_ob_in_quantity,
    output logic [1:0]                      o_debug_ob_in_action,
    output logic                            o_debug_ob_in_valid,
    output logic                            o_debug_ob_in_side,
    output logic [1:0]                      o_debug_ob_event_action,
    output logic [PRICE_LEN-1:0]            o_debug_ob_event_price,
    output logic [QUANTITY_LEN-1:0]         o_debug_ob_event_quantity,
    output logic                            o_debug_ob_event_valid,
    output logic                            o_debug_ob_event_side,
    output logic [TOT_QUATITY_LEN-1:0]      o_debug_best_bid_quantity,
    output logic [TOT_QUATITY_LEN-1:0]      o_debug_best_ask_quantity
);

logic [STOCK_LEN-1:0]           selected_stock_id;

logic [STOCK_LEN-1:0]           stock_id_1;
logic [FULL_PRICE_LEN-1:0]      best_bid_price_1;
logic [FULL_PRICE_LEN-1:0]      best_ask_price_1;
logic                           best_bid_valid_1;
logic                           best_ask_valid_1;
logic [FULL_PRICE_LEN-1:0]      trading_bid_price_1;
logic [FULL_PRICE_LEN-1:0]      trading_ask_price_1;
logic [1:0]                     trading_order_type_1;
logic                           trading_valid_1;
logic                           bid_reject_valid_1;
logic [3:0]                     bid_reject_reason_1;
logic                           ask_reject_valid_1;
logic [3:0]                     ask_reject_reason_1;
logic                           order_payload_valid_1;
logic [OUCH_PAYLOAD_LEN-1:0]    order_payload_1;
logic                           exec_valid_1;
logic                           exec_side_1;
logic [FULL_PRICE_LEN-1:0]      exec_price_1;
logic [TOT_QUATITY_LEN-1:0]     exec_quantity_1;
logic [ORDERID_LEN-1:0]         exec_order_id_1;
logic signed [POSITION_LEN-1:0] position_1;
logic signed [PNL_LEN-1:0]      day_pnl_1;
logic [TOT_QUATITY_LEN-1:0]     live_bid_qty_1;
logic [TOT_QUATITY_LEN-1:0]     live_ask_qty_1;
logic [ORDERID_LEN-1:0]         debug_ob_in_order_id_1;
logic [PRICE_LEN-1:0]           debug_ob_in_price_1;
logic [QUANTITY_LEN-1:0]        debug_ob_in_quantity_1;
logic [1:0]                     debug_ob_in_action_1;
logic                           debug_ob_in_valid_1;
logic                           debug_ob_in_side_1;
logic [1:0]                     debug_ob_event_action_1;
logic [PRICE_LEN-1:0]           debug_ob_event_price_1;
logic [QUANTITY_LEN-1:0]        debug_ob_event_quantity_1;
logic                           debug_ob_event_valid_1;
logic                           debug_ob_event_side_1;
logic [TOT_QUATITY_LEN-1:0]     debug_best_bid_quantity_1;
logic [TOT_QUATITY_LEN-1:0]     debug_best_ask_quantity_1;

logic [STOCK_LEN-1:0]           stock_id_2;
logic [FULL_PRICE_LEN-1:0]      best_bid_price_2;
logic [FULL_PRICE_LEN-1:0]      best_ask_price_2;
logic                           best_bid_valid_2;
logic                           best_ask_valid_2;
logic [FULL_PRICE_LEN-1:0]      trading_bid_price_2;
logic [FULL_PRICE_LEN-1:0]      trading_ask_price_2;
logic [1:0]                     trading_order_type_2;
logic                           trading_valid_2;
logic                           bid_reject_valid_2;
logic [3:0]                     bid_reject_reason_2;
logic                           ask_reject_valid_2;
logic [3:0]                     ask_reject_reason_2;
logic                           order_payload_valid_2;
logic [OUCH_PAYLOAD_LEN-1:0]    order_payload_2;
logic                           exec_valid_2;
logic                           exec_side_2;
logic [FULL_PRICE_LEN-1:0]      exec_price_2;
logic [TOT_QUATITY_LEN-1:0]     exec_quantity_2;
logic [ORDERID_LEN-1:0]         exec_order_id_2;
logic signed [POSITION_LEN-1:0] position_2;
logic signed [PNL_LEN-1:0]      day_pnl_2;
logic [TOT_QUATITY_LEN-1:0]     live_bid_qty_2;
logic [TOT_QUATITY_LEN-1:0]     live_ask_qty_2;
logic [ORDERID_LEN-1:0]         debug_ob_in_order_id_2;
logic [PRICE_LEN-1:0]           debug_ob_in_price_2;
logic [QUANTITY_LEN-1:0]        debug_ob_in_quantity_2;
logic [1:0]                     debug_ob_in_action_2;
logic                           debug_ob_in_valid_2;
logic                           debug_ob_in_side_2;
logic [1:0]                     debug_ob_event_action_2;
logic [PRICE_LEN-1:0]           debug_ob_event_price_2;
logic [QUANTITY_LEN-1:0]        debug_ob_event_quantity_2;
logic                           debug_ob_event_valid_2;
logic                           debug_ob_event_side_2;
logic [TOT_QUATITY_LEN-1:0]     debug_best_bid_quantity_2;
logic [TOT_QUATITY_LEN-1:0]     debug_best_ask_quantity_2;

logic [STOCK_LEN-1:0]           stock_id_3;
logic [FULL_PRICE_LEN-1:0]      best_bid_price_3;
logic [FULL_PRICE_LEN-1:0]      best_ask_price_3;
logic                           best_bid_valid_3;
logic                           best_ask_valid_3;
logic [FULL_PRICE_LEN-1:0]      trading_bid_price_3;
logic [FULL_PRICE_LEN-1:0]      trading_ask_price_3;
logic [1:0]                     trading_order_type_3;
logic                           trading_valid_3;
logic                           bid_reject_valid_3;
logic [3:0]                     bid_reject_reason_3;
logic                           ask_reject_valid_3;
logic [3:0]                     ask_reject_reason_3;
logic                           order_payload_valid_3;
logic [OUCH_PAYLOAD_LEN-1:0]    order_payload_3;
logic                           exec_valid_3;
logic                           exec_side_3;
logic [FULL_PRICE_LEN-1:0]      exec_price_3;
logic [TOT_QUATITY_LEN-1:0]     exec_quantity_3;
logic [ORDERID_LEN-1:0]         exec_order_id_3;
logic signed [POSITION_LEN-1:0] position_3;
logic signed [PNL_LEN-1:0]      day_pnl_3;
logic [TOT_QUATITY_LEN-1:0]     live_bid_qty_3;
logic [TOT_QUATITY_LEN-1:0]     live_ask_qty_3;
logic [ORDERID_LEN-1:0]         debug_ob_in_order_id_3;
logic [PRICE_LEN-1:0]           debug_ob_in_price_3;
logic [QUANTITY_LEN-1:0]        debug_ob_in_quantity_3;
logic [1:0]                     debug_ob_in_action_3;
logic                           debug_ob_in_valid_3;
logic                           debug_ob_in_side_3;
logic [1:0]                     debug_ob_event_action_3;
logic [PRICE_LEN-1:0]           debug_ob_event_price_3;
logic [QUANTITY_LEN-1:0]        debug_ob_event_quantity_3;
logic                           debug_ob_event_valid_3;
logic                           debug_ob_event_side_3;
logic [TOT_QUATITY_LEN-1:0]     debug_best_bid_quantity_3;
logic [TOT_QUATITY_LEN-1:0]     debug_best_ask_quantity_3;

logic [STOCK_LEN-1:0]           stock_id_4;
logic [FULL_PRICE_LEN-1:0]      best_bid_price_4;
logic [FULL_PRICE_LEN-1:0]      best_ask_price_4;
logic                           best_bid_valid_4;
logic                           best_ask_valid_4;
logic [FULL_PRICE_LEN-1:0]      trading_bid_price_4;
logic [FULL_PRICE_LEN-1:0]      trading_ask_price_4;
logic [1:0]                     trading_order_type_4;
logic                           trading_valid_4;
logic                           bid_reject_valid_4;
logic [3:0]                     bid_reject_reason_4;
logic                           ask_reject_valid_4;
logic [3:0]                     ask_reject_reason_4;
logic                           order_payload_valid_4;
logic [OUCH_PAYLOAD_LEN-1:0]    order_payload_4;
logic                           exec_valid_4;
logic                           exec_side_4;
logic [FULL_PRICE_LEN-1:0]      exec_price_4;
logic [TOT_QUATITY_LEN-1:0]     exec_quantity_4;
logic [ORDERID_LEN-1:0]         exec_order_id_4;
logic signed [POSITION_LEN-1:0] position_4;
logic signed [PNL_LEN-1:0]      day_pnl_4;
logic [TOT_QUATITY_LEN-1:0]     live_bid_qty_4;
logic [TOT_QUATITY_LEN-1:0]     live_ask_qty_4;
logic [ORDERID_LEN-1:0]         debug_ob_in_order_id_4;
logic [PRICE_LEN-1:0]           debug_ob_in_price_4;
logic [QUANTITY_LEN-1:0]        debug_ob_in_quantity_4;
logic [1:0]                     debug_ob_in_action_4;
logic                           debug_ob_in_valid_4;
logic                           debug_ob_in_side_4;
logic [1:0]                     debug_ob_event_action_4;
logic [PRICE_LEN-1:0]           debug_ob_event_price_4;
logic [QUANTITY_LEN-1:0]        debug_ob_event_quantity_4;
logic                           debug_ob_event_valid_4;
logic                           debug_ob_event_side_4;
logic [TOT_QUATITY_LEN-1:0]     debug_best_bid_quantity_4;
logic [TOT_QUATITY_LEN-1:0]     debug_best_ask_quantity_4;

always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
        selected_stock_id <= STOCK_LEN'(1);
    else if (i_valid && (i_stock_id >= STOCK_LEN'(1)) && (i_stock_id <= STOCK_LEN'(4)))
        selected_stock_id <= i_stock_id;
end

hft_single_stock_top #(
    .MARKET_PAYLOAD_LEN(MARKET_PAYLOAD_LEN),
    .OUCH_PAYLOAD_LEN(OUCH_PAYLOAD_LEN),
    .SYMBOL_LEN(SYMBOL_LEN),
    .POSITION_LEN(POSITION_LEN),
    .PNL_LEN(PNL_LEN),
    .STOCK_LEN(STOCK_LEN),
    .MARKET_QTY_LEN(MARKET_QTY_LEN),
    .BOOK_BASE_PRICE(AAPL_BOOK_BASE_PRICE)
) stock_1_inst (
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_order_id(i_order_id),
    .i_quantity(i_quantity),
    .i_side(i_side),
    .i_price(i_price),
    .i_action(i_action),
    .i_valid(i_valid && (i_stock_id == STOCK_LEN'(1))),
    .i_stock_id(i_stock_id),
    .i_symbol(AAPL_SYMBOL),
    .i_timestamp(i_timestamp),
    .i_bid_quote_quantity(i_bid_quote_quantity),
    .i_ask_quote_quantity(i_ask_quote_quantity),
    .i_trading_enable(i_trading_enable),
    .i_kill_switch(i_kill_switch),
    .i_price_band_enable(i_price_band_enable),
    .i_pnl_check_enable(i_pnl_check_enable),
    .o_stock_id(stock_id_1),
    .o_best_bid_price(best_bid_price_1),
    .o_best_ask_price(best_ask_price_1),
    .o_best_bid_valid(best_bid_valid_1),
    .o_best_ask_valid(best_ask_valid_1),
    .o_trading_bid_price(trading_bid_price_1),
    .o_trading_ask_price(trading_ask_price_1),
    .o_trading_order_type(trading_order_type_1),
    .o_trading_valid(trading_valid_1),
    .o_bid_reject_valid(bid_reject_valid_1),
    .o_bid_reject_reason(bid_reject_reason_1),
    .o_ask_reject_valid(ask_reject_valid_1),
    .o_ask_reject_reason(ask_reject_reason_1),
    .o_order_payload_valid(order_payload_valid_1),
    .o_order_payload(order_payload_1),
    .o_exec_valid(exec_valid_1),
    .o_exec_side(exec_side_1),
    .o_exec_price(exec_price_1),
    .o_exec_quantity(exec_quantity_1),
    .o_exec_order_id(exec_order_id_1),
    .o_position(position_1),
    .o_day_pnl(day_pnl_1),
    .o_live_bid_qty(live_bid_qty_1),
    .o_live_ask_qty(live_ask_qty_1),
    .o_debug_parser_order_id(),
    .o_debug_parser_quantity(),
    .o_debug_parser_side(),
    .o_debug_parser_price(),
    .o_debug_parser_action(),
    .o_debug_parser_valid(),
    .o_debug_parser_stock_id(),
    .o_debug_parser_timestamp(),
    .o_debug_ob_in_order_id(debug_ob_in_order_id_1),
    .o_debug_ob_in_price(debug_ob_in_price_1),
    .o_debug_ob_in_quantity(debug_ob_in_quantity_1),
    .o_debug_ob_in_action(debug_ob_in_action_1),
    .o_debug_ob_in_valid(debug_ob_in_valid_1),
    .o_debug_ob_in_side(debug_ob_in_side_1),
    .o_debug_ob_event_action(debug_ob_event_action_1),
    .o_debug_ob_event_price(debug_ob_event_price_1),
    .o_debug_ob_event_quantity(debug_ob_event_quantity_1),
    .o_debug_ob_event_valid(debug_ob_event_valid_1),
    .o_debug_ob_event_side(debug_ob_event_side_1),
    .o_debug_best_bid_quantity(debug_best_bid_quantity_1),
    .o_debug_best_ask_quantity(debug_best_ask_quantity_1)
);

hft_single_stock_top #(
    .MARKET_PAYLOAD_LEN(MARKET_PAYLOAD_LEN),
    .OUCH_PAYLOAD_LEN(OUCH_PAYLOAD_LEN),
    .SYMBOL_LEN(SYMBOL_LEN),
    .POSITION_LEN(POSITION_LEN),
    .PNL_LEN(PNL_LEN),
    .STOCK_LEN(STOCK_LEN),
    .MARKET_QTY_LEN(MARKET_QTY_LEN),
    .BOOK_BASE_PRICE(AMZN_BOOK_BASE_PRICE)
) stock_2_inst (
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_order_id(i_order_id),
    .i_quantity(i_quantity),
    .i_side(i_side),
    .i_price(i_price),
    .i_action(i_action),
    .i_valid(i_valid && (i_stock_id == STOCK_LEN'(2))),
    .i_stock_id(i_stock_id),
    .i_symbol(AMZN_SYMBOL),
    .i_timestamp(i_timestamp),
    .i_bid_quote_quantity(i_bid_quote_quantity),
    .i_ask_quote_quantity(i_ask_quote_quantity),
    .i_trading_enable(i_trading_enable),
    .i_kill_switch(i_kill_switch),
    .i_price_band_enable(i_price_band_enable),
    .i_pnl_check_enable(i_pnl_check_enable),
    .o_stock_id(stock_id_2),
    .o_best_bid_price(best_bid_price_2),
    .o_best_ask_price(best_ask_price_2),
    .o_best_bid_valid(best_bid_valid_2),
    .o_best_ask_valid(best_ask_valid_2),
    .o_trading_bid_price(trading_bid_price_2),
    .o_trading_ask_price(trading_ask_price_2),
    .o_trading_order_type(trading_order_type_2),
    .o_trading_valid(trading_valid_2),
    .o_bid_reject_valid(bid_reject_valid_2),
    .o_bid_reject_reason(bid_reject_reason_2),
    .o_ask_reject_valid(ask_reject_valid_2),
    .o_ask_reject_reason(ask_reject_reason_2),
    .o_order_payload_valid(order_payload_valid_2),
    .o_order_payload(order_payload_2),
    .o_exec_valid(exec_valid_2),
    .o_exec_side(exec_side_2),
    .o_exec_price(exec_price_2),
    .o_exec_quantity(exec_quantity_2),
    .o_exec_order_id(exec_order_id_2),
    .o_position(position_2),
    .o_day_pnl(day_pnl_2),
    .o_live_bid_qty(live_bid_qty_2),
    .o_live_ask_qty(live_ask_qty_2),
    .o_debug_parser_order_id(),
    .o_debug_parser_quantity(),
    .o_debug_parser_side(),
    .o_debug_parser_price(),
    .o_debug_parser_action(),
    .o_debug_parser_valid(),
    .o_debug_parser_stock_id(),
    .o_debug_parser_timestamp(),
    .o_debug_ob_in_order_id(debug_ob_in_order_id_2),
    .o_debug_ob_in_price(debug_ob_in_price_2),
    .o_debug_ob_in_quantity(debug_ob_in_quantity_2),
    .o_debug_ob_in_action(debug_ob_in_action_2),
    .o_debug_ob_in_valid(debug_ob_in_valid_2),
    .o_debug_ob_in_side(debug_ob_in_side_2),
    .o_debug_ob_event_action(debug_ob_event_action_2),
    .o_debug_ob_event_price(debug_ob_event_price_2),
    .o_debug_ob_event_quantity(debug_ob_event_quantity_2),
    .o_debug_ob_event_valid(debug_ob_event_valid_2),
    .o_debug_ob_event_side(debug_ob_event_side_2),
    .o_debug_best_bid_quantity(debug_best_bid_quantity_2),
    .o_debug_best_ask_quantity(debug_best_ask_quantity_2)
);

hft_single_stock_top #(
    .MARKET_PAYLOAD_LEN(MARKET_PAYLOAD_LEN),
    .OUCH_PAYLOAD_LEN(OUCH_PAYLOAD_LEN),
    .SYMBOL_LEN(SYMBOL_LEN),
    .POSITION_LEN(POSITION_LEN),
    .PNL_LEN(PNL_LEN),
    .STOCK_LEN(STOCK_LEN),
    .MARKET_QTY_LEN(MARKET_QTY_LEN),
    .BOOK_BASE_PRICE(INTC_BOOK_BASE_PRICE)
) stock_3_inst (
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_order_id(i_order_id),
    .i_quantity(i_quantity),
    .i_side(i_side),
    .i_price(i_price),
    .i_action(i_action),
    .i_valid(i_valid && (i_stock_id == STOCK_LEN'(3))),
    .i_stock_id(i_stock_id),
    .i_symbol(INTC_SYMBOL),
    .i_timestamp(i_timestamp),
    .i_bid_quote_quantity(i_bid_quote_quantity),
    .i_ask_quote_quantity(i_ask_quote_quantity),
    .i_trading_enable(i_trading_enable),
    .i_kill_switch(i_kill_switch),
    .i_price_band_enable(i_price_band_enable),
    .i_pnl_check_enable(i_pnl_check_enable),
    .o_stock_id(stock_id_3),
    .o_best_bid_price(best_bid_price_3),
    .o_best_ask_price(best_ask_price_3),
    .o_best_bid_valid(best_bid_valid_3),
    .o_best_ask_valid(best_ask_valid_3),
    .o_trading_bid_price(trading_bid_price_3),
    .o_trading_ask_price(trading_ask_price_3),
    .o_trading_order_type(trading_order_type_3),
    .o_trading_valid(trading_valid_3),
    .o_bid_reject_valid(bid_reject_valid_3),
    .o_bid_reject_reason(bid_reject_reason_3),
    .o_ask_reject_valid(ask_reject_valid_3),
    .o_ask_reject_reason(ask_reject_reason_3),
    .o_order_payload_valid(order_payload_valid_3),
    .o_order_payload(order_payload_3),
    .o_exec_valid(exec_valid_3),
    .o_exec_side(exec_side_3),
    .o_exec_price(exec_price_3),
    .o_exec_quantity(exec_quantity_3),
    .o_exec_order_id(exec_order_id_3),
    .o_position(position_3),
    .o_day_pnl(day_pnl_3),
    .o_live_bid_qty(live_bid_qty_3),
    .o_live_ask_qty(live_ask_qty_3),
    .o_debug_parser_order_id(),
    .o_debug_parser_quantity(),
    .o_debug_parser_side(),
    .o_debug_parser_price(),
    .o_debug_parser_action(),
    .o_debug_parser_valid(),
    .o_debug_parser_stock_id(),
    .o_debug_parser_timestamp(),
    .o_debug_ob_in_order_id(debug_ob_in_order_id_3),
    .o_debug_ob_in_price(debug_ob_in_price_3),
    .o_debug_ob_in_quantity(debug_ob_in_quantity_3),
    .o_debug_ob_in_action(debug_ob_in_action_3),
    .o_debug_ob_in_valid(debug_ob_in_valid_3),
    .o_debug_ob_in_side(debug_ob_in_side_3),
    .o_debug_ob_event_action(debug_ob_event_action_3),
    .o_debug_ob_event_price(debug_ob_event_price_3),
    .o_debug_ob_event_quantity(debug_ob_event_quantity_3),
    .o_debug_ob_event_valid(debug_ob_event_valid_3),
    .o_debug_ob_event_side(debug_ob_event_side_3),
    .o_debug_best_bid_quantity(debug_best_bid_quantity_3),
    .o_debug_best_ask_quantity(debug_best_ask_quantity_3)
);

hft_single_stock_top #(
    .MARKET_PAYLOAD_LEN(MARKET_PAYLOAD_LEN),
    .OUCH_PAYLOAD_LEN(OUCH_PAYLOAD_LEN),
    .SYMBOL_LEN(SYMBOL_LEN),
    .POSITION_LEN(POSITION_LEN),
    .PNL_LEN(PNL_LEN),
    .STOCK_LEN(STOCK_LEN),
    .MARKET_QTY_LEN(MARKET_QTY_LEN),
    .BOOK_BASE_PRICE(MSFT_BOOK_BASE_PRICE)
) stock_4_inst (
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_order_id(i_order_id),
    .i_quantity(i_quantity),
    .i_side(i_side),
    .i_price(i_price),
    .i_action(i_action),
    .i_valid(i_valid && (i_stock_id == STOCK_LEN'(4))),
    .i_stock_id(i_stock_id),
    .i_symbol(MSFT_SYMBOL),
    .i_timestamp(i_timestamp),
    .i_bid_quote_quantity(i_bid_quote_quantity),
    .i_ask_quote_quantity(i_ask_quote_quantity),
    .i_trading_enable(i_trading_enable),
    .i_kill_switch(i_kill_switch),
    .i_price_band_enable(i_price_band_enable),
    .i_pnl_check_enable(i_pnl_check_enable),
    .o_stock_id(stock_id_4),
    .o_best_bid_price(best_bid_price_4),
    .o_best_ask_price(best_ask_price_4),
    .o_best_bid_valid(best_bid_valid_4),
    .o_best_ask_valid(best_ask_valid_4),
    .o_trading_bid_price(trading_bid_price_4),
    .o_trading_ask_price(trading_ask_price_4),
    .o_trading_order_type(trading_order_type_4),
    .o_trading_valid(trading_valid_4),
    .o_bid_reject_valid(bid_reject_valid_4),
    .o_bid_reject_reason(bid_reject_reason_4),
    .o_ask_reject_valid(ask_reject_valid_4),
    .o_ask_reject_reason(ask_reject_reason_4),
    .o_order_payload_valid(order_payload_valid_4),
    .o_order_payload(order_payload_4),
    .o_exec_valid(exec_valid_4),
    .o_exec_side(exec_side_4),
    .o_exec_price(exec_price_4),
    .o_exec_quantity(exec_quantity_4),
    .o_exec_order_id(exec_order_id_4),
    .o_position(position_4),
    .o_day_pnl(day_pnl_4),
    .o_live_bid_qty(live_bid_qty_4),
    .o_live_ask_qty(live_ask_qty_4),
    .o_debug_parser_order_id(),
    .o_debug_parser_quantity(),
    .o_debug_parser_side(),
    .o_debug_parser_price(),
    .o_debug_parser_action(),
    .o_debug_parser_valid(),
    .o_debug_parser_stock_id(),
    .o_debug_parser_timestamp(),
    .o_debug_ob_in_order_id(debug_ob_in_order_id_4),
    .o_debug_ob_in_price(debug_ob_in_price_4),
    .o_debug_ob_in_quantity(debug_ob_in_quantity_4),
    .o_debug_ob_in_action(debug_ob_in_action_4),
    .o_debug_ob_in_valid(debug_ob_in_valid_4),
    .o_debug_ob_in_side(debug_ob_in_side_4),
    .o_debug_ob_event_action(debug_ob_event_action_4),
    .o_debug_ob_event_price(debug_ob_event_price_4),
    .o_debug_ob_event_quantity(debug_ob_event_quantity_4),
    .o_debug_ob_event_valid(debug_ob_event_valid_4),
    .o_debug_ob_event_side(debug_ob_event_side_4),
    .o_debug_best_bid_quantity(debug_best_bid_quantity_4),
    .o_debug_best_ask_quantity(debug_best_ask_quantity_4)
);

always_comb begin
    o_stock_id = selected_stock_id;
    o_best_bid_price = '0;
    o_best_ask_price = '0;
    o_best_bid_valid = 1'b0;
    o_best_ask_valid = 1'b0;
    o_trading_bid_price = '0;
    o_trading_ask_price = '0;
    o_trading_order_type = 2'b00;
    o_trading_valid = 1'b0;
    o_position = '0;
    o_day_pnl = '0;
    o_live_bid_qty = '0;
    o_live_ask_qty = '0;
    o_debug_ob_in_order_id = '0;
    o_debug_ob_in_price = '0;
    o_debug_ob_in_quantity = '0;
    o_debug_ob_in_action = '0;
    o_debug_ob_in_valid = 1'b0;
    o_debug_ob_in_side = 1'b0;
    o_debug_ob_event_action = '0;
    o_debug_ob_event_price = '0;
    o_debug_ob_event_quantity = '0;
    o_debug_ob_event_valid = 1'b0;
    o_debug_ob_event_side = 1'b0;
    o_debug_best_bid_quantity = '0;
    o_debug_best_ask_quantity = '0;

    // When an event-producing sub-engine fires, expose that stock ID so the
    // Avalon wrapper can latch the true source of the payload/exec/reject.
    if (order_payload_valid_1 || exec_valid_1 || bid_reject_valid_1 || ask_reject_valid_1)
        o_stock_id = stock_id_1;
    else if (order_payload_valid_2 || exec_valid_2 || bid_reject_valid_2 || ask_reject_valid_2)
        o_stock_id = stock_id_2;
    else if (order_payload_valid_3 || exec_valid_3 || bid_reject_valid_3 || ask_reject_valid_3)
        o_stock_id = stock_id_3;
    else if (order_payload_valid_4 || exec_valid_4 || bid_reject_valid_4 || ask_reject_valid_4)
        o_stock_id = stock_id_4;

    case (selected_stock_id)
        STOCK_LEN'(1): begin
            o_best_bid_price = best_bid_price_1;
            o_best_ask_price = best_ask_price_1;
            o_best_bid_valid = best_bid_valid_1;
            o_best_ask_valid = best_ask_valid_1;
            o_trading_bid_price = trading_bid_price_1;
            o_trading_ask_price = trading_ask_price_1;
            o_trading_order_type = trading_order_type_1;
            o_trading_valid = trading_valid_1;
            o_position = position_1;
            o_day_pnl = day_pnl_1;
            o_live_bid_qty = live_bid_qty_1;
            o_live_ask_qty = live_ask_qty_1;
            o_debug_ob_in_order_id = debug_ob_in_order_id_1;
            o_debug_ob_in_price = debug_ob_in_price_1;
            o_debug_ob_in_quantity = debug_ob_in_quantity_1;
            o_debug_ob_in_action = debug_ob_in_action_1;
            o_debug_ob_in_valid = debug_ob_in_valid_1;
            o_debug_ob_in_side = debug_ob_in_side_1;
            o_debug_ob_event_action = debug_ob_event_action_1;
            o_debug_ob_event_price = debug_ob_event_price_1;
            o_debug_ob_event_quantity = debug_ob_event_quantity_1;
            o_debug_ob_event_valid = debug_ob_event_valid_1;
            o_debug_ob_event_side = debug_ob_event_side_1;
            o_debug_best_bid_quantity = debug_best_bid_quantity_1;
            o_debug_best_ask_quantity = debug_best_ask_quantity_1;
        end
        STOCK_LEN'(2): begin
            o_best_bid_price = best_bid_price_2;
            o_best_ask_price = best_ask_price_2;
            o_best_bid_valid = best_bid_valid_2;
            o_best_ask_valid = best_ask_valid_2;
            o_trading_bid_price = trading_bid_price_2;
            o_trading_ask_price = trading_ask_price_2;
            o_trading_order_type = trading_order_type_2;
            o_trading_valid = trading_valid_2;
            o_position = position_2;
            o_day_pnl = day_pnl_2;
            o_live_bid_qty = live_bid_qty_2;
            o_live_ask_qty = live_ask_qty_2;
            o_debug_ob_in_order_id = debug_ob_in_order_id_2;
            o_debug_ob_in_price = debug_ob_in_price_2;
            o_debug_ob_in_quantity = debug_ob_in_quantity_2;
            o_debug_ob_in_action = debug_ob_in_action_2;
            o_debug_ob_in_valid = debug_ob_in_valid_2;
            o_debug_ob_in_side = debug_ob_in_side_2;
            o_debug_ob_event_action = debug_ob_event_action_2;
            o_debug_ob_event_price = debug_ob_event_price_2;
            o_debug_ob_event_quantity = debug_ob_event_quantity_2;
            o_debug_ob_event_valid = debug_ob_event_valid_2;
            o_debug_ob_event_side = debug_ob_event_side_2;
            o_debug_best_bid_quantity = debug_best_bid_quantity_2;
            o_debug_best_ask_quantity = debug_best_ask_quantity_2;
        end
        STOCK_LEN'(3): begin
            o_best_bid_price = best_bid_price_3;
            o_best_ask_price = best_ask_price_3;
            o_best_bid_valid = best_bid_valid_3;
            o_best_ask_valid = best_ask_valid_3;
            o_trading_bid_price = trading_bid_price_3;
            o_trading_ask_price = trading_ask_price_3;
            o_trading_order_type = trading_order_type_3;
            o_trading_valid = trading_valid_3;
            o_position = position_3;
            o_day_pnl = day_pnl_3;
            o_live_bid_qty = live_bid_qty_3;
            o_live_ask_qty = live_ask_qty_3;
            o_debug_ob_in_order_id = debug_ob_in_order_id_3;
            o_debug_ob_in_price = debug_ob_in_price_3;
            o_debug_ob_in_quantity = debug_ob_in_quantity_3;
            o_debug_ob_in_action = debug_ob_in_action_3;
            o_debug_ob_in_valid = debug_ob_in_valid_3;
            o_debug_ob_in_side = debug_ob_in_side_3;
            o_debug_ob_event_action = debug_ob_event_action_3;
            o_debug_ob_event_price = debug_ob_event_price_3;
            o_debug_ob_event_quantity = debug_ob_event_quantity_3;
            o_debug_ob_event_valid = debug_ob_event_valid_3;
            o_debug_ob_event_side = debug_ob_event_side_3;
            o_debug_best_bid_quantity = debug_best_bid_quantity_3;
            o_debug_best_ask_quantity = debug_best_ask_quantity_3;
        end
        STOCK_LEN'(4): begin
            o_best_bid_price = best_bid_price_4;
            o_best_ask_price = best_ask_price_4;
            o_best_bid_valid = best_bid_valid_4;
            o_best_ask_valid = best_ask_valid_4;
            o_trading_bid_price = trading_bid_price_4;
            o_trading_ask_price = trading_ask_price_4;
            o_trading_order_type = trading_order_type_4;
            o_trading_valid = trading_valid_4;
            o_position = position_4;
            o_day_pnl = day_pnl_4;
            o_live_bid_qty = live_bid_qty_4;
            o_live_ask_qty = live_ask_qty_4;
            o_debug_ob_in_order_id = debug_ob_in_order_id_4;
            o_debug_ob_in_price = debug_ob_in_price_4;
            o_debug_ob_in_quantity = debug_ob_in_quantity_4;
            o_debug_ob_in_action = debug_ob_in_action_4;
            o_debug_ob_in_valid = debug_ob_in_valid_4;
            o_debug_ob_in_side = debug_ob_in_side_4;
            o_debug_ob_event_action = debug_ob_event_action_4;
            o_debug_ob_event_price = debug_ob_event_price_4;
            o_debug_ob_event_quantity = debug_ob_event_quantity_4;
            o_debug_ob_event_valid = debug_ob_event_valid_4;
            o_debug_ob_event_side = debug_ob_event_side_4;
            o_debug_best_bid_quantity = debug_best_bid_quantity_4;
            o_debug_best_ask_quantity = debug_best_ask_quantity_4;
        end
        default: begin
        end
    endcase
end

always_comb begin
    o_order_payload_valid = 1'b0;
    o_order_payload = '0;
    if (order_payload_valid_1) begin
        o_order_payload_valid = 1'b1;
        o_order_payload = order_payload_1;
    end else if (order_payload_valid_2) begin
        o_order_payload_valid = 1'b1;
        o_order_payload = order_payload_2;
    end else if (order_payload_valid_3) begin
        o_order_payload_valid = 1'b1;
        o_order_payload = order_payload_3;
    end else if (order_payload_valid_4) begin
        o_order_payload_valid = 1'b1;
        o_order_payload = order_payload_4;
    end
end

always_comb begin
    o_exec_valid = 1'b0;
    o_exec_side = 1'b0;
    o_exec_price = '0;
    o_exec_quantity = '0;
    o_exec_order_id = '0;
    if (exec_valid_1) begin
        o_exec_valid = 1'b1;
        o_exec_side = exec_side_1;
        o_exec_price = exec_price_1;
        o_exec_quantity = exec_quantity_1;
        o_exec_order_id = exec_order_id_1;
    end else if (exec_valid_2) begin
        o_exec_valid = 1'b1;
        o_exec_side = exec_side_2;
        o_exec_price = exec_price_2;
        o_exec_quantity = exec_quantity_2;
        o_exec_order_id = exec_order_id_2;
    end else if (exec_valid_3) begin
        o_exec_valid = 1'b1;
        o_exec_side = exec_side_3;
        o_exec_price = exec_price_3;
        o_exec_quantity = exec_quantity_3;
        o_exec_order_id = exec_order_id_3;
    end else if (exec_valid_4) begin
        o_exec_valid = 1'b1;
        o_exec_side = exec_side_4;
        o_exec_price = exec_price_4;
        o_exec_quantity = exec_quantity_4;
        o_exec_order_id = exec_order_id_4;
    end
end

always_comb begin
    o_bid_reject_valid = 1'b0;
    o_bid_reject_reason = 4'd0;
    if (bid_reject_valid_1) begin
        o_bid_reject_valid = 1'b1;
        o_bid_reject_reason = bid_reject_reason_1;
    end else if (bid_reject_valid_2) begin
        o_bid_reject_valid = 1'b1;
        o_bid_reject_reason = bid_reject_reason_2;
    end else if (bid_reject_valid_3) begin
        o_bid_reject_valid = 1'b1;
        o_bid_reject_reason = bid_reject_reason_3;
    end else if (bid_reject_valid_4) begin
        o_bid_reject_valid = 1'b1;
        o_bid_reject_reason = bid_reject_reason_4;
    end
end

always_comb begin
    o_ask_reject_valid = 1'b0;
    o_ask_reject_reason = 4'd0;
    if (ask_reject_valid_1) begin
        o_ask_reject_valid = 1'b1;
        o_ask_reject_reason = ask_reject_reason_1;
    end else if (ask_reject_valid_2) begin
        o_ask_reject_valid = 1'b1;
        o_ask_reject_reason = ask_reject_reason_2;
    end else if (ask_reject_valid_3) begin
        o_ask_reject_valid = 1'b1;
        o_ask_reject_reason = ask_reject_reason_3;
    end else if (ask_reject_valid_4) begin
        o_ask_reject_valid = 1'b1;
        o_ask_reject_reason = ask_reject_reason_4;
    end
end

assign o_debug_parser_order_id = i_order_id;
assign o_debug_parser_quantity = {{(32-QUANTITY_LEN){1'b0}}, i_quantity};
assign o_debug_parser_side = i_side;
assign o_debug_parser_price = {{(32-PRICE_LEN){1'b0}}, i_price};
assign o_debug_parser_action = i_action;
assign o_debug_parser_valid = i_valid;
assign o_debug_parser_stock_id = i_stock_id;
assign o_debug_parser_timestamp = i_timestamp;

endmodule
