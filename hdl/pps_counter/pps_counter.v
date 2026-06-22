// =============================================================================
// pps_counter.v  -  GPS-timing helper for Pluto+ (xo_correction / TDOA)
//
// A free-running counter clocked by `cnt_clk` (wire this to the AD9361/63 sample
// clock so it measures the AD936x reference that xo_correction tunes), with an
// OPTIONAL hardware latch on a PPS rising edge. Exposed as an AXI4-Lite slave.
//
// Two usage modes (the IP supports both; pick per how you wire `pps_in`):
//   * SOFTWARE latch (no extra FPGA pin): leave pps_in tied 0; read LIVE_COUNT
//     from the PPS IRQ handler (/dev/pps0 on MIO9). ~us jitter -> fine for
//     frequency discipline (xo_correction).
//   * HARDWARE latch (needs PPS routed to a PL pin): drive pps_in; read
//     PPS_COUNT/PPS_DELTA -> sample-accurate (1 cnt_clk period), for TDOA.
//
// Register map (AXI4-Lite, 32-bit words, offset from base):
//   0x00 ID        RO  0x50505343 ("PPSC")
//   0x04 CTRL      RW  bit0 enable(1=run, default 1), bit1 clear(self-clearing)
//   0x08 STATUS    RO  bit0 pps_present(1 if >=1 PPS edge seen)
//   0x0C LIVE_COUNT RO current free-running counter (CDC-synced snapshot)
//   0x10 PPS_COUNT RO  counter latched at the last PPS rising edge
//   0x14 PPS_DELTA RO  PPS_COUNT(n) - PPS_COUNT(n-1)  (== cnt_clk Hz when locked)
//   0x18 PPS_SEQ   RO  number of PPS rising edges observed
//   --- PPS-aligned TDD frame timing (see TDD_PPS_DESIGN.md) ---
//   0x1C TDD_CTRL  RW  bit0 enable, bit1 pps_sync_en (reset frame on PPS),
//                      bit2 drive_pins (drive ENABLE/TXNRX), bit3 txnrx_pol, bit4 enable_pol
//   0x20 FRAME_LEN RW  frame length in cnt_clk samples (must divide samples/PPS)
//   0x24 RX_START  RW  RX window opens at this frame-count
//   0x28 RX_STOP   RW  RX window closes (window=[start,stop); 0 disables)
//   0x2C TX_START  RW  TX window opens
//   0x30 TX_STOP   RW  TX window closes (0 disables)
//   0x34 FRAME_POS RO  live frame counter (CDC-synced)
//   0x38 FRAME_SEQ RO  frames elapsed since the last PPS (confirms FRAME_LEN divides the second)
//   Configure while TDD disabled (TDD_CTRL.enable=0), then enable (CDC contract).
//
// Notes:
//   * 32-bit counter wraps ~107 s at 40 MHz / ~43 s at 100 MHz; far longer than
//     the 1 s PPS interval, and PPS_DELTA is computed modulo-2^32 so wrap is fine.
//   * LIVE_COUNT crosses clock domains via a Gray-code 2-FF synchronizer.
//   * PPS_* update at most once/sec (cnt_clk), so a simple 2-FF sync is safe.
// =============================================================================
`timescale 1ns/1ps

module pps_counter #(
    parameter integer C_S_AXI_ADDR_WIDTH = 6,
    parameter integer C_S_AXI_DATA_WIDTH = 32
) (
    // ---- counter clock domain ----
    input  wire                              cnt_clk,     // e.g. AD936x sample clk
    input  wire                              cnt_resetn,  // active-low reset
    input  wire                              pps_in,      // optional PPS (tie 0 if unused)
    output wire [1:0]                        gpio_out,    // CTRL[5:4]: test outputs (I/O voltage probe)

    // ---- PPS-aligned TDD frame timing (cnt_clk domain) ----
    // tdd_sync is a 1-cyc pulse at each frame start, re-anchored to the GPS second
    // on every PPS edge -> feed it to ADI's TDD/ENSM controller as its sync (Opt A).
    // tdd_enable/tdd_txnrx optionally drive ENABLE/TXNRX directly (Opt B, drive_pins).
    output wire                              tdd_sync,
    output wire                              tdd_enable,
    output wire                              tdd_txnrx,
    // 1-cyc pulse on every PPS rising edge (l_clk domain). Independent of the TDD
    // frame logic -> drives ADI axi_tdd's sync_in to GPS-anchor its frame counter.
    output wire                              pps_tick,

    // ---- AXI4-Lite slave (FCLK / s_axi_aclk domain) ----
    input  wire                              s_axi_aclk,
    input  wire                              s_axi_aresetn,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  wire [2:0]                        s_axi_awprot,
    input  wire                              s_axi_awvalid,
    output reg                               s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  wire                              s_axi_wvalid,
    output reg                               s_axi_wready,
    output reg  [1:0]                        s_axi_bresp,
    output reg                               s_axi_bvalid,
    input  wire                              s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
    input  wire [2:0]                        s_axi_arprot,
    input  wire                              s_axi_arvalid,
    output reg                               s_axi_arready,
    output reg  [C_S_AXI_DATA_WIDTH-1:0]     s_axi_rdata,
    output reg  [1:0]                        s_axi_rresp,
    output reg                               s_axi_rvalid,
    input  wire                              s_axi_rready
);

    // ----------------------------------------------------------------- //
    // Control bits live in the AXI domain, synced into the counter domain
    // ----------------------------------------------------------------- //
    reg        ctrl_enable = 1'b1;
    reg        ctrl_clear  = 1'b0;     // pulse
    reg  [1:0] ctrl_gpio   = 2'b00;    // CTRL[5:4] -> gpio_out (I/O voltage test)
    assign     gpio_out    = ctrl_gpio;
    reg  [1:0] en_sync, clr_sync;
    always @(posedge cnt_clk) begin
        en_sync  <= {en_sync[0],  ctrl_enable};
        clr_sync <= {clr_sync[0], ctrl_clear};
    end
    wire cnt_en  = en_sync[1];
    wire cnt_clr = clr_sync[1];

    // ----------------------------------------------------------------- //
    // TDD config (AXI domain). CDC contract: write these while TDD is
    // DISABLED (tdd_ctrl[0]=0); the cnt_clk side only consumes them once the
    // synced enable is high, by which point the buses are long stable (no
    // multi-bit skew). Reconfigure = disable, write, re-enable.
    // ----------------------------------------------------------------- //
    reg  [4:0]  tdd_ctrl  = 5'd0;   // 0 enable, 1 pps_sync_en, 2 drive_pins, 3 txnrx_pol, 4 enable_pol
    reg  [31:0] frame_len = 32'd0;  // frame length in cnt_clk samples (must divide samples/PPS)
    reg  [31:0] rx_start  = 32'd0;
    reg  [31:0] rx_stop   = 32'd0;  // RX window = [rx_start, rx_stop); disabled when rx_stop==0
    reg  [31:0] tx_start  = 32'd0;
    reg  [31:0] tx_stop   = 32'd0;  // TX window = [tx_start, tx_stop); disabled when tx_stop==0

    // 2-FF sync config into cnt_clk (stable-while-enabled contract above)
    reg  [4:0]  tdc_s1, tdc_s2;
    reg  [31:0] flen_s1, flen_s2, rxa_s1, rxa_s2, rxo_s1, rxo_s2, txa_s1, txa_s2, txo_s1, txo_s2;
    always @(posedge cnt_clk) begin
        tdc_s1  <= tdd_ctrl;  tdc_s2  <= tdc_s1;
        flen_s1 <= frame_len; flen_s2 <= flen_s1;
        rxa_s1  <= rx_start;  rxa_s2  <= rxa_s1;
        rxo_s1  <= rx_stop;   rxo_s2  <= rxo_s1;
        txa_s1  <= tx_start;  txa_s2  <= txa_s1;
        txo_s1  <= tx_stop;   txo_s2  <= txo_s1;
    end
    wire        tdd_en    = tdc_s2[0];
    wire        tdd_ppsr  = tdc_s2[1];   // re-anchor frame on PPS
    wire        tdd_drive = tdc_s2[2];
    wire        tdd_txpol = tdc_s2[3];
    wire        tdd_enpol = tdc_s2[4];

    // ----------------------------------------------------------------- //
    // Counter domain: free-run counter + PPS edge detect + latch
    // ----------------------------------------------------------------- //
    reg  [31:0] counter   = 32'd0;
    reg  [31:0] pps_count = 32'd0;
    reg  [31:0] pps_prev  = 32'd0;
    reg  [31:0] pps_delta = 32'd0;
    reg  [31:0] pps_seq   = 32'd0;
    reg  [1:0]  pps_meta  = 2'b00;     // sync PPS into cnt_clk
    reg         pps_d     = 1'b0;
    reg         pps_tick_r = 1'b0;     // registered 1-cyc PPS-edge pulse -> axi_tdd sync
    wire        pps_s     = pps_meta[1];
    wire        pps_rise  = pps_s & ~pps_d;
    assign      pps_tick  = pps_tick_r;

    always @(posedge cnt_clk or negedge cnt_resetn) begin
        if (!cnt_resetn) begin
            counter <= 0; pps_count <= 0; pps_prev <= 0;
            pps_delta <= 0; pps_seq <= 0; pps_meta <= 0; pps_d <= 0; pps_tick_r <= 0;
        end else begin
            pps_meta <= {pps_meta[0], pps_in};
            pps_d    <= pps_s;
            pps_tick_r <= pps_rise;
            if (cnt_clr) counter <= 0;
            else if (cnt_en) counter <= counter + 32'd1;
            if (pps_rise) begin
                pps_count <= counter;
                pps_prev  <= pps_count;
                pps_delta <= counter - pps_count;  // modulo 2^32
                pps_seq   <= pps_seq + 32'd1;
            end
        end
    end

    // ----------------------------------------------------------------- //
    // PPS-aligned TDD frame counter (cnt_clk domain). Counts samples per frame
    // and reloads 0 on the PPS edge (re-anchor to the GPS second) -> frame phase
    // is common across nodes to +-1 cnt_clk. sync_pulse is a 1-cyc frame-start
    // marker for ADI's TDD controller; in_tx/in_rx drive ENABLE/TXNRX in Opt B.
    // ----------------------------------------------------------------- //
    reg  [31:0] frame_cnt  = 32'd0;
    reg  [31:0] frame_seq  = 32'd0;     // frames since last PPS (resets on PPS)
    reg         sync_pulse = 1'b0;
    wire        frame_wrap = (frame_cnt >= (flen_s2 - 32'd1));
    always @(posedge cnt_clk or negedge cnt_resetn) begin
        if (!cnt_resetn) begin
            frame_cnt <= 0; frame_seq <= 0; sync_pulse <= 0;
        end else begin
            sync_pulse <= 1'b0;
            if (!tdd_en || flen_s2 == 32'd0) begin
                frame_cnt <= 0; frame_seq <= 0;
            end else if (pps_rise && tdd_ppsr) begin
                frame_cnt <= 0; frame_seq <= 0; sync_pulse <= 1'b1;  // GPS re-anchor
            end else if (frame_wrap) begin
                frame_cnt <= 0; frame_seq <= frame_seq + 32'd1; sync_pulse <= 1'b1;
            end else begin
                frame_cnt <= frame_cnt + 32'd1;
            end
        end
    end

    wire in_rx = tdd_en & (rxo_s2 != 32'd0) & (frame_cnt >= rxa_s2) & (frame_cnt < rxo_s2);
    wire in_tx = tdd_en & (txo_s2 != 32'd0) & (frame_cnt >= txa_s2) & (frame_cnt < txo_s2);
    assign tdd_sync   = sync_pulse;
    assign tdd_txnrx  = tdd_drive ? (in_tx ^ tdd_txpol)        : 1'b0;
    assign tdd_enable = tdd_drive ? ((in_tx | in_rx) ^ tdd_enpol) : 1'b0;

    // FRAME_POS CDC: Gray-code (changes every cnt_clk), like live_count
    reg [31:0] fgray;
    always @(posedge cnt_clk) fgray <= bin2gray(frame_cnt);
    reg [31:0] fgray_s1, fgray_s2;
    always @(posedge s_axi_aclk) begin fgray_s1 <= fgray; fgray_s2 <= fgray_s1; end
    wire [31:0] frame_pos = gray2bin(fgray_s2);
    // FRAME_SEQ changes <= once/frame -> 2-FF sync
    reg [31:0] fseq_s1, fseq_s2;
    always @(posedge s_axi_aclk) begin fseq_s1 <= frame_seq; fseq_s2 <= fseq_s1; end

    // ----------------------------------------------------------------- //
    // LIVE_COUNT CDC: Gray-code the free-run counter, 2-FF sync, ungray
    // ----------------------------------------------------------------- //
    function [31:0] bin2gray(input [31:0] b); bin2gray = b ^ (b >> 1); endfunction
    function [31:0] gray2bin(input [31:0] g);
        integer i; reg [31:0] b;
        begin b[31] = g[31];
              for (i=30;i>=0;i=i-1) b[i] = b[i+1] ^ g[i];
              gray2bin = b; end
    endfunction

    reg [31:0] gray_cnt;
    always @(posedge cnt_clk) gray_cnt <= bin2gray(counter);
    reg [31:0] gray_s1, gray_s2;
    always @(posedge s_axi_aclk) begin gray_s1 <= gray_cnt; gray_s2 <= gray_s1; end
    wire [31:0] live_count = gray2bin(gray_s2);

    // PPS_* change <=1/sec -> simple 2-FF sync into AXI domain
    reg [31:0] ppsc_s1, ppsc_s2, ppsd_s1, ppsd_s2, ppss_s1, ppss_s2;
    always @(posedge s_axi_aclk) begin
        ppsc_s1 <= pps_count; ppsc_s2 <= ppsc_s1;
        ppsd_s1 <= pps_delta; ppsd_s2 <= ppsd_s1;
        ppss_s1 <= pps_seq;   ppss_s2 <= ppss_s1;
    end
    wire        pps_present = (ppss_s2 != 32'd0);

    // ----------------------------------------------------------------- //
    // AXI4-Lite write channel
    // ----------------------------------------------------------------- //
    reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_q;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 0; s_axi_wready <= 0; s_axi_bvalid <= 0;
            s_axi_bresp <= 0; ctrl_enable <= 1'b1; ctrl_clear <= 1'b0; ctrl_gpio <= 2'b00;
            tdd_ctrl <= 5'd0; frame_len <= 32'd0;
            rx_start <= 32'd0; rx_stop <= 32'd0; tx_start <= 32'd0; tx_stop <= 32'd0;
        end else begin
            ctrl_clear <= 1'b0;  // auto-clear pulse
            // address latch
            if (!s_axi_awready && s_axi_awvalid && s_axi_wvalid) begin
                s_axi_awready <= 1'b1; awaddr_q <= s_axi_awaddr;
            end else s_axi_awready <= 1'b0;
            // data accept
            if (!s_axi_wready && s_axi_wvalid && s_axi_awvalid) s_axi_wready <= 1'b1;
            else s_axi_wready <= 1'b0;
            // perform write
            if (s_axi_awready && s_axi_awvalid && s_axi_wready && s_axi_wvalid) begin
                case (awaddr_q[5:2])
                    4'h1: begin                       // 0x04 CTRL
                        ctrl_enable <= s_axi_wdata[0];
                        ctrl_clear  <= s_axi_wdata[1];
                        ctrl_gpio   <= s_axi_wdata[5:4];
                    end
                    4'h7: tdd_ctrl  <= s_axi_wdata[4:0];  // 0x1C TDD_CTRL
                    4'h8: frame_len <= s_axi_wdata;       // 0x20 FRAME_LEN
                    4'h9: rx_start  <= s_axi_wdata;       // 0x24 RX_START
                    4'hA: rx_stop   <= s_axi_wdata;       // 0x28 RX_STOP
                    4'hB: tx_start  <= s_axi_wdata;       // 0x2C TX_START
                    4'hC: tx_stop   <= s_axi_wdata;       // 0x30 TX_STOP
                    default: ;
                endcase
                s_axi_bvalid <= 1'b1; s_axi_bresp <= 2'b00;
            end else if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
        end
    end

    // ----------------------------------------------------------------- //
    // AXI4-Lite read channel
    // ----------------------------------------------------------------- //
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 0; s_axi_rvalid <= 0; s_axi_rresp <= 0; s_axi_rdata <= 0;
        end else begin
            if (!s_axi_arready && s_axi_arvalid) s_axi_arready <= 1'b1;
            else s_axi_arready <= 1'b0;
            if (s_axi_arready && s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_rvalid <= 1'b1; s_axi_rresp <= 2'b00;
                case (s_axi_araddr[5:2])
                    4'h0: s_axi_rdata <= 32'h50505343;     // "PPSC"
                    4'h1: s_axi_rdata <= {26'd0, ctrl_gpio, 2'b00, ctrl_enable};
                    4'h2: s_axi_rdata <= {31'd0, pps_present};
                    4'h3: s_axi_rdata <= live_count;
                    4'h4: s_axi_rdata <= ppsc_s2;
                    4'h5: s_axi_rdata <= ppsd_s2;
                    4'h6: s_axi_rdata <= ppss_s2;
                    4'h7: s_axi_rdata <= {27'd0, tdd_ctrl};   // TDD_CTRL
                    4'h8: s_axi_rdata <= frame_len;           // FRAME_LEN
                    4'h9: s_axi_rdata <= rx_start;            // RX_START
                    4'hA: s_axi_rdata <= rx_stop;             // RX_STOP
                    4'hB: s_axi_rdata <= tx_start;            // TX_START
                    4'hC: s_axi_rdata <= tx_stop;             // TX_STOP
                    4'hD: s_axi_rdata <= frame_pos;           // FRAME_POS (live)
                    4'hE: s_axi_rdata <= fseq_s2;             // FRAME_SEQ (since PPS)
                    default: s_axi_rdata <= 32'd0;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
        end
    end

endmodule
