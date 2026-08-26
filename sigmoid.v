// =============================================================================
// Module : sigmoid.v   (CORRECTED)
// Purpose: σ(x) = 1 / (1 + e^-x)  using CORDIC hyperbolic core
//
// Format : Q2.14  signed fixed-point  (scale = 2^14 = 16384)
//
// ─── Mathematical identity used ───────────────────────────────────────────
//   σ(x) = 0.5 + tanh(x/2) / 2
//
//   Proof:
//     tanh(x/2) = (e^x - 1) / (e^x + 1)
//     0.5 + tanh(x/2)/2
//       = [ (e^x + 1) + (e^x - 1) ] / [ 2(e^x + 1) ]
//       = 2·e^x / [ 2(e^x + 1) ]
//       = e^x / (e^x + 1) = σ(x)  ✓
//
//   So we pass x/2 to CORDIC, which returns cosh(x/2) and sinh(x/2).
//   tanh(x/2) = sinh(x/2) / cosh(x/2), and we divide using the restoring
//   bit-serial divider below.
//
// ─── Why x_in >>> 1 is passed as z_in ─────────────────────────────────────
//   CORDIC convergence requires |z_in| < 1.118.
//   If x_in ∈ [-2, +2], then x/2 ∈ [-1, +1] ⊂ [-1.118, +1.118].
//   Halving the input keeps us safely inside the convergence range.
//
// ─── Restoring bit-serial divider ─────────────────────────────────────────
//   Goal: compute Q2.14 value of |tanh(x/2)| = |sinh| / cosh
//   where both |sinh| and cosh are already in Q2.14.
//
//   Since both have the same scale factor (2^14), their ratio tanh is
//   scale-free, i.e., tanh_real = sinh_Q2.14 / cosh_Q2.14 (as integers).
//
//   To get the Q2.14 fixed-point representation of tanh (a value in [0,1)):
//     quotient = floor( |sinh_int| × 2^FRAC_BITS / cosh_int )
//
//   Algorithm (FRAC_BITS = 14 iterations, one per clock cycle):
//     Initialize: remainder = |sinh_int|   ← KEY: start with numerator!
//     Each cycle k:
//       remainder = remainder << 1
//       if remainder >= cosh_int:
//         remainder -= cosh_int
//         quotient[bit] = 1
//       else:
//         quotient[bit] = 0
//   After 14 cycles: quotient = floor(|sinh| × 2^14 / cosh)
//                             = Q2.14 representation of |tanh(x/2)|
//
//   ── WHY PREVIOUS CODE WAS WRONG ──────────────────────────────────────
//   The previous design initialized remainder = 0 and fed bits from
//   {|sinh|, 16'b0}[31]. After a left-shift of the 32-bit register,
//   only bits 31..18 were consumed in 14 iterations - i.e., bits 15..2
//   of |sinh|, which is at most |sinh|>>2 ≈ 1000-3000.  This is always
//   less than cosh (~16000-25000), so no subtraction ever fired and
//   quotient was permanently 0, giving sig_out = 0.5 for every input.
//
// ─── Final output ─────────────────────────────────────────────────────────
//   sig_out = ONE_HALF + (quotient >> 1)    if sinh ≥ 0  (x ≥ 0)
//   sig_out = ONE_HALF - (quotient >> 1)    if sinh < 0  (x < 0)
//
//   ONE_HALF = 8192 = 0.5 in Q2.14
//   quotient >> 1 = tanh(x/2)/2  in Q2.14
//
// ─── Latency ──────────────────────────────────────────────────────────────
//   CORDIC:  18 cycles  (16 iterations + 2 overhead)
//   Divider: 14 cycles  (FRAC_BITS iterations, 1 per cycle)
//   Total:  ~32 cycles @ 100 MHz → ~320 ns per sigmoid evaluation
// =============================================================================

