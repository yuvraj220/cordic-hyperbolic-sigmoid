`timescale 1ns / 1ps
// =============================================================================
// Module: cordic_hyp_tb.v  (FIXED)
// Description: Testbench for the Hyperbolic CORDIC core
//
// Tests cosh(z) and sinh(z) for several input angles and compares against
// expected values computed from the real math.
//
// Q2.14 format:
//   real → fixed : real_val * 16384  (truncate to integer)
//   fixed → real : fixed_int / 16384.0
//
// Test cases:
//   z =  0.0  → cosh = 1.0000,  sinh = 0.0000
//   z =  0.5  → cosh = 1.1276,  sinh = 0.5211
//   z =  1.0  → cosh = 1.5431,  sinh = 1.1752
//   z = -0.5  → cosh = 1.1276,  sinh = -0.5211  (symmetry check)
// =============================================================================

module cordic_hyp_tb;

    // -------------------------------------------------------------------------
    // Parameters - must match the DUT exactly
    // -------------------------------------------------------------------------
    parameter WIDTH      = 16;
    parameter FRAC_BITS  = 14;
    parameter ITERATIONS = 16;

    // Scale factor: 2^14 = 16384
    localparam real SCALE = 16384.0;

    // -------------------------------------------------------------------------
    // DUT Signal Declarations
    // -------------------------------------------------------------------------
    reg                      clk;
    reg                      rst_n;
    reg                      start;
    reg  signed [WIDTH-1:0]  z_in;

    wire signed [WIDTH-1:0]  cosh_out;
    wire signed [WIDTH-1:0]  sinh_out;
    wire                     valid;

    // -------------------------------------------------------------------------
    // Instantiate the DUT
    // -------------------------------------------------------------------------
    cordic_hyp #(
        .WIDTH      (WIDTH),
        .FRAC_BITS  (FRAC_BITS),
        .ITERATIONS (ITERATIONS)
    ) uut (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (start),
        .z_in     (z_in),
        .cosh_out (cosh_out),
        .sinh_out (sinh_out),
        .valid    (valid)
    );

    // -------------------------------------------------------------------------
    // Clock Generation: 10 ns period = 100 MHz
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Fixed-point ↔ real conversion functions
    // -------------------------------------------------------------------------
    function real fixed_to_real;
        input signed [WIDTH-1:0] val;
        begin
            fixed_to_real = $itor(val) / SCALE;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Task: drive one test case and report results
    //
    // FIX 1: z_in is set ONE full cycle before start is pulsed, so the DUT
    //         sees a stable input when it latches on the start edge.
    //
    // FIX 2: Instead of wait(valid) - which can unblock mid-cycle -
    //         we poll on clean posedge clk boundaries using a loop.
    //         This guarantees we read cosh_out/sinh_out only after the
    //         registered valid=1 has fully settled.
    //
    // FIX 3: We print actual vs. expected values with an error metric
    //         so the simulation log is actually useful.
    // -------------------------------------------------------------------------
    task check_hyperbolic;
        input real angle_val;
        input real expected_cosh;
        input real expected_sinh;

        real result_cosh, result_sinh;
        real err_cosh, err_sinh;
        integer timeout_count;

        begin
            // ------------------------------------------------------------------
            // Step 1: Present z_in ONE cycle before asserting start.
            //         This ensures the input is stable when the DUT latches it.
            // ------------------------------------------------------------------
            @(posedge clk);
            #1;                              // small delay after clock edge
            z_in  = $rtoi(angle_val * SCALE);
            start = 0;

            // ------------------------------------------------------------------
            // Step 2: Assert start for exactly ONE clock cycle.
            //         The DUT checks (start && !running) on each posedge.
            // ------------------------------------------------------------------
            @(posedge clk);
            #1;
            start = 1;

            @(posedge clk);
            #1;
            start = 0;

            // ------------------------------------------------------------------
            // Step 3: Poll for valid on clean clock edges (safe alternative to
            //         wait(valid)).
            //
            //         The DUT takes: 1 load cycle + 18 CORDIC cycles +
            //         1 done_latch cycle = 20 cycles total.
            //         We allow up to 40 cycles as a generous timeout.
            // ------------------------------------------------------------------
            timeout_count = 0;
            while (!valid && timeout_count < 40) begin
                @(posedge clk);
                timeout_count = timeout_count + 1;
            end

            // ------------------------------------------------------------------
            // Step 4: Read and convert outputs - we are now aligned to the
            //         exact posedge where valid=1, so outputs are stable.
            // ------------------------------------------------------------------
            if (!valid) begin
                $display("  [TIMEOUT] No valid signal received for z = %0.4f", angle_val);
            end else begin
                result_cosh = fixed_to_real(cosh_out);
                result_sinh = fixed_to_real(sinh_out);
                err_cosh    = result_cosh - expected_cosh;
                err_sinh    = result_sinh - expected_sinh;
                if (err_cosh < 0) err_cosh = -err_cosh;
                if (err_sinh < 0) err_sinh = -err_sinh;

                $display("─────────────────────────────────────────────────────────");
                $display("  Input z        = %0.4f  (Q2.14 = %0d)", angle_val, z_in);
                $display("  cosh_out (hw)  = %0.5f  | expected = %0.5f  | error = %0.6f  (%s)",
                         result_cosh, expected_cosh, err_cosh,
                         (err_cosh < 0.005) ? "PASS" : "FAIL");
                $display("  sinh_out (hw)  = %0.5f  | expected = %0.5f  | error = %0.6f  (%s)",
                         result_sinh, expected_sinh, err_sinh,
                         (err_sinh < 0.005) ? "PASS" : "FAIL");
                $display("");
            end

            // ------------------------------------------------------------------
            // Step 5: Wait a few idle cycles before the next test so the DUT
            //         fully de-asserts valid and returns to idle state.
            // ------------------------------------------------------------------
            repeat(5) @(posedge clk);
        end
    endtask

    // -------------------------------------------------------------------------
    // Main Test Sequence
    // -------------------------------------------------------------------------
    initial begin
        // Waveform dump for Vivado / ModelSim
        $dumpfile("cordic_hyp_tb.vcd");
        $dumpvars(0, cordic_hyp_tb);

        // Initialize all inputs
        rst_n = 0;
        start = 0;
        z_in  = 0;

        // Hold reset for 4 cycles then release
        repeat(4) @(posedge clk);
        #1;
        rst_n = 1;

        // Allow a few cycles after reset for DUT to stabilize
        repeat(4) @(posedge clk);

        $display("");
        $display("═════════════════════════════════════════════════════════");
        $display("      CORDIC Hyperbolic Core Testbench                   ");
        $display("      Format: Q2.14 Fixed Point (16-bit)                 ");
        $display("      Scale : 16384 | Iterations: 16 (18 table entries)  ");
        $display("═════════════════════════════════════════════════════════");
        $display("");

        // ------------------------------------------------------------------
        // Test 1: z = 0.0
        //   cosh(0) = 1.00000   sinh(0) = 0.00000
        // ------------------------------------------------------------------
        check_hyperbolic(0.0, 1.00000, 0.00000);

        // ------------------------------------------------------------------
        // Test 2: z = 0.5
        //   cosh(0.5) ≈ 1.12763  sinh(0.5) ≈ 0.52110
        // ------------------------------------------------------------------
        check_hyperbolic(0.5, 1.12763, 0.52110);

        // ------------------------------------------------------------------
        // Test 3: z = 1.0
        //   cosh(1.0) ≈ 1.54308  sinh(1.0) ≈ 1.17520
        //   NOTE: Q2.14 max representable value = 1.99999, so 1.5431 fits.
        //   sinh(1.0) = 1.1752 also fits within Q2.14 range.
        // ------------------------------------------------------------------
        check_hyperbolic(1.0, 1.54308, 1.17520);

        // ------------------------------------------------------------------
        // Test 4: z = -0.5  (symmetry check)
        //   cosh(-0.5) =  1.12763  (same as positive - cosh is even)
        //   sinh(-0.5) = -0.52110  (negated      - sinh is odd)
        // ------------------------------------------------------------------
        check_hyperbolic(-0.5, 1.12763, -0.52110);

        // ------------------------------------------------------------------
        // Test 5: z = -1.0  (full negative symmetry)
        // ------------------------------------------------------------------
        check_hyperbolic(-1.0, 1.54308, -1.17520);

        $display("═════════════════════════════════════════════════════════");
        $display("  Simulation Complete.");
        $display("═════════════════════════════════════════════════════════");

        #100 $finish;
    end

    // -------------------------------------------------------------------------
    // Watchdog: abort if simulation hangs
    // -------------------------------------------------------------------------
    initial begin
        #100000;
        $display("ERROR: Simulation watchdog timeout - check for deadlock.");
        $finish;
    end

endmodule