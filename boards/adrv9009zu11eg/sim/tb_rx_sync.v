// =============================================================================
// tb_rx_sync - pps_counter + pps_rx_sync_mux + ADI util_ext_sync (the RX TPL's
// external-sync logic, compiled from the ADI HDL tree).
//
// Checks, with a periodic SYSREF running the whole time:
//   1. Not armed: SYSREF still starts the TPL (ADI's multi-SOM start intact).
//   2. GPS window armed: SYSREF edges are ignored; the TPL starts exactly when
//      the PPS-anchored window opens, every "second", at a fixed offset from
//      LATCH_COUNT; LATCH_COUNT - PPS_COUNT = RX_START + const.
//   3. The same at RX_START = 0 (window opens on the PPS edge itself).
// A simulated "second" is SEC cnt_clk cycles to keep the run short.
// =============================================================================
`timescale 1ns/1ps

module tb_rx_sync;
    localparam integer SEC = 20000;          // cnt_clk cycles per simulated second

    reg cnt_clk = 0, aclk = 0;
    always #2.0345 cnt_clk = ~cnt_clk;       // 245.76 MHz (core_clk_b)
    always #5      aclk    = ~aclk;          // 100 MHz AXI

    reg cnt_resetn = 0, aresetn = 0;

    // ---- PPS: 100-cycle pulse every SEC cycles, first edge after 3000 ----
    integer pps_div = SEC - 3000;
    reg pps = 0;
    always @(posedge cnt_clk) begin
        pps_div <= (pps_div == SEC - 1) ? 0 : pps_div + 1;
        pps     <= (pps_div < 100);
    end

    // ---- SYSREF: 50 % square wave, period 320 cycles (768 kHz) ----
    integer sr_div = 0;
    reg sysref = 0;
    always @(posedge cnt_clk) begin
        sr_div <= (sr_div == 319) ? 0 : sr_div + 1;
        sysref <= (sr_div < 160);
    end

    // ---- DUT ----
    reg  [6:0]  awaddr = 0, araddr = 0;
    reg  [31:0] wdata = 0;
    reg         awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;
    wire        tdd_enable, tdd_armed, sync_out, sync_armed;

    pps_counter dut (
        .cnt_clk(cnt_clk), .cnt_resetn(cnt_resetn), .pps_in(pps),
        .latch_trig(sync_out), .gpio_out(), .tdd_sync(), .tdd_enable(tdd_enable),
        .tdd_txnrx(), .pps_tick(), .tdd_armed(tdd_armed),
        .s_axi_aclk(aclk), .s_axi_aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready));

    pps_rx_sync_mux mux (.armed(tdd_armed), .window(tdd_enable), .sysref(sysref), .sync_out(sync_out));

    reg ext_arm = 0;
    util_ext_sync #(.ENABLED(1)) tpl_sync (
        .clk(cnt_clk), .ext_sync_arm(ext_arm), .ext_sync_disarm(1'b0),
        .sync_in(sync_out), .sync_armed(sync_armed));

    // ---- AXI4-Lite tasks ----
    task axi_write(input [6:0] a, input [31:0] d);
        begin
            @(posedge aclk); awaddr <= a; wdata <= d; awvalid <= 1; wvalid <= 1;
            wait (awready && wready); @(posedge aclk); awvalid <= 0; wvalid <= 0;
            wait (bvalid); @(posedge aclk);
        end
    endtask
    task axi_read(input [6:0] a, output [31:0] d);
        begin
            @(posedge aclk); araddr <= a; arvalid <= 1;
            wait (arready); @(posedge aclk); arvalid <= 0;
            wait (rvalid); d = rdata; @(posedge aclk);
        end
    endtask

    // ---- the TPL's first valid sample: the first cycle sync_armed is low ----
    reg [31:0] start_count = 0;
    reg        started = 0, watch = 0;
    always @(posedge cnt_clk)
        if (watch && !sync_armed && !started) begin
            start_count <= dut.counter; started <= 1;
        end

    task arm_tpl;                       // = sync_start_enable "arm" on the TPL device
        begin
            started = 0; watch = 0;
            @(posedge cnt_clk); ext_arm <= 1;
            repeat (4) @(posedge cnt_clk); ext_arm <= 0;
            wait (sync_armed); watch = 1;
        end
    endtask

    task wait_pps_edge;   // returns just after a PPS rising edge (cnt domain)
        begin
            @(posedge pps); repeat (8) @(posedge cnt_clk);
        end
    endtask

    integer errors = 0;
    reg [31:0] v, ppsc, lc, lseq0, lseq1;
    integer sec, d, s_off;

    task gated_capture(input [31:0] rx_start, input integer seconds);
        integer expect_d;
        begin
            axi_write(7'h1C, 0);                    // TDD_CTRL off while reprogramming
            axi_write(7'h20, SEC);                  // FRAME_LEN = one "second"
            axi_write(7'h24, rx_start);             // RX_START
            axi_write(7'h28, rx_start + 4000);      // RX_STOP
            axi_write(7'h1C, 32'h7);                // enable | pps_sync_en | drive_pins
            expect_d = -1;
            for (sec = 0; sec < seconds; sec = sec + 1) begin
                wait_pps_edge;                      // arm mid-second, before the target PPS,
                repeat (SEC / 2) @(posedge cnt_clk); // like the daemon's ARM_LEAD_S
                axi_read(7'h40, lseq0);
                arm_tpl;
                wait (started);
                repeat (20) @(posedge aclk);        // let the latch cross into the AXI domain
                axi_read(7'h10, ppsc);
                axi_read(7'h3C, lc);
                axi_read(7'h40, lseq1);
                d = lc - ppsc;
                s_off = start_count - lc;
                $display("  RX_START=%0d second %0d: LATCH-PPS = %0d, TPL start - LATCH = %0d, LATCH_SEQ +%0d",
                         rx_start, sec, d, s_off, lseq1 - lseq0);
                if (lseq1 - lseq0 != 1) begin errors = errors + 1; $display("  FAIL: expected exactly one latch"); end
                if (expect_d < 0) expect_d = d;
                if (d != expect_d) begin errors = errors + 1; $display("  FAIL: offset moved"); end
                if (d < rx_start || d > rx_start + 4) begin errors = errors + 1; $display("  FAIL: latch not at the window"); end
                if (s_off != 2) begin errors = errors + 1; $display("  FAIL: TPL start not 2 cycles after the latch"); end
            end
            axi_write(7'h1C, 0);
        end
    endtask

    initial begin
        repeat (20) @(posedge aclk);
        cnt_resetn = 1; aresetn = 1;
        repeat (20) @(posedge aclk);

        axi_read(7'h00, v);
        if (v !== 32'h50505343) begin errors = errors + 1; $display("FAIL: ID %h", v); end

        // 1. Not armed: SYSREF starts the TPL within one SYSREF period.
        $display("1. GPS window not armed: SYSREF passes through");
        wait_pps_edge;
        arm_tpl;
        repeat (400) @(posedge cnt_clk);
        if (!started) begin errors = errors + 1; $display("  FAIL: SYSREF did not start the TPL"); end
        else $display("  ok: TPL started by SYSREF");

        // 2./3. GPS-gated captures
        $display("2. GPS window armed, RX_START = 5000, SYSREF running");
        gated_capture(5000, 3);
        $display("3. GPS window armed, RX_START = 0 (opens on the PPS edge)");
        gated_capture(0, 3);

        if (errors == 0) $display("PASS tb_rx_sync");
        else             $display("FAIL tb_rx_sync: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #20_000_000; $display("FAIL tb_rx_sync: timeout"); $finish;
    end
endmodule
