// =============================================================================
// pps_rx_sync_mux - select the external-sync source of the RX transport layer.
//
// ADI's ADRV9009-ZU11EG design drives the RX TPL core's adc_sync_in from SYSREF
// (its multi-SOM start). While pps_counter has a GPS window armed
// (TDD_CTRL enable & drive_pins -> tdd_armed), pass the PPS-anchored window
// instead, so a stray SYSREF pulse cannot start the capture. Otherwise SYSREF
// passes through unchanged and ADI's multi-SOM start keeps working.
//
// Purely combinational: no added latency on either path. The same signal
// drives pps_counter's latch_trig, so LATCH_COUNT holds the count of the cycle
// the window opens. The TPL's util_ext_sync registers sync_in twice and
// disarms on the rising edge, so its first valid sample comes 2 core_clk_b
// cycles later (checked by sim/tb_rx_sync.v). The RF-to-TPL latency on top of
// that is fixed and is calibrated once (docs/ADRV9009_ZU11EG.md).
// =============================================================================
`timescale 1ns/1ps

module pps_rx_sync_mux (
    input  wire armed,     // pps_counter/tdd_armed
    input  wire window,    // pps_counter/tdd_enable (PPS-anchored RX window)
    input  wire sysref,    // ADI's rx_sysref_0
    output wire sync_out   // -> RX TPL adc_sync_in and pps_counter/latch_trig
);
    assign sync_out = armed ? window : sysref;
endmodule
