# nic-verilog

Custom Network Interface Card RX-path logic (simulation-only, HFT-inclined).

Standalone Verilog project, complementary to a separate C++ LOB + ITCH
parser project. This NIC's classified/timestamped output is designed to
sit upstream of an FPGA UDP parser (Phase 3 of that other project) in a
future "wire to book" composition — but this repo is self-contained and
buildable on its own.

## Scope

RX-only pipeline: `mac_rx` -> `hw_timestamp` (tap) / `udp_classifier` (tap)
-> `rx_descriptor_ring`. See `docs/DESIGN.md` for the full interface
contract -- signal names, widths, handshaking rules, sizing constants,
and explicit non-goals. **Read that before touching any RTL file.**

## Layout

```
rtl/    module implementations
tb/     one self-checking testbench per module, plus tb_top_integration.v
sim/    build outputs (.out, .vcd) -- gitignored, created by make
docs/   DESIGN.md -- the interface contract, frozen before RTL work started
```

## Build

Requires Icarus Verilog (`sudo apt install iverilog` on Kali/Debian).
For a non-standard install location, override `IVERILOG`/`VVP` on the
make command line (see the comment at the top of the `Makefile`).

```
make all                    # every module testbench + full integration
make tb_hw_timestamp        # or run one at a time
make tb_mac_rx
make tb_udp_classifier
make tb_rx_descriptor_ring
make tb_top_integration
```

Each testbench is self-checking and prints an
`ALL <n> TESTS PASSED` / `FAILED` summary. VCD waveforms land in
`sim/` for GTKWave inspection.


