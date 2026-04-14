module one_stock_top #(
    parameter int MARKET_PAYLOAD_LEN = 288,
    parameter int OUCH_PAYLOAD_LEN   = 752,
    parameter int SYMBOL_LEN         = 64,
    parameter int ORDER_ID_LEN       = 32,
    parameter int PRICE_LEN          = 32,
    parameter int QUANTITY_LEN       = 16,
    parameter int POSITION_LEN       = 16,
    parameter int PNL_LEN            = 64,
    parameter int STOCK_LEN          = 16,
    parameter int MARKET_QTY_LEN     = 32
) (
    input  logic                            i_clk,
    input  logic                            i_rst_n,
    input  logic [MARKET_PAYLOAD_LEN-1:0]   i_market_payload,
    input  logic                            i_market_valid,
    input  logic [47:0]                     i_order_time,
    input  logic [SYMBOL_LEN-1:0]           i_symbol,
    input  logic [QUANTITY_LEN-1:0]         i_bid_quote_quantity,
    input  logic [QUANTITY_LEN-1:0]         i_ask_quote_quantity,
    input  logic                            i_trading_enable,
    input  logic                            i_kill_switch,
    input  logic                            i_price_band_enable,
    input  logic                            i_pnl_check_enable,

    output logic [STOCK_LEN-1:0]            o_stock_id,
    output logic [PRICE_LEN-1:0]            o_best_bid_price,
    output logic [PRICE_LEN-1:0]            o_best_ask_price,
    output logic                            o_best_bid_valid,
    output logic                            o_best_ask_valid,
    output logic [PRICE_LEN-1:0]            o_trading_bid_price,
    output logic [PRICE_LEN-1:0]            o_trading_ask_price,
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
    output logic [PRICE_LEN-1:0]            o_exec_price,
    output logic [QUANTITY_LEN-1:0]         o_exec_quantity,
    output logic [ORDER_ID_LEN-1:0]         o_exec_order_id,
    output logic signed [POSITION_LEN-1:0]  o_position,
    output logic signed [PNL_LEN-1:0]       o_day_pnl,
    output logic [QUANTITY_LEN-1:0]         o_live_bid_qty,
    output logic [QUANTITY_LEN-1:0]         o_live_ask_qty
);

localparam int OB_ORDERID_LEN  = ob_pkg::ORDERID_LEN;
localparam int OB_QUANTITY_LEN = ob_pkg::QUANTITY_LEN;
localparam int OB_TOTAL_QTY_LEN = ob_pkg::TOT_QUATITY_LEN;
// Parser outputs
logic [63:0]               parser_order_id;
logic [31:0]               parser_quantity;
logic                      parser_side;
logic [31:0]               parser_price;
logic [1:0]                parser_action;
logic                      parser_valid;
logic [STOCK_LEN-1:0]      parser_stock_id;
logic [47:0]               parser_timestamp;
// Order book outputs
logic [PRICE_LEN-1:0]      ob_best_bid_price;
logic [PRICE_LEN-1:0]      ob_best_ask_price;
logic [OB_TOTAL_QTY_LEN-1:0] ob_best_bid_quantity;
logic [OB_TOTAL_QTY_LEN-1:0] ob_best_ask_quantity;
logic                      ob_best_bid_valid;
logic                      ob_best_ask_valid;
logic [1:0]                ob_event_action;
logic [PRICE_LEN-1:0]      ob_event_price;
logic [MARKET_QTY_LEN-1:0] ob_event_quantity;
logic                      ob_event_valid;
logic                      ob_event_side;
// Trading logic outputs
logic [PRICE_LEN-1:0]      tl_bid_price;
logic [PRICE_LEN-1:0]      tl_ask_price;
logic [1:0]                tl_order_type;
logic                      tl_valid;
// Split bid/ask quote requests into separate risk-managers
logic                      bid_quote_req_valid;
logic                      ask_quote_req_valid;
logic [PRICE_LEN-1:0]      reference_price;
logic                      price_valid_for_tl;
logic                      trade_valid_for_tl;
logic [15:0]               trade_qty_for_tl;
logic                      trade_side_for_tl;
// Risk manager outputs
logic                      bid_quote_valid;
logic                      bid_quote_side;
logic [PRICE_LEN-1:0]      bid_quote_price;
logic [QUANTITY_LEN-1:0]   bid_quote_quantity;
logic                      ask_quote_valid;
logic                      ask_quote_side;
logic [PRICE_LEN-1:0]      ask_quote_price;
logic [QUANTITY_LEN-1:0]   ask_quote_quantity;
// Order generator / execution tracker feedback
logic [QUANTITY_LEN-1:0]   og_quantity_buy;
logic [QUANTITY_LEN-1:0]   og_quantity_sell;
logic [PRICE_LEN-1:0]      og_price_buy;
logic [PRICE_LEN-1:0]      og_price_sell;
logic [ORDER_ID_LEN-1:0]   og_new_order_num_buy;
logic [ORDER_ID_LEN-1:0]   og_new_order_num_sell;
logic                      exec_replace_bid_ready;
logic                      exec_replace_ask_ready;
logic [ORDER_ID_LEN-1:0]   exec_oldest_bid_order_id;
logic [ORDER_ID_LEN-1:0]   exec_oldest_ask_order_id;
logic [QUANTITY_LEN-1:0]   risk_bid_qty_in;
logic [QUANTITY_LEN-1:0]   risk_ask_qty_in;

