`timescale 1ns/1ps
module tb_pps_reset;
    reg cnt_clk = 0;
    reg axi_clk = 0;
    reg resetn = 0;
    reg pps = 0;
    always #2 cnt_clk = ~cnt_clk;
    always #5 axi_clk = ~axi_clk;
    pps_counter dut (
        .cnt_clk(cnt_clk), .cnt_resetn(resetn), .pps_in(pps), .latch_trig(1'b0),
        .s_axi_aclk(axi_clk), .s_axi_aresetn(resetn),
        .s_axi_awaddr(7'b0), .s_axi_awprot(3'b0), .s_axi_awvalid(1'b0),
        .s_axi_wdata(32'b0), .s_axi_wstrb(4'b0), .s_axi_wvalid(1'b0),
        .s_axi_bready(1'b1), .s_axi_araddr(7'b0), .s_axi_arprot(3'b0),
        .s_axi_arvalid(1'b0), .s_axi_rready(1'b1)
    );
    task check_release;
        input real phase;
        begin
            @(negedge cnt_clk);
            #(phase) resetn = 1;
            @(posedge cnt_clk); #0.01;
            if (dut.cnt_resetn_local !== 0 || dut.counter !== 0)
                $fatal(1, "Reset released before both synchronizer stages settled");
            @(posedge cnt_clk); #0.01;
            if (dut.cnt_resetn_local !== 1 || dut.counter !== 0)
                $fatal(1, "Reset release did not occur on second cnt_clk edge");
            repeat (12) @(posedge cnt_clk);
            #0.01;
            if (dut.counter == 0) $fatal(1, "Counter did not resume after reset");
        end
    endtask
    initial begin
        #0.3;
        check_release(0.7);
        // Assert between RX clock edges: immediate reset is required.
        @(negedge cnt_clk); #0.4 resetn = 0; #0.01;
        if (dut.cnt_resetn_local !== 0 || dut.counter !== 0 || dut.frame_cnt !== 0)
            $fatal(1, "Asynchronous reset assertion was delayed");
        check_release(1.3);
        repeat (20) @(negedge cnt_clk);
        pps = 1;
        repeat (8) @(negedge cnt_clk);
        pps = 0;
        repeat (8) @(negedge cnt_clk);
        if (dut.pps_seq !== 1 || dut.pps_count == 0)
            $fatal(1, "PPS counting/latching changed after reset synchronization");
        $display("PPS_RESET_AND_EDGE_TEST_PASS");
        $finish;
    end
    initial begin
        #2000;
        $fatal(1, "Test timed out");
    end
endmodule
