`timescale 1ns / 1ps

// =============================================================================
// Module : sigmoid_tb.v   (CORRECTED)
// Purpose: Testbench for CORDIC-based sigmoid function
//
// Fixed-Point Format: Q2.14  (scale = 2^14 = 16384)
//
// ─── TWO BUGS FIXED FROM ORIGINAL ────────────────────────────────────────────
//
// BUG 1 - x_in was changing too early
// ─────────────────────────────────────
// ORIGINAL (wrong):
//   task run_test:
//     x_in = real_to_fixed(x_val);   ← x_in changes immediately at task start
//     @(posedge clk);
//     start = 1;                      ← start fires one cycle LATER
//
//   Effect in waveform:
//     x_in changes to 0.5 while x=0 computation is still running.
//     When sig_out finally shows the x=0 result, x_in already reads 0.5.
//     This makes it LOOK like x_in=0.5 → sig_out=0.5 (x=0 result), which
//     appears one test behind in the waveform viewer.
//
// FIX:
//   Set x_in and start=1 in the SAME clock cycle.
//   x_in only changes when a new computation actually begins.
//   During the previous computation's execution, x_in still shows the
//   previous input value → waveform correctly correlates input to output.
//
// BUG 2 - wait(valid) + extra @(posedge clk) overshoot
// ──────────────────────────────────────────────────────
// ORIGINAL (wrong):
//   wait(valid == 1);    ← level-sensitive: fires when valid=1 (after NBA phase)
//   @(posedge clk);      ← advances to the NEXT clock edge
//   result = sig_out;    ← reads correctly, but NOW x_in may have moved forward
//
//   Effect: the extra @(posedge clk) pushes the read into the next clock,
//   creating a one-cycle window where the next test could appear to start,
//   making the waveform show the correlation as offset.
//
// FIX:
//   Use @(posedge valid) instead.
//   @(posedge valid) fires at the EXACT rising edge of valid, after all
//   non-blocking assignments for that clock edge have settled. At this
//   moment sig_out already holds the new value (it was assigned via NBA
//   in the same clock cycle as valid). No extra clock advance needed.
//
// ─── WHY @(posedge valid) WORKS ──────────────────────────────────────────────
//
//   In sigmoid.v, the final divider cycle does:
//     sig_out <= ONE_HALF ± (quot_next >> 1);   ← NBA
//     valid   <= 1;                              ← NBA
//
//   Both are non-blocking assignments at the SAME posedge clk edge T.
//   After the NBA phase of edge T:
//     sig_out = new_value     ← updated
//     valid   = 1             ← updated → @(posedge valid) fires HERE
//
//   At the moment @(posedge valid) fires, sig_out IS the new value.
//   No extra clock advance is needed or desired.
//
// ─── WAVEFORM BEHAVIOUR AFTER FIX ────────────────────────────────────────────
//
//   x_in:    ──0.0──────────────────┬────0.5──────────────────┬────1.0──
//                                   │ start                   │ start
//   valid:                          ↑                         ↑
//   sig_out:                        └─0.5001 (x=0 result)     └─0.6225 (x=0.5)
//
//   Each sig_out transition is now perfectly aligned with the valid pulse
//   while x_in STILL shows the value that was computed.
//
// =============================================================================
 
`timescale 1ns/1ps
 