assign bid_quote_req_valid = tl_valid && tl_order_type[0];
assign ask_quote_req_valid = tl_valid && tl_order_type[1];
assign reference_price     = (ob_best_bid_price + ob_best_ask_price) >> 1;
// For now, risk uses best bid/ask quantity from the orderbook since our trading logic does not currently output quantity
assign risk_bid_qty_in     = ob_best_bid_quantity[QUANTITY_LEN-1:0];
assign risk_ask_qty_in     = ob_best_ask_quantity[QUANTITY_LEN-1:0];
assign price_valid_for_tl = parser_valid && ob_best_bid_valid && ob_best_ask_valid;
assign trade_valid_for_tl = o_exec_valid;
assign trade_qty_for_tl   = o_exec_quantity;
assign trade_side_for_tl  = o_exec_side;

parser parser_inst (
    .i_clk      (i_clk),
    .i_rst_n    (i_rst_n),
    .i_payload  (i_market_payload),
    .i_valid    (i_market_valid),
    .o_order_id (parser_order_id),
    .o_quantity (parser_quantity),
    .o_side     (parser_side),
    .o_price    (parser_price),
    .o_action   (parser_action),
    .o_valid    (parser_valid),
    .o_stock_id (parser_stock_id),
    .o_timestamp(parser_timestamp)
);

// Parser I think gives wider fields than the book uses, so slice order_id to package width here
// need to get the output for execution tracker from here still, might be wrong here tho so can change if needed
orderbook ob_inst (
    .i_clk            (i_clk),
    .i_rst_n          (i_rst_n),
    .i_order_id       (parser_order_id[OB_ORDERID_LEN-1:0]),
    .i_side           (parser_side),
    .i_price          (parser_price),
    .i_quantity       (parser_quantity[OB_QUANTITY_LEN-1:0]),
    .i_action         (parser_action),
    .i_valid          (parser_valid),
    .o_bid_best_price (ob_best_bid_price),
    .o_bid_best_quant (ob_best_bid_quantity),
    .o_ask_best_price (ob_best_ask_price),
    .o_ask_best_quant (ob_best_ask_quantity),
    .o_bid_best_valid (ob_best_bid_valid),
    .o_ask_best_valid (ob_best_ask_valid),
    .o_action         (ob_event_action),
    .o_price          (ob_event_price),
    .o_quantity       (ob_event_quantity),
    .o_valid          (ob_event_valid),
    .o_side           (ob_event_side)
);

// should still be updated so it outputs a trade quantity
tl_top tl_inst (
    .i_clk        (i_clk),
    .i_rst_n      (i_rst_n),
    .i_best_bid   (ob_best_bid_price),
    .i_best_ask   (ob_best_ask_price),
    .i_order_time (parser_timestamp),
    .i_price_valid(price_valid_for_tl),
    .i_trade_valid(trade_valid_for_tl),
    .i_trade_qty  (trade_qty_for_tl),
    .i_trade_side (trade_side_for_tl),
    .o_bid_price  (tl_bid_price),
    .o_ask_price  (tl_ask_price),
    .o_order_type (tl_order_type),
    .o_valid      (tl_valid)
);

