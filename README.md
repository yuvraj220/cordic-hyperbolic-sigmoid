# Hyperbolic CORDIC Core for Hardware Sigmoid Activation

Verilog HDL implementation of a hyperbolic CORDIC core, used to build a
fixed-point hardware sigmoid activation function — a multiplier-less,
area-efficient building block for neural-network inference on FPGA/ASIC.

## Why CORDIC

Neural network accelerators need the sigmoid activation

```
σ(x) = 1 / (1 + e^-x)
```

but a direct hardware implementation of `e^-x` is expensive: it needs
multipliers, floating-point arithmetic, or large lookup tables. **CORDIC**
(**CO**ordinate **R**otation **DI**gital **C**omputer) computes
transcendental functions using only shift, add/subtract, and small lookup
tables, replacing multiplication with shift-add operations entirely — which
is why it's used here instead.

CORDIC comes in three flavors depending on the coordinate system:

| Mode | Computes | Elementary angle |
|---|---|---|
| Circular | sin, cos, tan | θᵢ = tan⁻¹(2⁻ⁱ) |
| Linear | multiplication, division | — |
| **Hyperbolic** | sinh, cosh, tanh, exponentials | θᵢ = tanh⁻¹(2⁻ⁱ) |

This project uses **hyperbolic CORDIC**, since the sigmoid can be rewritten
in terms of `tanh`.

## Hyperbolic CORDIC theory

The hyperbolic rotation iterates:

```
x[i+1] = x[i] + d[i]*y[i]*2^-i
y[i+1] = y[i] + d[i]*x[i]*2^-i
z[i+1] = z[i] - d[i]*atanh(2^-i)
```

with `d[i] = +1` if `z[i] >= 0`, else `-1`, and initial conditions
`x0 = 1/Kh` (Kh ≈ 0.8282, the hyperbolic gain), `y0 = 0`, `z0` = input angle.
After enough iterations, `x` converges to `cosh(z)` and `y` to `sinh(z)`.
Because certain iteration indices (i = 4, 13, ...) must be repeated for the
hyperbolic case to converge, the core here runs an 18-entry table (16
"real" iterations plus 2 repeats) instead of a plain 1-to-16 loop —
see the repeated `atanh_table`/`shift_table` entries at indices 4 and 14
in [`cordic_hyp.v`](cordic_hyp.v). Convergence additionally requires
`|z| < 1.118`.

## Sigmoid from cosh/sinh

The sigmoid identity used to bridge CORDIC's outputs to `σ(x)`:

```
tanh(x/2) = (e^x - 1) / (e^x + 1)
0.5 + tanh(x/2)/2 = e^x / (e^x + 1) = 1 / (1 + e^-x) = σ(x)
```

So [`sigmoid.v`](sigmoid.v) passes `x/2` into the CORDIC core (halving keeps
the angle inside the `|z| < 1.118` convergence range for `x` in [-2, +2]),
takes the resulting `cosh(x/2)` and `sinh(x/2)`, divides them to get
`tanh(x/2) = sinh/cosh`, and combines: `σ(x) = 0.5 ± tanh(x/2)/2` (sign
following the sign of `sinh`).

The division itself is done with a **restoring bit-serial divider** — one
quotient bit produced per clock cycle, no hardware multiplier or divider
IP required:

```
remainder = |sinh|
repeat FRAC_BITS times:
    remainder = remainder << 1
    if remainder >= cosh:
        remainder -= cosh
        quotient_bit = 1
    else:
        quotient_bit = 0
```

After `FRAC_BITS` (14) cycles, `quotient = floor(|sinh| * 2^14 / cosh)`,
which is exactly the Q2.14 representation of `|tanh(x/2)|`.

## Fixed-point format

16-bit signed **Q2.14** (1 sign + 1 integer + 14 fractional bits, scale =
2^14 = 16384). E.g. `1.0 → 16384`, `0.5 → 8192`, `-1.0 → -16384`.

## Latency

- Hyperbolic CORDIC core: 18 cycles (16 iterations + 2 pipeline/settle cycles)
- Bit-serial divider: 14 cycles (one quotient bit per cycle)
- Total: ~32 cycles per sigmoid evaluation ≈ 320 ns at 100 MHz

## Files

| File | Role |
|---|---|
| `cordic_hyp.v` | Hyperbolic CORDIC core — 18-step iteration computing cosh(z) and sinh(z) in Q2.14 |
| `cord_hyp_tb.v` | Testbench for the CORDIC core — checks cosh/sinh against reference math for several input angles, including a symmetry check (z and -z) |
| `sigmoid.v` | Sigmoid activation module built on the CORDIC core, using the identity σ(x) = 0.5 + tanh(x/2)/2 and the restoring bit-serial divider above |
| `sigmoid_tb.v` | Testbench for the sigmoid module — sweeps representative inputs and checks against the reference sigmoid curve |

## Verified accuracy

Simulation results (from the course project report) against the reference
floating-point sigmoid:

| Input | Sigmoid output |
|---|---|
| -1.0 | 0.2689 |
| -0.5 | 0.3775 |
|  0.0 | 0.5001 |
|  0.5 | 0.6225 |
|  1.0 | 0.6792 |

## Design advantages

- Multiplier-less: only shifts, adds/subtracts, and small lookup tables
- Low hardware area and power vs. a floating-point or LUT-based sigmoid
- FPGA and ASIC compatible; suitable for low-area/low-power neural
  network accelerators and embedded AI inference engines

## Background

Originally implemented as a course project for EE515 (VLSI Architecture),
Dept. of Electronics and Electrical Engineering, IIT Guwahati.
