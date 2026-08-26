`timescale 1ns / 1ps
// =============================================================================
// Module: cordic_hyp.v
// Description: Hyperbolic CORDIC core - computes cosh(z) and sinh(z)
//
// Fixed-Point Format: Q2.14  (16-bit: 1 sign + 1 integer + 14 fractional)
// Scale = 2^14 = 16384
//
// Theory:
//   Hyperbolic CORDIC iterative equations:
//     x[i+1] = x[i] + d[i] * 2^(-i) * y[i]
//     y[i+1] = y[i] + d[i] * 2^(-i) * x[i]
//     z[i+1] = z[i] - d[i] * atanh(2^(-i))
//
//   where d[i] = +1 if z[i] >= 0, else -1
//
//   Initialization:
//     x[0] = Kh_inv = 1/Kh ≈ 0.8282  → 0.8282 * 16384 = 13573 (Q2.14)
//     y[0] = 0
//     z[0] = input angle
//
//   After N iterations:
//     x_out ≈ cosh(z_in)
//     y_out ≈ sinh(z_in)
//
// Hyperbolic angles (atanh(2^-i)) in Q2.14 fixed point:
//   i=1:  atanh(0.5)   = 0.5493  → 8998
//   i=2:  atanh(0.25)  = 0.2554  → 4185
//   i=3:  atanh(0.125) = 0.1256  → 2058
//   i=4:  atanh(0.0625)= 0.0627  → 1027 (REPEATED at i=4)
//   i=5:  atanh(...)   = 0.0313  →  514
//   ... etc.
//
// Convergence: Input z must be in range |z| < 1.118 (for 16 iterations)
//
// =============================================================================


module cordic_hyp #(
    parameter WIDTH       = 16,
    parameter FRAC_BITS   = 14,
    parameter ITERATIONS  = 16
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    start,
    input  wire signed [WIDTH-1:0] z_in,
    output reg  signed [WIDTH-1:0] cosh_out,
    output reg  signed [WIDTH-1:0] sinh_out,
    output reg                     valid
);

    localparam signed [WIDTH-1:0] KH_INV = 16'sd19784; // 
    //1/Kh * 16384: Kh=0.82816, 1/Kh=1.20750, 1.20750*16384=19784

    // 18-entry angle table (indices 0..17)
    reg signed [WIDTH-1:0] atanh_table [0:17];
    initial begin
        atanh_table[0]  = 16'sd8998;
        atanh_table[1]  = 16'sd4185;
        atanh_table[2]  = 16'sd2059;
        atanh_table[3]  = 16'sd1025;
        atanh_table[4]  = 16'sd1025;  // repeat i=4
        atanh_table[5]  = 16'sd512;
        atanh_table[6]  = 16'sd256;
        atanh_table[7]  = 16'sd128;
        atanh_table[8]  = 16'sd64;
        atanh_table[9]  = 16'sd32;
        atanh_table[10] = 16'sd16;
        atanh_table[11] = 16'sd8;
        atanh_table[12] = 16'sd4;
        atanh_table[13] = 16'sd2;
        atanh_table[14] = 16'sd2;     // repeat i=13
        atanh_table[15] = 16'sd1;
        atanh_table[16] = 16'sd1;
        atanh_table[17] = 16'sd0;
    end

    reg [4:0] shift_table [0:17];
    initial begin
        shift_table[0]  = 5'd1;
        shift_table[1]  = 5'd2;
        shift_table[2]  = 5'd3;
        shift_table[3]  = 5'd4;
        shift_table[4]  = 5'd4;   // repeat i=4
        shift_table[5]  = 5'd5;
        shift_table[6]  = 5'd6;
        shift_table[7]  = 5'd7;
        shift_table[8]  = 5'd8;
        shift_table[9]  = 5'd9;
        shift_table[10] = 5'd10;
        shift_table[11] = 5'd11;
        shift_table[12] = 5'd12;
        shift_table[13] = 5'd13;
        shift_table[14] = 5'd13;  // repeat i=13
        shift_table[15] = 5'd14;
        shift_table[16] = 5'd15;
        shift_table[17] = 5'd16;
    end

    // Extended-width registers to prevent overflow
    reg signed [WIDTH+8-1:0] x_reg;
    reg signed [WIDTH+8-1:0] y_reg;
    reg signed [WIDTH+8-1:0] z_reg;

    reg [4:0] iter;
    reg       running;
    // -------------------------------------------------------------------------
    // FIX 1: 'done_latch' fires the cycle AFTER the last CORDIC update so that
    //         x_reg/y_reg have settled before we capture them into cosh/sinh.
    // -------------------------------------------------------------------------
    reg       done_latch;

    wire d_pos = ~z_reg[WIDTH+8-1];

    wire signed [WIDTH+8-1:0] x_shifted = x_reg >>> shift_table[iter];
    wire signed [WIDTH+8-1:0] y_shifted = y_reg >>> shift_table[iter];
    wire signed [WIDTH+8-1:0] angle     = {{8{atanh_table[iter][WIDTH-1]}},
                                            atanh_table[iter]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_reg     <= 0;
            y_reg     <= 0;
            z_reg     <= 0;
            iter      <= 0;
            running   <= 0;
            done_latch<= 0;
            valid     <= 0;
            cosh_out  <= 0;
            sinh_out  <= 0;
        end
        else begin
            valid      <= 0;
            done_latch <= 0;

            if (start && !running) begin
                x_reg    <= {{8{KH_INV[WIDTH-1]}}, KH_INV};
                y_reg    <= 0;
                z_reg    <= {{8{z_in[WIDTH-1]}}, z_in};
                iter     <= 0;
                running  <= 1;
            end
            else if (running) begin
                // CORDIC iteration
                if (d_pos) begin
                    x_reg <= x_reg + y_shifted;
                    y_reg <= y_reg + x_shifted;
                    z_reg <= z_reg - angle;
                end else begin
                    x_reg <= x_reg - y_shifted;
                    y_reg <= y_reg - x_shifted;
                    z_reg <= z_reg + angle;
                end

                // ---------------------------------------------------------------
                // FIX 1: All 18 table entries (0..17) must be processed.
                // After iter==17 completes its update, set done_latch so the
                // NEXT cycle captures the fully-updated x_reg / y_reg.
                // ---------------------------------------------------------------
                if (iter == 5'd17) begin
                    running    <= 0;
                    done_latch <= 1;  // capture output next cycle
                    iter       <= 0;
                end
                else begin
                    iter <= iter + 1;
                end
            end

            // ------------------------------------------------------------------
            // FIX 2: Capture output ONE cycle after the final iteration so that
            //         non-blocking assignments have settled.
            // ------------------------------------------------------------------
            if (done_latch) begin
                cosh_out <= x_reg[WIDTH-1:0];
                sinh_out <= y_reg[WIDTH-1:0];
                valid    <= 1;
            end
        end
    end

endmodule