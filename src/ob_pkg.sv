package ob_pkg;

    parameter int ORDERID_LEN = 14;
    parameter int PRICE_LEN = ;
    parameter int QUANTITY_LEN = ;
    parameter int TOT_QUATITY_LEN = ;

    typedef struct packed {
        logic [PRICE_LEN-1:0] price;
        logic [QUANTITY_LEN-1:0] quantity;
    } ob_packet_t;

    localparam int OPB_DEPTH = (1 << ORDERID_LEN);
    localparam int OPB_WIDTH = $bits(ob_packet_t);

endpackage