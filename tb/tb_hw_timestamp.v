`timescale 1ns/1ps

module tb_hw_timestamp;

    reg clk;
    reg rst;
    reg macrx_sof;

    wire [63:0] hwts_counter;
    wire [63:0] hwts_value;
    wire        hwts_valid;

    hw_timestamp dut (
        .clk          (clk),
        .rst          (rst),
        .macrx_sof    (macrx_sof),
        .hwts_counter (hwts_counter),
        .hwts_value   (hwts_value),
        .hwts_valid   (hwts_valid)
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

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    reg [63:0] snap_a, snap_b, held;

    initial begin
        $dumpfile("sim/tb_hw_timestamp.vcd");
        $dumpvars(0, tb_hw_timestamp);

        macrx_sof = 0;
        rst = 1;
        repeat (2) @(posedge clk);
        #1 rst = 0;

        @(negedge clk);
        snap_a = hwts_counter;
        @(negedge clk);
        check(hwts_counter == snap_a + 1, "counter increments every cycle");
        @(negedge clk);
        check(hwts_counter == snap_a + 2, "counter keeps incrementing");
        check(hwts_valid == 1'b0, "hwts_valid low with no sof");

        @(posedge clk);
        #1 macrx_sof = 1;
        @(negedge clk);
        snap_a = hwts_counter;       // counter value visible during sof cycle
        @(posedge clk);
        #1 macrx_sof = 0;
        @(negedge clk);              // cycle after sof
        check(hwts_valid == 1'b1, "hwts_valid pulses the cycle after sof");
        check(hwts_value == snap_a, "hwts_value latched counter at sof cycle");
        @(negedge clk);
        check(hwts_valid == 1'b0, "hwts_valid is a one-cycle pulse");

        held = hwts_value;
        repeat (20) begin
            @(negedge clk);
            check(hwts_value == held, "hwts_value stable between sofs");
        end

        @(posedge clk);
        #1 macrx_sof = 1;
        @(negedge clk);
        snap_b = hwts_counter;
        @(posedge clk);
        #1 macrx_sof = 0;
        @(negedge clk);
        check(hwts_valid == 1'b1, "second sof: valid pulse");
        check(hwts_value == snap_b, "second sof: value re-latched");
        check(hwts_value > held, "timestamps monotonically increase");

        @(posedge clk);
        #1 rst = 1;
        @(posedge clk);
        @(negedge clk);
        check(hwts_counter == 64'd0, "reset clears counter");
        check(hwts_value == 64'd0, "reset clears value");
        check(hwts_valid == 1'b0, "reset clears valid");
        #1 rst = 0;

        $display("");
        if (fail_count == 0)
            $display("tb_hw_timestamp: ALL %0d TESTS PASSED", pass_count);
        else
            $display("tb_hw_timestamp: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $finish;
    end

endmodule
