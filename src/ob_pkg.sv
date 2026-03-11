package ob_pkg;

    parameter int ORDERID_LEN = 3;
    parameter int PRICE_LEN = 8;
    parameter int QUANTITY_LEN = 8;
    parameter int TOT_QUATITY_LEN = 8;

    typedef struct packed {
        logic [PRICE_LEN-1:0] price;
        logic [QUANTITY_LEN-1:0] quantity;
    } ob_packet_t;

    localparam int OPB_DEPTH = (1 << ORDERID_LEN);
    localparam int OPB_WIDTH = $bits(ob_packet_t);

endpackage