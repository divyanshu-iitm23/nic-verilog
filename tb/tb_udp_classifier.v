`timescale 1ns/1ps

module tb_udp_classifier;

    reg        clk;
    reg        rst;
    reg [7:0]  macrx_data;
    reg        macrx_data_valid;
    reg        macrx_sof;
    reg        macrx_eof;
    reg        macrx_frame_ok;

    reg        cfg_wr_en;
    reg [3:0]  cfg_wr_idx;
    reg [31:0] cfg_dst_ip;
    reg [15:0] cfg_dst_port;
    reg        cfg_entry_en;

    wire        classifier_valid;
    wire        classifier_accept;
    wire [31:0] classifier_dst_ip;
    wire [15:0] classifier_dst_port;
    wire [15:0] classifier_payload_len;

    udp_classifier dut (
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

    reg [7:0] frame_buf [0:255];
    integer   flen;

    task build_udp_frame(input [3:0] ihl_a, input [31:0] dip,
                         input [15:0] dport, input integer plen);
        integer i, udp_off, ip_totlen;
        begin
            // dest MAC (multicast-style) + src MAC
            frame_buf[0] = 8'h01; frame_buf[1] = 8'h00; frame_buf[2] = 8'h5E;
            frame_buf[3] = 8'h11; frame_buf[4] = 8'h22; frame_buf[5] = 8'h33;
            frame_buf[6] = 8'h02; frame_buf[7] = 8'hAA; frame_buf[8] = 8'hBB;
            frame_buf[9] = 8'hCC; frame_buf[10] = 8'hDD; frame_buf[11] = 8'hEE;
            // ethertype IPv4
            frame_buf[12] = 8'h08; frame_buf[13] = 8'h00;
            // IP header
            ip_totlen = ihl_a * 4 + 8 + plen;
            frame_buf[14] = {4'd4, ihl_a};
            frame_buf[15] = 8'h00;                        // TOS
            frame_buf[16] = ip_totlen[15:8];
            frame_buf[17] = ip_totlen[7:0];
            frame_buf[18] = 8'h00; frame_buf[19] = 8'h01; // ID
            frame_buf[20] = 8'h00; frame_buf[21] = 8'h00; // flags/frag
            frame_buf[22] = 8'd64;                        // TTL
            frame_buf[23] = 8'd17;                        // protocol = UDP
            frame_buf[24] = 8'h00; frame_buf[25] = 8'h00; // csum (unchecked)
            frame_buf[26] = 8'd10; frame_buf[27] = 8'd0;  // src IP 10.0.0.1
            frame_buf[28] = 8'd0;  frame_buf[29] = 8'd1;
            frame_buf[30] = dip[31:24]; frame_buf[31] = dip[23:16];
            frame_buf[32] = dip[15:8];  frame_buf[33] = dip[7:0];
            // IP options (IHL > 5): NOP bytes
            for (i = 34; i < 14 + ihl_a * 4; i = i + 1)
                frame_buf[i] = 8'h01;
            // UDP header at the IHL-dependent offset
            udp_off = 14 + ihl_a * 4;
            frame_buf[udp_off]   = 8'h30; frame_buf[udp_off+1] = 8'h39; // sport
            frame_buf[udp_off+2] = dport[15:8];
            frame_buf[udp_off+3] = dport[7:0];
            frame_buf[udp_off+4] = (plen + 8) >> 8;
            frame_buf[udp_off+5] = (plen + 8) & 255;
            frame_buf[udp_off+6] = 8'h00; frame_buf[udp_off+7] = 8'h00; // csum
            // payload
            for (i = 0; i < plen; i = i + 1)
                frame_buf[udp_off + 8 + i] = 8'h40 + i[7:0];
            flen = udp_off + 8 + plen;
            // Ethernet min-frame padding (mac_rx delivers >= 60 bytes)
            while (flen < 60) begin
                frame_buf[flen] = 8'h00;
                flen = flen + 1;
            end
        end
    endtask

    integer    got_valid;
    reg        got_accept;
    reg [31:0] got_ip;
    reg [15:0] got_port;
    reg [15:0] got_plen;

    always @(negedge clk) begin
        if (classifier_valid) begin
            got_valid  = got_valid + 1;
            got_accept = classifier_accept;
            got_ip     = classifier_dst_ip;
            got_port   = classifier_dst_port;
            got_plen   = classifier_payload_len;
        end
    end

    task drive_frame(input frame_ok);
        integer i;
        begin
            got_valid = 0;
            for (i = 0; i < flen; i = i + 1) begin
                @(posedge clk);
                #1;
                macrx_data       = frame_buf[i];
                macrx_data_valid = 1;
                macrx_sof        = (i == 0);
                macrx_eof        = (i == flen - 1);
                macrx_frame_ok   = (i == flen - 1) ? frame_ok : 1'b0;
            end
            @(posedge clk);
            #1;
            macrx_data_valid = 0; macrx_sof = 0;
            macrx_eof = 0; macrx_frame_ok = 0;
            repeat (2) @(posedge clk);
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

    localparam [31:0] IP_A = {8'd239, 8'd1, 8'd1, 8'd1};    // 239.1.1.1
    localparam [31:0] IP_B = {8'd239, 8'd2, 8'd2, 8'd2};    // 239.2.2.2
    localparam [15:0] PORT_A = 16'd5000;
    localparam [15:0] PORT_B = 16'd6000;

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        $dumpfile("sim/tb_udp_classifier.vcd");
        $dumpvars(0, tb_udp_classifier);

        macrx_data = 0; macrx_data_valid = 0; macrx_sof = 0;
        macrx_eof = 0; macrx_frame_ok = 0;
        cfg_wr_en = 0; cfg_wr_idx = 0; cfg_dst_ip = 0;
        cfg_dst_port = 0; cfg_entry_en = 0;
        got_valid = 0;

        rst = 1;
        repeat (2) @(posedge clk);
        #1 rst = 0;
        repeat (2) @(posedge clk);

        cfg_write(4'd0, IP_A, PORT_A, 1'b1);

        build_udp_frame(4'd5, IP_A, PORT_A, 32);
        drive_frame(1'b1);
        check(got_valid == 1, "match ihl5: one decision per frame");
        check(got_accept === 1'b1, "match ihl5: accepted");
        check(got_ip == IP_A, "match ihl5: dst_ip extracted");
        check(got_port == PORT_A, "match ihl5: dst_port extracted");
        check(got_plen == 16'd32, "match ihl5: payload_len = udp_len - 8");

        build_udp_frame(4'd6, IP_A, PORT_A, 48);
        drive_frame(1'b1);
        check(got_valid == 1 && got_accept === 1'b1, "match ihl6: accepted");
        check(got_port == PORT_A, "match ihl6: dst_port at shifted offset");
        check(got_plen == 16'd48, "match ihl6: payload_len");

        build_udp_frame(4'd7, IP_A, PORT_A, 16);
        drive_frame(1'b1);
        check(got_accept === 1'b1, "match ihl7: accepted");
        check(got_plen == 16'd16, "match ihl7: payload_len");

        build_udp_frame(4'd5, IP_A, PORT_A + 16'd1, 32);
        drive_frame(1'b1);
        check(got_valid == 1 && got_accept === 1'b0, "wrong port: rejected");

        build_udp_frame(4'd5, IP_B, PORT_A, 32);
        drive_frame(1'b1);
        check(got_accept === 1'b0, "wrong IP: rejected");

        build_udp_frame(4'd5, IP_A, PORT_A, 32);
        frame_buf[12] = 8'h86; frame_buf[13] = 8'hDD;     // IPv6
        drive_frame(1'b1);
        check(got_accept === 1'b0, "non-IPv4 ethertype: rejected");

        build_udp_frame(4'd5, IP_A, PORT_A, 32);
        frame_buf[23] = 8'd6;                             // TCP
        drive_frame(1'b1);
        check(got_accept === 1'b0, "non-UDP protocol: rejected");

        build_udp_frame(4'd5, IP_A, PORT_A, 32);
        drive_frame(1'b0);
        check(got_valid == 1, "bad frame: decision still fires at eof");
        check(got_accept === 1'b0, "bad frame: rejected despite match");

        cfg_write(4'd3, IP_B, PORT_B, 1'b0);
        build_udp_frame(4'd5, IP_B, PORT_B, 24);
        drive_frame(1'b1);
        check(got_accept === 1'b0, "disabled entry: rejected");
        cfg_write(4'd3, IP_B, PORT_B, 1'b1);
        drive_frame(1'b1);
        check(got_accept === 1'b1, "enabled entry: accepted");

        cfg_write(4'd0, IP_A, PORT_B, 1'b1);              // was IP_A:PORT_A
        build_udp_frame(4'd5, IP_A, PORT_A, 32);
        drive_frame(1'b1);
        check(got_accept === 1'b0, "overwritten entry: old port rejected");
        build_udp_frame(4'd5, IP_A, PORT_B, 32);
        drive_frame(1'b1);
        check(got_accept === 1'b1, "overwritten entry: new port accepted");

        $display("");
        if (fail_count == 0)
            $display("tb_udp_classifier: ALL %0d TESTS PASSED", pass_count);
        else
            $display("tb_udp_classifier: %0d PASSED, %0d FAILED",
                     pass_count, fail_count);
        $finish;
    end

endmodule