risk_manager bid_risk_inst (
    .i_clk                (i_clk),
    .i_rst_n              (i_rst_n),
    .i_trading_enable     (i_trading_enable),
    .i_kill_switch        (i_kill_switch),
    .i_price_band_enable  (i_price_band_enable),
    .i_pnl_check_enable   (i_pnl_check_enable),
    .i_inventory_position (o_position),
    .i_day_pnl            (o_day_pnl),
    .i_live_bid_qty       (risk_bid_qty_in),
    .i_live_ask_qty       (risk_ask_qty_in),
    .i_quote_valid        (bid_quote_req_valid),
    .i_quote_side         (1'b0),
    .i_quote_price        (tl_bid_price),
    .i_quote_quantity     (i_bid_quote_quantity),
    .i_reference_price    (reference_price),
    .o_quote_valid        (bid_quote_valid),
    .o_quote_side         (bid_quote_side),
    .o_quote_price        (bid_quote_price),
    .o_quote_quantity     (bid_quote_quantity),
    .o_reject_valid       (o_bid_reject_valid),
    .o_reject_reason      (o_bid_reject_reason)
);

risk_manager ask_risk_inst (
    .i_clk                (i_clk),
    .i_rst_n              (i_rst_n),
    .i_trading_enable     (i_trading_enable),
    .i_kill_switch        (i_kill_switch),
    .i_price_band_enable  (i_price_band_enable),
    .i_pnl_check_enable   (i_pnl_check_enable),
    .i_inventory_position (o_position),
    .i_day_pnl            (o_day_pnl),
    .i_live_bid_qty       (risk_bid_qty_in),
    .i_live_ask_qty       (risk_ask_qty_in),
    .i_quote_valid        (ask_quote_req_valid),
    .i_quote_side         (1'b1),
    .i_quote_price        (tl_ask_price),
    .i_quote_quantity     (i_ask_quote_quantity),
    .i_reference_price    (reference_price),
    .o_quote_valid        (ask_quote_valid),
    .o_quote_side         (ask_quote_side),
    .o_quote_price        (ask_quote_price),
    .o_quote_quantity     (ask_quote_quantity),
    .o_reject_valid       (o_ask_reject_valid),
    .o_reject_reason      (o_ask_reject_reason)
);

Order_Generator ogen_inst (
    .i_clk                  (i_clk),
    .i_rst_n                (i_rst_n),
    .i_symbol               (i_symbol),
    .i_old_order_num_buy    (exec_oldest_bid_order_id),
    .i_old_order_num_sell   (exec_oldest_ask_order_id),
    .i_old_order_executed_buy(!exec_replace_bid_ready),
    .i_old_order_executed_sell(!exec_replace_ask_ready),
    .i_old_symbol_buy       (i_symbol),
    .i_old_symbol_sell      (i_symbol),
    .i_price_buy            (bid_quote_price),
    .i_price_sell           (ask_quote_price),
    .i_quantity_buy         (bid_quote_quantity),
    .i_quantity_sell        (ask_quote_quantity),
    .i_valid_buy            (bid_quote_valid),
    .i_valid_sell           (ask_quote_valid),
    .o_quantity_buy         (og_quantity_buy),
    .o_quantity_sell        (og_quantity_sell),
    .o_price_buy            (og_price_buy),
    .o_price_sell           (og_price_sell),
    .o_new_order_num_buy    (og_new_order_num_buy),
    .o_new_order_num_sell   (og_new_order_num_sell),
    .o_payload_valid        (o_order_payload_valid),
    .o_payload              (o_order_payload)
);

// should currently keep track of 10 in the market on each side
execution_tracker execution_tracker_inst (
    .i_clk               (i_clk),
    .i_rst_n             (i_rst_n),
    .i_order_valid       (o_order_payload_valid),
    .i_order_id_buy      (og_new_order_num_buy),
    .i_order_id_sell     (og_new_order_num_sell),
    .i_order_price_buy   (og_price_buy),
    .i_order_price_sell  (og_price_sell),
    .i_order_quantity_buy(og_quantity_buy),
    .i_order_quantity_sell(og_quantity_sell),
    .i_market_exec_valid (trade_valid_for_tl),
    .i_market_exec_side  (ob_event_side),
    .i_market_exec_price (ob_event_price),
    .i_market_exec_quantity(ob_event_quantity),
    .o_exec_valid        (o_exec_valid),
    .o_exec_side         (o_exec_side),
    .o_exec_price        (o_exec_price),
    .o_exec_quantity     (o_exec_quantity),
    .o_exec_order_id     (o_exec_order_id),
    .o_live_bid_active   (exec_replace_bid_ready),
    .o_live_ask_active   (exec_replace_ask_ready),
    .o_live_bid_order_id (exec_oldest_bid_order_id),
    .o_live_ask_order_id (exec_oldest_ask_order_id),
    .o_live_bid_qty      (o_live_bid_qty),
    .o_live_ask_qty      (o_live_ask_qty)
);

inventory_tracker inventory_tracker_inst (
    .i_clk          (i_clk),
    .i_rst_n        (i_rst_n),
    .i_exec_valid   (o_exec_valid),
    .i_exec_side    (o_exec_side),
    .i_exec_price   (o_exec_price),
    .i_exec_quantity(o_exec_quantity),
    .o_position     (o_position),
    .o_day_pnl      (o_day_pnl)
);

assign o_stock_id         = parser_stock_id;
assign o_best_bid_price   = ob_best_bid_price;
assign o_best_ask_price   = ob_best_ask_price;
assign o_best_bid_valid   = ob_best_bid_valid;
assign o_best_ask_valid   = ob_best_ask_valid;
assign o_trading_bid_price = tl_bid_price;
assign o_trading_ask_price = tl_ask_price;
assign o_trading_order_type = tl_order_type;
assign o_trading_valid    = tl_valid;

endmodule
