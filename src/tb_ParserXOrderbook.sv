`timescale 1ns/1ps
import ob_pkg::*;
module tb_ParserXOrderbook();

    logic                       CLOCK_50;
    logic 		     [3:0]		KEY;
	logic 		     [9:0]		SW;

    ParserXOrderbook iDUT(
	.CLOCK2_50(CLOCK_50),
	.CLOCK3_50(CLOCK_50),
	.CLOCK4_50(CLOCK_50),
	.CLOCK_50(CLOCK_50),
	.HEX0(),
	.HEX1(),
	.HEX2(),
	.HEX3(),
	.HEX4(),
	.HEX5(),
	.LEDR(),
	.KEY(KEY),
	.SW(SW)
);
    // Clock
    initial begin
        CLOCK_50 = 0;
        forever #5 CLOCK_50 = ~CLOCK_50;
    end


    task automatic send_op(
        input logic [3:0] i_KEY,
	    input logic [9:0] i_SW
    );
    begin
        @(posedge CLOCK_50);
        KEY <= i_KEY;
        SW <= i_SW;
    end
    endtask

    initial begin
        KEY = '0;
        SW = '0;
        repeat(5) @(posedge CLOCK_50);
        KEY[0] = 1;
        repeat(20) @(posedge CLOCK_50);
        send_op(4'b0001, 10'd0);
        send_op(4'b0011, 10'd0);
        send_op(4'b0001, 10'd0);

        send_op(4'b0001, 10'd1);
        send_op(4'b0011, 10'd1);
        send_op(4'b0001, 10'd1);

        send_op(4'b0001, 10'd2);
        send_op(4'b0011, 10'd2);
        send_op(4'b0001, 10'd2);

        send_op(4'b0001, 10'd3);
        send_op(4'b0011, 10'd3);
        send_op(4'b0001, 10'd3);

        send_op(4'b0001, 10'd4);
        send_op(4'b0011, 10'd4);
        send_op(4'b0001, 10'd4);

        send_op(4'b0001, 10'd5);
        send_op(4'b0011, 10'd5);
        send_op(4'b0001, 10'd5);

        send_op(4'b0001, 10'd6);
        send_op(4'b0011, 10'd6);
        send_op(4'b0001, 10'd6);

        send_op(4'b0001, 10'd7);
        send_op(4'b0011, 10'd7);
        send_op(4'b0001, 10'd7);

        send_op(4'b0001, 10'd8);
        send_op(4'b0011, 10'd8);
        send_op(4'b0001, 10'd8);

        send_op(4'b0001, 10'd9);
        send_op(4'b0011, 10'd9);
        send_op(4'b0001, 10'd9);

        send_op(4'b0001, 10'd10);
        send_op(4'b0011, 10'd10);
        send_op(4'b0001, 10'd10);

        send_op(4'b0001, 10'd10);
        send_op(4'b0011, 10'd10);
        send_op(4'b0001, 10'd10);

        send_op(4'b0001, 10'd10);
        send_op(4'b0011, 10'd10);
        send_op(4'b0001, 10'd10);

        send_op(4'b0001, 10'd11);
        send_op(4'b0011, 10'd11);
        send_op(4'b0001, 10'd11);

        send_op(4'b0001, 10'd12);
        send_op(4'b0011, 10'd12);
        send_op(4'b0001, 10'd12);


        // send_op(4'b0001, 10'b001_000_10_00);
        // send_op(4'b0011, 10'b001_000_10_00);
        // send_op(4'b0001, 10'b001_000_10_00);
        repeat(30) @(posedge CLOCK_50);
        $stop;
    end
endmodule