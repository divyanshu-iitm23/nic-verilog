`timescale 1ns/1ps

module tb_rx_descriptor_ring;

    reg        clk;
    reg        rst;

    reg [7:0]  macrx_data;
    reg        macrx_data_valid;
    reg        macrx_sof;
    reg        macrx_eof;

    reg        classifier_valid;
    reg        classifier_accept;
    reg [31:0] classifier_dst_ip;
    reg [15:0] classifier_dst_port;
    reg [15:0] classifier_payload_len;

    reg [63:0] hwts_value;
    reg        sw_ren;

    wire        ring_desc_valid;
    wire [31:0] ring_desc_ip;
    wire [15:0] ring_desc_port;
    wire [15:0] ring_desc_len;
    wire [63:0] ring_desc_timestamp;
    wire [11:0] ring_desc_payload_addr;
    wire        ring_full;
    wire [3:0]  ring_head_ptr;
    wire [3:0]  ring_tail_ptr;

    rx_descriptor_ring dut (
        .clk                    (clk),
        .rst                    (rst),
        .macrx_data             (macrx_data),
        .macrx_data_valid       (macrx_data_valid),
        .macrx_sof              (macrx_sof),
        .macrx_eof              (macrx_eof),
        .classifier_valid       (classifier_valid),
        .classifier_accept      (classifier_accept),
        .classifier_dst_ip      (classifier_dst_ip),
        .classifier_dst_port    (classifier_dst_port),
        .classifier_payload_len (classifier_payload_len),
        .hwts_value             (hwts_value),
        .sw_ren                 (sw_ren),
        .ring_desc_valid        (ring_desc_valid),
        .ring_desc_ip           (ring_desc_ip),
        .ring_desc_port         (ring_desc_port),
        .ring_desc_len          (ring_desc_len),
        .ring_desc_timestamp    (ring_desc_timestamp),
        .ring_desc_payload_addr (ring_desc_payload_addr),
        .ring_full              (ring_full),
        .ring_head_ptr          (ring_head_ptr),
        .ring_tail_ptr          (ring_tail_ptr)
    );

    integer pass_count = 0;
    integer fail_count = 0;

    task check(input cond, input [255:0] name);
        begin
            if (cond) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s (time %0t)", name, $time);
            end
        end
    endtask

    function [4:0] desc_count;
        input dummy;
        begin
            if (ring_full)
                desc_count = 5'd16;
            else
                desc_count = {1'b0, ring_tail_ptr - ring_head_ptr};
        end
    endfunction

    task send_frame(input integer nbytes, input accept, input [7:0] seed,
                    input [31:0] ip, input [15:0] port, input [15:0] plen,
                    input [63:0] ts);
        integer i;
        begin
            hwts_value = ts;   // stable for the whole frame, per §3
            for (i = 0; i < nbytes; i = i + 1) begin
                @(posedge clk);
                #1;
                macrx_data       = seed + i[7:0];
                macrx_data_valid = 1;
                macrx_sof        = (i == 0);
                macrx_eof        = (i == nbytes - 1);
                classifier_valid   = (i == nbytes - 1);
                classifier_accept  = (i == nbytes - 1) ? accept : 1'b0;
                classifier_dst_ip  = ip;
                classifier_dst_port = port;
                classifier_payload_len = plen;
            end
            @(posedge clk);
            #1;
            macrx_data_valid = 0; macrx_sof = 0; macrx_eof = 0;
            classifier_valid = 0; classifier_accept = 0;
            @(negedge clk);   // outputs settled for checking
        end
    endtask

    task pop_one;
        begin
            @(posedge clk);
            #1 sw_ren = 1;
            @(posedge clk);
            #1 sw_ren = 0;
            @(negedge clk);
        end
    endtask

    task check_payload(input [11:0] addr, input integer n, input [7:0] seed,
                       input [255:0] name);
        integer i;
        reg ok;
        begin
            ok = 1;
            for (i = 0; i < n; i = i + 1)
                if (dut.payload_mem[(addr + i[11:0]) & 12'hFFF]
                        !== (seed + i[7:0]))
                    ok = 0;
            check(ok, name);
        end
    endtask

    localparam [31:0] IP_A = {8'd239, 8'd1, 8'd1, 8'd1};
    localparam [31:0] IP_B = {8'd239, 8'd2, 8'd2, 8'd2};

    integer i;

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        $dumpfile("sim/tb_rx_descriptor_ring.vcd");
        $dumpvars(0, tb_rx_descriptor_ring);

        macrx_data = 0; macrx_data_valid = 0; macrx_sof = 0; macrx_eof = 0;
        classifier_valid = 0; classifier_accept = 0; classifier_dst_ip = 0;
        classifier_dst_port = 0; classifier_payload_len = 0;
        hwts_value = 0; sw_ren = 0;

        rst = 1;
        repeat (2) @(posedge clk);
        #1 rst = 0;
        repeat (2) @(posedge clk);

        check(ring_desc_valid == 1'b0, "empty after reset");
        check(ring_full == 1'b0, "not full after reset");

        send_frame(100, 1'b1, 8'h10, IP_A, 16'd5000, 16'd72, 64'd1000);
        check(ring_desc_valid == 1'b1, "accept: descriptor available");
        check(ring_desc_ip == IP_A, "accept: ip metadata");
        check(ring_desc_port == 16'd5000, "accept: port metadata");
        check(ring_desc_len == 16'd72, "accept: len metadata");
        check(ring_desc_timestamp == 64'd1000, "accept: timestamp");
        check(ring_desc_payload_addr == 12'd0, "accept: payload addr");
        check(ring_tail_ptr == 4'd1 && ring_head_ptr == 4'd0,
              "accept: pointers");
        check_payload(12'd0, 100, 8'h10, "accept: payload bytes stored");
        pop_one;
        check(ring_desc_valid == 1'b0, "pop: ring empty again");
        check(ring_head_ptr == 4'd1, "pop: head advanced");

        send_frame(50, 1'b0, 8'h99, IP_B, 16'd1, 16'd1, 64'd1100);
        check(ring_desc_valid == 1'b0, "reject: no descriptor");
        check(ring_tail_ptr == 4'd1, "reject: tail unchanged");
        send_frame(80, 1'b1, 8'h20, IP_A, 16'd5000, 16'd52, 64'd1200);
        check(ring_desc_payload_addr == 12'd100,
              "rewind: next frame reuses rejected frame's space");
        check_payload(12'd100, 80, 8'h20, "rewind: payload overwritten");
        pop_one;

        send_frame(60, 1'b1, 8'h30, IP_A, 16'd7001, 16'd32, 64'd2000);
        send_frame(60, 1'b1, 8'h40, IP_B, 16'd7002, 16'd32, 64'd2001);
        check(ring_desc_port == 16'd7001, "fifo: head is first frame");
        check(ring_desc_timestamp == 64'd2000, "fifo: head ts");
        pop_one;
        check(ring_desc_valid == 1'b1, "fifo: second still queued");
        check(ring_desc_port == 16'd7002, "fifo: head is second frame");
        pop_one;
        check(ring_desc_valid == 1'b0, "fifo: drained");

        for (i = 0; i < 16; i = i + 1)
            send_frame(100, 1'b1, 8'h50 + i[7:0], IP_A,
                       16'd8000 + i[15:0], 16'd72, 64'd3000 + i[63:0]);
        check(ring_full == 1'b1, "overload: ring_full after 16");
        check(desc_count(0) == 5'd16, "overload: 16 committed");
        send_frame(100, 1'b1, 8'hEE, IP_B, 16'd9999, 16'd72, 64'd4000);
        check(ring_full == 1'b1, "overload: 17th dropped, still full");
        check(ring_desc_port == 16'd8000, "overload: head undisturbed");
        for (i = 0; i < 16; i = i + 1) begin
            check(ring_desc_valid == 1'b1, "overload: drain has entries");
            check(ring_desc_port == 16'd8000 + i[15:0],
                  "overload: FIFO order preserved");
            pop_one;
        end
        check(ring_desc_valid == 1'b0 && ring_full == 1'b0,
              "overload: fully drained");
        check(ring_head_ptr == ring_tail_ptr, "overload: pointers meet");

        // 13 x 300B = 3900 committed; the 14th 300B frame hits the 4096B
        // buffer limit mid-frame and must be dropped at commit time.
        for (i = 0; i < 13; i = i + 1)
            send_frame(300, 1'b1, i[7:0], IP_A, 16'd8100 + i[15:0],
                       16'd272, 64'd5000 + i[63:0]);
        check(desc_count(0) == 5'd13, "buffull: 13 fit");
        send_frame(300, 1'b1, 8'hDD, IP_B, 16'd8200, 16'd272, 64'd6000);
        check(desc_count(0) == 5'd13, "buffull: 14th dropped (no buffer)");
        check(ring_full == 1'b0, "buffull: ring itself not full");
        // pop one (frees 300B) -> next 300B frame fits again
        pop_one;
        send_frame(300, 1'b1, 8'h77, IP_B, 16'd8300, 16'd272, 64'd7000);
        check(desc_count(0) == 5'd13, "buffull: fits after one pop");
        // the new frame starts where the dropped frame was rewound to
        begin : buffull_addr
            reg [11:0] exp_addr;
            // wr_ptr history: 2200 after tests 1-4, +13*300 mod 4096 = 1704
            exp_addr = 12'd1704;
            // walk to the newest descriptor: it's at tail-1
            check(dut.d_addr[(ring_tail_ptr - 4'd1) & 4'hF] == exp_addr,
                  "buffull: new frame reuses rewound space");
        end
        check_payload(12'd1704, 300, 8'h77, "buffull: new payload intact");

        $display("");
        if (fail_count == 0)
            $display("tb_rx_descriptor_ring: ALL %0d TESTS PASSED",
                     pass_count);
        else
            $display("tb_rx_descriptor_ring: %0d PASSED, %0d FAILED",
                     pass_count, fail_count);
        $finish;
    end

endmodule
