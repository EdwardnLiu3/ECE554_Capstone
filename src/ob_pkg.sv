package ob_pkg;

    parameter int ORDERID_LEN = 3;
    parameter int PRICE_LEN = 11;
    parameter int QUANTITY_LEN = 11;
    parameter int TOT_QUATITY_LEN = 22;
    parameter int NUM_LEVELS = 4096;
    parameter int FLB_CACHE_LEVEL = 10;
    parameter int CACHE_POS = $clog2(FLB_CACHE_LEVEL);

    // action
    parameter ADD = 2'b00;
    parameter CANCEL = 2'b01;
    parameter EXECUTE = 2'b10;
    parameter DELETE = 2'b11;
    

    typedef struct packed {
        logic [PRICE_LEN-1:0] price;
        logic [QUANTITY_LEN-1:0] quantity;
    } ob_packet_t;

    typedef struct packed {
        logic valid;
        logic [$clog2(NUM_LEVELS)-1:0] index;
        logic [QUANTITY_LEN-1:0] quantity;
    } flb_cache_packet_t;
    
    localparam int OPB_DEPTH = (1 << ORDERID_LEN);
    localparam int OPB_WIDTH = $bits(ob_packet_t);

endpackage