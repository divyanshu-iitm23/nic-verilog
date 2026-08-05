`timescale 1ns/1ps

module tb_top_integration;

    reg clk;
    reg rst;

    reg [7:0] phy_data;
    reg       phy_data_valid;

    wire [7:0]  macrx_data;
    wire        macrx_data_valid;
    wire        macrx_sof;
    wire        macrx_eof;
    wire        macrx_frame_ok;
    wire        macrx_ready;

    wire [63:0] hwts_counter;
    wire [63:0] hwts_value;
    wire        hwts_valid;

    wire        classifier_valid;
    wire        classifier_accept;
    wire [31:0] classifier_dst_ip;
    wire [15:0] classifier_dst_port;
    wire [15:0] classifier_payload_len;

    reg         cfg_wr_en;
    reg  [3:0]  cfg_wr_idx;
    reg  [31:0] cfg_dst_ip;
    reg  [15:0] cfg_dst_port;
    reg         cfg_entry_en;

    reg         sw_ren;
    wire        ring_desc_valid;
    wire [31:0] ring_desc_ip;
    wire [15:0] ring_desc_port;
    wire [15:0] ring_desc_len;
    wire [63:0] ring_desc_timestamp;
    wire [11:0] ring_desc_payload_addr;
    wire        ring_full;
    wire [3:0]  ring_head_ptr;
    wire [3:0]  ring_tail_ptr;

    mac_rx u_mac_rx (
        .clk              (clk),
        .rst              (rst),
        .phy_data         (phy_data),
        .phy_data_valid   (phy_data_valid),
        .macrx_data       (macrx_data),
        .macrx_data_valid (macrx_data_valid),
        .macrx_sof        (macrx_sof),
        .macrx_eof        (macrx_eof),
        .macrx_frame_ok   (macrx_frame_ok),
        .macrx_ready      (macrx_ready)
    );

    hw_timestamp u_hw_timestamp (
        .clk          (clk),
        .rst          (rst),
        .macrx_sof    (macrx_sof),
        .hwts_counter (hwts_counter),
        .hwts_value   (hwts_value),
        .hwts_valid   (hwts_valid)
    );

    udp_classifier u_udp_classifier (
        .clk                    (clk),
        .rst                    (rst),
        .macrx_data             (macrx_data),
        .macrx_data_valid       (macrx_data_valid),
        .macrx_sof              (macrx_sof),
        .macrx_eof              (macrx_eof),
        .macrx_frame_ok         (macrx_frame_ok),
        .cfg_wr_en              (cfg_wr_en),
        .cfg_wr_idx             (cfg_wr_idx),
        .cfg_dst_ip             (cfg_dst_ip),
        .cfg_dst_port           (cfg_dst_port),
        .cfg_entry_en           (cfg_entry_en),
        .classifier_valid       (classifier_valid),
        .classifier_accept      (classifier_accept),
        .classifier_dst_ip      (classifier_dst_ip),
        .classifier_dst_port    (classifier_dst_port),
        .classifier_payload_len (classifier_payload_len)
    );

    rx_descriptor_ring u_rx_descriptor_ring (
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

    function [31:0] crc32_step(input [31:0] crc, input [7:0] b);
        integer i;
        reg [31:0] c;
        begin
            c = crc ^ {24'h0, b};
            for (i = 0; i < 8; i = i + 1)
                c = (c >> 1) ^ (c[0] ? 32'hEDB88320 : 32'h0);
            crc32_step = c;
        end
    endfunction

    reg [7:0] frame_buf [0:255];   // frame incl. FCS
    integer   flen;                // length incl. FCS

    task build_udp_frame(input [3:0] ihl_a, input [31:0] dip,
                         input [15:0] dport, input integer plen,
                         input [7:0] seed);
        integer i, udp_off, ip_totlen;
        reg [31:0] c;
        begin
            frame_buf[0] = 8'h01; frame_buf[1] = 8'h00; frame_buf[2] = 8'h5E;
            frame_buf[3] = 8'h11; frame_buf[4] = 8'h22; frame_buf[5] = 8'h33;
            frame_buf[6] = 8'h02; frame_buf[7] = 8'hAA; frame_buf[8] = 8'hBB;
            frame_buf[9] = 8'hCC; frame_buf[10] = 8'hDD; frame_buf[11] = 8'hEE;
            frame_buf[12] = 8'h08; frame_buf[13] = 8'h00;
            ip_totlen = ihl_a * 4 + 8 + plen;
            frame_buf[14] = {4'd4, ihl_a};
            frame_buf[15] = 8'h00;
            frame_buf[16] = ip_totlen[15:8];
            frame_buf[17] = ip_totlen[7:0];
            frame_buf[18] = 8'h00; frame_buf[19] = 8'h01;
            frame_buf[20] = 8'h00; frame_buf[21] = 8'h00;
            frame_buf[22] = 8'd64;
            frame_buf[23] = 8'd17;
            frame_buf[24] = 8'h00; frame_buf[25] = 8'h00;
            frame_buf[26] = 8'd10; frame_buf[27] = 8'd0;
            frame_buf[28] = 8'd0;  frame_buf[29] = 8'd1;
            frame_buf[30] = dip[31:24]; frame_buf[31] = dip[23:16];
            frame_buf[32] = dip[15:8];  frame_buf[33] = dip[7:0];
            for (i = 34; i < 14 + ihl_a * 4; i = i + 1)
                frame_buf[i] = 8'h01;
            udp_off = 14 + ihl_a * 4;
            frame_buf[udp_off]   = 8'h30; frame_buf[udp_off+1] = 8'h39;
            frame_buf[udp_off+2] = dport[15:8];
            frame_buf[udp_off+3] = dport[7:0];
            frame_buf[udp_off+4] = (plen + 8) >> 8;
            frame_buf[udp_off+5] = (plen + 8) & 255;
            frame_buf[udp_off+6] = 8'h00; frame_buf[udp_off+7] = 8'h00;
            for (i = 0; i < plen; i = i + 1)
                frame_buf[udp_off + 8 + i] = seed + i[7:0];
            flen = udp_off + 8 + plen;
            while (flen < 60) begin
                frame_buf[flen] = 8'h00;
                flen = flen + 1;
            end
            // append FCS
            c = 32'hFFFFFFFF;
            for (i = 0; i < flen; i = i + 1)
                c = crc32_step(c, frame_buf[i]);
            c = ~c;
            frame_buf[flen]   = c[7:0];
            frame_buf[flen+1] = c[15:8];
            frame_buf[flen+2] = c[23:16];
            frame_buf[flen+3] = c[31:24];
            flen = flen + 4;
        end
    endtask

    reg [7:0]  exp_stream [0:4095];
    integer    exp_off;
    integer    n_exp;
    reg [31:0] exp_ip   [0:7];
    reg [15:0] exp_port [0:7];
    reg [15:0] exp_len  [0:7];
    integer    exp_addr [0:7];
    integer    exp_stored [0:7];

    task expect_accepted(input [31:0] ip, input [15:0] port,
                         input [15:0] plen);
        integer i;
        begin
            exp_ip[n_exp]     = ip;
            exp_port[n_exp]   = port;
            exp_len[n_exp]    = plen;
            exp_addr[n_exp]   = exp_off;
            exp_stored[n_exp] = flen - 4;
            for (i = 0; i < flen - 4; i = i + 1)
                exp_stream[exp_off + i] = frame_buf[i];
            exp_off = exp_off + flen - 4;
            n_exp = n_exp + 1;
        end
    endtask

    task send_frame;
        integer i;
        begin
            for (i = 0; i < 7; i = i + 1) begin
                @(posedge clk);
                #1 phy_data = 8'h55; phy_data_valid = 1;
            end
            @(posedge clk);
            #1 phy_data = 8'hD5;
            for (i = 0; i < flen; i = i + 1) begin
                @(posedge clk);
                #1 phy_data = frame_buf[i];
            end
            @(posedge clk);
            #1 phy_data_valid = 0; phy_data = 8'h00;
        end
    endtask

    task gap(input integer n);
        begin
            repeat (n) @(posedge clk);
        end
    endtask

    task cfg_write(input [3:0] idx, input [31:0] ip, input [15:0] port,
                   input en);
        begin
            @(posedge clk);
            #1;
            cfg_wr_en = 1; cfg_wr_idx = idx;
            cfg_dst_ip = ip; cfg_dst_port = port; cfg_entry_en = en;
            @(posedge clk);
            #1 cfg_wr_en = 0;
        end
    endtask

    localparam [31:0] IP_A = {8'd239, 8'd1, 8'd1, 8'd1};    // subscribed
    localparam [31:0] IP_B = {8'd239, 8'd9, 8'd9, 8'd9};    // not subscribed

    integer i, j, n_drained;
    reg [63:0] prev_ts;
    reg        bytes_ok;

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        $dumpfile("sim/tb_top_integration.vcd");
        $dumpvars(0, tb_top_integration);

        rst = 1;
        phy_data = 8'h00;
        phy_data_valid = 0;
        cfg_wr_en = 0;
        cfg_wr_idx = 0;
        cfg_dst_ip = 0;
        cfg_dst_port = 0;
        cfg_entry_en = 0;
        sw_ren = 0;
        exp_off = 0;
        n_exp = 0;

        repeat (2) @(posedge clk);
        #1 rst = 0;
        repeat (2) @(posedge clk);

        cfg_write(4'd0, IP_A, 16'd5000, 1'b1);
        cfg_write(4'd1, IP_A, 16'd5001, 1'b1);

        build_udp_frame(4'd5, IP_A, 16'd5000, 32, 8'h11);
        expect_accepted(IP_A, 16'd5000, 16'd32);
        send_frame;
        gap(6);

        build_udp_frame(4'd5, IP_B, 16'd5000, 32, 8'h22);
        send_frame;
        gap(6);

        build_udp_frame(4'd5, IP_A, 16'd5000, 32, 8'h33);
        frame_buf[flen-2] = frame_buf[flen-2] ^ 8'hFF;
        send_frame;
        gap(6);

        build_udp_frame(4'd5, IP_A, 16'd5000, 16, 8'h44);
        expect_accepted(IP_A, 16'd5000, 16'd16);
        send_frame;                      // ends with exactly 1 low cycle
        build_udp_frame(4'd5, IP_A, 16'd5001, 48, 8'h55);
        expect_accepted(IP_A, 16'd5001, 16'd48);
        send_frame;
        gap(6);

        build_udp_frame(4'd6, IP_A, 16'd5000, 24, 8'h66);
        expect_accepted(IP_A, 16'd5000, 16'd24);
        send_frame;

        gap(12);

        check(ring_full == 1'b0, "ring not full");
        n_drained = 0;
        prev_ts = 64'd0;
        @(negedge clk);
        while (ring_desc_valid && n_drained < 8) begin
            if (n_drained < n_exp) begin
                check(ring_desc_ip == exp_ip[n_drained],
                      "drain: dst IP matches");
                check(ring_desc_port == exp_port[n_drained],
                      "drain: dst port matches");
                check(ring_desc_len == exp_len[n_drained],
                      "drain: payload_len matches");
                check(ring_desc_payload_addr == exp_addr[n_drained][11:0],
                      "drain: payload addr matches");
                check(ring_desc_timestamp > prev_ts,
                      "drain: timestamp monotonically increasing");
                prev_ts = ring_desc_timestamp;
                // payload bytes: full FCS-stripped frame at payload_addr
                bytes_ok = 1;
                for (j = 0; j < exp_stored[n_drained]; j = j + 1)
                    if (u_rx_descriptor_ring.payload_mem[
                            (exp_addr[n_drained] + j) & 4095]
                            !== exp_stream[exp_addr[n_drained] + j])
                        bytes_ok = 0;
                check(bytes_ok, "drain: payload bytes match sent frame");
            end
            // pop
            @(posedge clk);
            #1 sw_ren = 1;
            @(posedge clk);
            #1 sw_ren = 0;
            n_drained = n_drained + 1;
            @(negedge clk);
        end
        check(n_drained == n_exp,
              "exactly the matching good frames landed in the ring");
        check(ring_desc_valid == 1'b0, "ring empty after drain");
        check(ring_head_ptr == ring_tail_ptr, "head == tail after drain");

        // --- summary ---
        $display("");
        if (fail_count == 0)
            $display("tb_top_integration: ALL %0d TESTS PASSED", pass_count);
        else
            $display("tb_top_integration: %0d PASSED, %0d FAILED",
                     pass_count, fail_count);
        $finish;
    end

endmodule