module sigmoid_tb;
 
    // ── Parameters ────────────────────────────────────────────────────────────
    parameter WIDTH     = 16;
    parameter FRAC_BITS = 14;
    parameter SCALE     = 16384;   // 2^FRAC_BITS
 
    // ── DUT Signals ───────────────────────────────────────────────────────────
    reg                     clk;
    reg                     rst_n;
    reg                     start;
    reg  signed [WIDTH-1:0] x_in;
    wire signed [WIDTH-1:0] sig_out;
    wire                    valid;
 
    // ── DUT Instantiation ─────────────────────────────────────────────────────
    sigmoid #(
        .WIDTH    (WIDTH),
        .FRAC_BITS(FRAC_BITS)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (start),
        .x_in    (x_in),
        .sig_out (sig_out),
        .valid   (valid)
    );
 
    // ── Clock: 10 ns period (100 MHz) ─────────────────────────────────────────
    initial clk = 0;
    always  #5 clk = ~clk;
 
    // ── Conversion Utilities ──────────────────────────────────────────────────
    // Real → Q2.14 fixed-point integer
    function automatic signed [WIDTH-1:0] real_to_fixed;
        input real val;
        begin
            real_to_fixed = $rtoi(val * SCALE);
        end
    endfunction
 
    // Q2.14 fixed-point integer → real
    function automatic real fixed_to_real;
        input signed [WIDTH-1:0] val;
        begin
            fixed_to_real = $itor(val) / $itor(SCALE);
        end
    endfunction
 
    // Reference sigmoid using built-in $exp
    function automatic real sigmoid_ref;
        input real x;
        real ex;
        begin
            ex = $exp(x);
            sigmoid_ref = ex / (1.0 + ex);
        end
    endfunction
 
    // ── Shared variables (task-visible) ───────────────────────────────────────
    real result_real, expected_real, error_real;
 
    // ── run_test task (CORRECTED) ─────────────────────────────────────────────
    task run_test;
        input real x_val;
        begin
 
            // ── STEP 1: Set x_in and start in the SAME clock cycle ───────────
            // Advancing one posedge first ensures we're on a clean clock edge.
            // Then x_in and start=1 are set as blocking assignments in the
            // same simulation time step - x_in is stable before the NEXT
            // posedge where the CORDIC will latch z_in = x_in >>> 1.
            //
            //  Timeline:
            //    posedge A (below) → x_in = new_val, start=1 set after edge
            //    posedge B         → CORDIC sees start=1, latches z_in ← x_in
            //    posedge B         → start=0 set after edge
            @(posedge clk);
            x_in  = real_to_fixed(x_val);   // ← FIX: x_in changes HERE, not earlier
            start = 1;
 
            @(posedge clk);
            start = 0;
 
            // ── STEP 2: Wait for result using @(posedge valid) ───────────────
            // @(posedge valid) fires at the EXACT clock edge where valid goes
            // from 0 → 1. At that moment, the non-blocking assignment for
            // sig_out has ALSO settled (both assigned at the same posedge clk).
            // Reading sig_out immediately after is guaranteed correct.
            //
            // This replaces the original:
            //   wait(valid == 1);   ← level-sensitive, then needed @clk to settle
            //   @(posedge clk);     ← unnecessary extra clock
            @(posedge valid);
 
            // ── STEP 3: Capture and display results ──────────────────────────
            result_real   = fixed_to_real(sig_out);
            expected_real = sigmoid_ref(x_val);
            error_real    = result_real - expected_real;
            if (error_real < 0) error_real = -error_real;
 
            $display("────────────────────────────────────────────────────────────");
            $display("  Input x       = %7.4f   (Q2.14 = %0d)", x_val, x_in);
            $display("  CORDIC out    = %7.4f   (Q2.14 = %0d)", result_real, sig_out);
            $display("  Expected      = %7.4f", expected_real);
            $display("  Abs error     = %8.6f   (%s)", error_real,
                     (error_real < 0.01) ? "PASS" : "FAIL");
            $display("");
 
            // ── STEP 4: Idle gap before next test ────────────────────────────
            // 5 clock cycles of separation ensures the sigmoid module is fully
            // idle (dividing=0, cordic running=0) before the next start pulse.
            // With CORDIC latency ~18 and divider latency 14, 5 cycles is safe
            // because we only get here AFTER valid fired (computation done).
            repeat(5) @(posedge clk);
        end
    endtask
 
    // ── Waveform Dump ─────────────────────────────────────────────────────────
    initial begin
        $dumpfile("sigmoid_tb.vcd");
        $dumpvars(0, sigmoid_tb);
    end
 
    // ── Main Test Sequence ────────────────────────────────────────────────────
    initial begin
        // Initialize
        rst_n = 0;
        start = 0;
        x_in  = 0;
 
        // Release reset after 5 cycles
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(3) @(posedge clk);
 
        $display("");
        $display("════════════════════════════════════════════════════════════");
        $display("      CORDIC Hyperbolic Sigmoid - Testbench Results         ");
        $display("      Format : Q2.14 Fixed-Point (16-bit)                   ");
        $display("      Scale  : 16384  |  Iterations : 16                   ");
        $display("════════════════════════════════════════════════════════════");
        $display("");
 
        // ── Test vectors ─────────────────────────────────────────────────────
        run_test(-1.0);    // σ(-1.0) = 0.2689
        run_test(-0.75);   // σ(-0.75)= 0.3208
        run_test(-0.5);    // σ(-0.5) = 0.3775
        run_test(-0.25);   // σ(-0.25)= 0.4378
        run_test( 0.0);    // σ(0.0)  = 0.5000
        run_test( 0.25);   // σ(0.25) = 0.5622
        run_test( 0.5);    // σ(0.5)  = 0.6225
        run_test( 0.75);   // σ(0.75) = 0.6792
        run_test( 1.0);    // σ(1.0)  = 0.7311
 
        $display("════════════════════════════════════════════════════════════");
        $display("  Simulation Complete.");
        $display("════════════════════════════════════════════════════════════");
        $finish;
    end
 
    // ── Timeout Watchdog ─────────────────────────────────────────────────────
    initial begin
        #500_000;
        $display("ERROR: Simulation TIMEOUT - check for stuck FSM or missing valid.");
        $finish;
    end
 
endmodule