module sigmoid #(
    parameter WIDTH     = 16,   // I/O width, Q2.14
    parameter FRAC_BITS = 14    // fractional bits = log2(scale)
)(
    input  wire                    clk,
    input  wire                    rst_n,   // active-low async reset
    input  wire                    start,   // single-cycle start pulse
    input  wire signed [WIDTH-1:0] x_in,   // input in Q2.14
    output reg  signed [WIDTH-1:0] sig_out, // σ(x) in Q2.14
    output reg                     valid    // one-cycle pulse when result ready
);

    // 0.5 in Q2.14 = 8192
    localparam signed [WIDTH-1:0] ONE_HALF = 16'sd8192;

    // ── CORDIC instantiation ─────────────────────────────────────────────────
    // Pass x/2 so CORDIC computes cosh(x/2) and sinh(x/2).
    // Arithmetic right-shift (>>>) preserves sign for negative x.
    wire signed [WIDTH-1:0] cosh_val;
    wire signed [WIDTH-1:0] sinh_val;
    wire                    cordic_valid;

    cordic_hyp #(
        .WIDTH      (WIDTH),
        .FRAC_BITS  (FRAC_BITS),
        .ITERATIONS (16)
    ) u_cordic (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (start),
        .z_in     (x_in >>> 1),   // x/2  →  CORDIC computes cosh(x/2), sinh(x/2)
        .cosh_out (cosh_val),
        .sinh_out (sinh_val),
        .valid    (cordic_valid)
    );

    // ── Divider registers ────────────────────────────────────────────────────
    //  remainder_reg : WIDTH+1 bits  (one extra MSB guards against overflow
    //                                 when left-shifting just before compare)
    //  quotient_reg  : WIDTH bits    (we only fill FRAC_BITS = 14 of them)
    //  divisor_reg   : WIDTH bits    (cosh, always positive)
    reg [WIDTH:0]    remainder_reg;
    reg [WIDTH-1:0]  quotient_reg;
    reg [WIDTH-1:0]  divisor_reg;
    reg [4:0]        bit_cnt;   // 0 .. FRAC_BITS-1
    reg              dividing;
    reg              sign_flag; // captures sign of sinh (= sign of tanh = sign of x)

    // ── Combinational divider signals ────────────────────────────────────────
    // These are purely combinational, computed every cycle from current regs.
    // rem_shifted : remainder doubled (one cycle's step)
    // do_sub      : true if remainder-after-shift >= cosh  →  quotient bit = 1
    // rem_after   : updated remainder for this step
    // quot_next   : updated quotient for this step  (needed for last-cycle output)
    wire [WIDTH:0]   rem_shifted  = {remainder_reg[WIDTH-1:0], 1'b0}; // remainder << 1
    wire             do_sub       = (rem_shifted >= {1'b0, divisor_reg});
    wire [WIDTH:0]   rem_after    = do_sub ? (rem_shifted - {1'b0, divisor_reg})
                                           : rem_shifted;
    wire [WIDTH-1:0] quot_next    = do_sub ? ((quotient_reg << 1) | 1'b1)
                                           : (quotient_reg << 1);

    // ── Sequential logic ─────────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sig_out       <= 0;
            valid         <= 0;
            dividing      <= 0;
            sign_flag     <= 0;
            remainder_reg <= 0;
            quotient_reg  <= 0;
            divisor_reg   <= 0;
            bit_cnt       <= 0;

        end else begin
            valid <= 0;  // default: de-assert each cycle

            // ── Trigger: CORDIC finished, start division ──────────────────
            // (Non-blocking on 'dividing' means this block and the divider
            //  block below cannot both run in the same cycle.)
            if (cordic_valid && !dividing) begin
                sign_flag     <= sinh_val[WIDTH-1]; // 1 = negative (x < 0)

                // *** KEY FIX ***
                // Initialize remainder = |sinh|, NOT zero.
                // The restoring divider computes floor(|sinh| × 2^14 / cosh)
                // by left-shifting remainder and subtracting cosh when possible.
                remainder_reg <= {1'b0,
                                  sinh_val[WIDTH-1] ? -sinh_val : sinh_val};

                divisor_reg   <= cosh_val;  // cosh always positive (cosh ≥ 1)
                quotient_reg  <= 0;
                bit_cnt       <= 0;
                dividing      <= 1;
            end

            // ── Divider: one bit of quotient per clock cycle ──────────────
            if (dividing) begin

                if (bit_cnt < FRAC_BITS - 1) begin
                    // Not the last bit yet: update rem and quotient, count up.
                    remainder_reg <= rem_after;
                    quotient_reg  <= quot_next;
                    bit_cnt       <= bit_cnt + 1;

                end else begin
                    // ── Last bit (bit_cnt == FRAC_BITS-1) ────────────────
                    // quot_next already includes this final bit (combinational).
                    // Use quot_next (not quotient_reg!) to capture all 14 bits.
                    dividing <= 0;

                    // sig_out = 0.5  ±  tanh(x/2)/2
                    //         = ONE_HALF  ±  (quot_next >> 1)
                    //
                    // quot_next >> 1 divides by 2 (the "/2" in the formula).
                    // This is NOT a precision loss - it is part of the formula.
                    //
                    // Positive tanh (x ≥ 0): sigmoid > 0.5  → add
                    // Negative tanh (x < 0): sigmoid < 0.5  → subtract
                    if (sign_flag)
                        sig_out <= ONE_HALF - $signed({1'b0, quot_next >> 1});
                    else
                        sig_out <= ONE_HALF + $signed({1'b0, quot_next >> 1});

                    valid <= 1;
                end
            end
        end
    end

endmodule