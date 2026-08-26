# Hyperbolic CORDIC Core for Hardware Sigmoid Activation

Verilog HDL implementation of a hyperbolic CORDIC core, used to build a
fixed-point hardware sigmoid activation function — a building block for
neural-network inference on FPGA/ASIC.

## Fixed-point format

Q2.14 signed fixed-point (1 sign + 1 integer + 14 fractional bits, scale = 2^14).

## Files

| File | Role |
|---|---|
| `cordic_hyp.v` | Hyperbolic CORDIC core — 16-iteration rotation computing cosh(z) and sinh(z) |
| `cord_hyp_tb.v` | Testbench for the CORDIC core — checks cosh/sinh against reference math for several input angles, including a symmetry check |
| `sigmoid.v` | Sigmoid activation module built on the CORDIC core, using the identity σ(x) = 0.5 + tanh(x/2)/2 and a restoring bit-serial divider to compute tanh(x/2) = sinh/cosh |
| `sigmoid_tb.v` | Testbench for the sigmoid module |
| `CORDIC.pdf` | Write-up covering the CORDIC algorithm and design notes |

## Design notes

- Convergence requires \|z\| < 1.118 for 16 iterations, so the sigmoid module
  passes `x/2` into the CORDIC core (keeping the input inside the convergence
  range for `x` in [-2, +2]) and folds the halving into the final
  `tanh(x/2)/2` identity.
- The divider is a 14-cycle restoring bit-serial divider (one quotient bit
  per clock), computing `floor(|sinh| * 2^14 / cosh)` in Q2.14.
- Total latency: ~18 cycles for the CORDIC core + ~14 cycles for the divider
  ≈ 32 cycles per sigmoid evaluation (~320 ns at 100 MHz).
