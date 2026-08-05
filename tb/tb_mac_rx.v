`timescale 1ns/1ps

module tb_mac_rx;

    reg        clk;
    reg        rst;
    reg [7:0]  phy_data;
    reg        phy_data_valid;

    wire [7:0] macrx_data;
    wire       macrx_data_valid;
    wire       macrx_sof;
    wire       macrx_eof;
    wire       macrx_frame_ok;
    wire       macrx_ready;

    mac_rx dut (
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

    reg [7:0] tx_buf [0:2047];   // frame contents incl. FCS
    integer   tx_len;

    task build_frame(input integer data_len, input [7:0] seed);
        integer i;
        reg [31:0] c;
        begin
            c = 32'hFFFFFFFF;
            for (i = 0; i < data_len; i = i + 1) begin
                tx_buf[i] = seed + i[7:0];
                c = crc32_step(c, tx_buf[i]);
            end
            c = ~c;
            tx_buf[data_len]   = c[7:0];
            tx_buf[data_len+1] = c[15:8];
            tx_buf[data_len+2] = c[23:16];
            tx_buf[data_len+3] = c[31:24];
            tx_len = data_len + 4;
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
            for (i = 0; i < tx_len; i = i + 1) begin
                @(posedge clk);
                #1 phy_data = tx_buf[i];
            end
            @(posedge clk);
            #1 phy_data_valid = 0; phy_data = 8'h00;
        end
    endtask

    reg [7:0] rx_buf [0:2047];
    integer   rx_len;
    integer   sof_count, eof_count;
    integer   sof_at, eof_at;      // rx_buf index where sof/eof were seen
    reg       last_frame_ok;

    always @(negedge clk) begin
        if (macrx_data_valid) begin
            rx_buf[rx_len] = macrx_data;
            if (macrx_sof) begin sof_count = sof_count + 1; sof_at = rx_len; end
            if (macrx_eof) eof_at = rx_len;
            rx_len = rx_len + 1;
        end
        if (macrx_eof) begin
            eof_count = eof_count + 1;
            last_frame_ok = macrx_frame_ok;
        end
    end

    task clear_capture;
        begin
            rx_len = 0; sof_count = 0; eof_count = 0;
            sof_at = -1; eof_at = -1; last_frame_ok = 1'bx;
        end
    endtask

    task drain;
        begin
            repeat (12) @(posedge clk);
        end
    endtask

    task check_frame(input integer exp_data_len, input exp_ok,
                     input [255:0] name);
        integer i;
        reg bytes_match;
        begin
            check(eof_count == 1, {name, ": exactly one eof"});
            check(rx_len == exp_data_len, {name, ": FCS-stripped length"});
            bytes_match = 1;
            for (i = 0; i < exp_data_len; i = i + 1)
                if (rx_buf[i] !== tx_buf[i]) bytes_match = 0;
            check(bytes_match, {name, ": payload bytes match"});
            check(sof_count == 1 && sof_at == 0, {name, ": sof on first byte"});
            check(eof_at == exp_data_len - 1, {name, ": eof on last byte"});
            check(last_frame_ok === exp_ok, {name, ": frame_ok"});
        end
    endtask

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    integer i;

    initial begin
        $dumpfile("sim/tb_mac_rx.vcd");
        $dumpvars(0, tb_mac_rx);

        phy_data = 0; phy_data_valid = 0;
        clear_capture;
        rst = 1;
        repeat (2) @(posedge clk);
        #1 rst = 0;
        repeat (2) @(posedge clk);

        clear_capture;
        build_frame(60, 8'h10);
        send_frame;
        drain;
        check_frame(60, 1'b1, "min frame");

        clear_capture;
        build_frame(200, 8'hA0);
        send_frame;
        drain;
        check_frame(200, 1'b1, "200B frame");

        clear_capture;
        build_frame(80, 8'h33);
        tx_buf[tx_len-1] = tx_buf[tx_len-1] ^ 8'hFF;
        send_frame;
        drain;
        check(eof_count == 1, "bad CRC: eof still fires");
        check(last_frame_ok === 1'b0, "bad CRC: frame_ok = 0");
        check(rx_len == 80, "bad CRC: bytes still stream (consumer drops)");

        clear_capture;
        build_frame(20, 8'h55);
        send_frame;
        drain;
        check(eof_count == 1, "runt: eof fires");
        check(last_frame_ok === 1'b0, "runt: frame_ok = 0");

        clear_capture;
        build_frame(1600, 8'h77);
        send_frame;
        drain;
        check(eof_count == 1, "oversize: eof fires");
        check(last_frame_ok === 1'b0, "oversize: frame_ok = 0");

        clear_capture;
        build_frame(60, 8'h01);
        send_frame;                  // send_frame ends with 1 low cycle
        build_frame(60, 8'h81);      // immediately re-drive preamble
        send_frame;
        drain;
        check(sof_count == 2, "back-to-back: two sofs");
        check(eof_count == 2, "back-to-back: two eofs");
        check(rx_len == 120, "back-to-back: both frames' bytes out");
        check(last_frame_ok === 1'b1, "back-to-back: second frame ok");
        // second frame's bytes are tx_buf of the *second* build
        begin : b2b_bytes
            reg m;
            m = 1;
            for (i = 0; i < 60; i = i + 1)
                if (rx_buf[60+i] !== tx_buf[i]) m = 0;
            check(m, "back-to-back: second frame bytes match");
        end

        clear_capture;
        for (i = 0; i < 30; i = i + 1) begin
            @(posedge clk);
            #1 phy_data = 8'hAA + i[7:0]; phy_data_valid = 1;
        end
        @(posedge clk);
        #1 phy_data_valid = 0;
        drain;
        check(rx_len == 0 && eof_count == 0, "noise without preamble ignored");

        clear_capture;
        build_frame(64, 8'hC3);
        send_frame;
        drain;
        check_frame(64, 1'b1, "frame after noise");

        $display("");
        if (fail_count == 0)
            $display("tb_mac_rx: ALL %0d TESTS PASSED", pass_count);
        else
            $display("tb_mac_rx: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $finish;
    end

endmodule
