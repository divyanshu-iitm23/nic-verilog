# Custom NIC Logic — Design Document

**Project:** HFT-inclined NIC RX pipeline (simulation-only, Verilog)
**Scope:** RX path — `mac_rx` → `hw_timestamp` → `udp_classifier` → `rx_descriptor_ring`
**Toolchain:** Icarus Verilog (`iverilog` + `vvp`) for simulation, GTKWave for waveform inspection
**Status:** v0.1 — contract frozen before RTL. Any signal-level change here must be a deliberate edit to this file, not an implicit change in a module.

---

## 1. Global Conventions

- **Clock domain:** single clock domain for v0.1. Signal name `clk`. All modules synchronous to posedge `clk`. No CDC in this version — CDC (e.g. to a host-facing clock) is an explicit future extension, not something to sneak into a module early.
- **Reset:** synchronous, active-high, signal name `rst`. Every module resets all state (counters, FSM state, valid flags) on `rst`.
- **Handshaking:** valid/ready (AXI-Stream-lite style) on every inter-module link. No link in this design is valid-only. Rule: producer asserts `*_valid` and holds data stable until `*_valid && *_ready` on a clock edge (transfer happens on that edge). Consumer asserts `*_ready` combinationally based on its own capacity — it may deassert `*_ready` at any time (not required to stay high once asserted).
- **Byte order:** all multi-byte fields (Ethernet, IP, UDP headers) arrive **big-endian** (network byte order), consistent with the wire. Internal registers store header fields in **host-natural (little-endian-normalized)** form after extraction — i.e. `udp_classifier` and downstream modules read `dst_port` etc. as a normal integer, not a byte-swapped one. Byte-swapping happens once, at extraction, not repeatedly downstream.
- **Naming:** every inter-module bus is `<producer_module>_<signal>`, e.g. `macrx_frame_valid`. This avoids ambiguity in the integration testbench where multiple modules' `valid` signals are in scope simultaneously.
- **Widths are fixed in this doc.** If a module needs a width change, edit this table first, then the RTL.

---

## 2. Module: `mac_rx`

**Responsibility:** Byte-stream deframing. Detects preamble/SFD, delineates frame boundaries, checks FCS (CRC32), and passes a clean payload stream downstream — garbage frames (bad CRC, runt, oversize) are dropped before they ever reach the classifier.

### Inputs
| Signal | Width | Description |
|---|---|---|
| `clk` | 1 | clock |
| `rst` | 1 | sync reset |
| `phy_data` | 8 | simulated PHY byte input (stand-in for SerDes/GMII data) |
| `phy_data_valid` | 1 | asserted when `phy_data` carries a live byte this cycle |

> Note: no preamble/SFD generation is modeled upstream of this — the testbench for `mac_rx` is responsible for feeding a realistic byte stream (preamble bytes `0x55`×7 + SFD `0xD5`, then frame bytes, then FCS). This keeps `mac_rx` itself PHY-agnostic.

### Outputs
| Signal | Width | Description |
|---|---|---|
| `macrx_data` | 8 | one payload byte (Ethernet frame contents, starting at dest MAC, FCS stripped) |
| `macrx_data_valid` | 1 | byte-valid, part of the valid/ready handshake |
| `macrx_sof` | 1 | start-of-frame pulse, asserted together with the first valid byte of a new frame |
| `macrx_eof` | 1 | end-of-frame pulse, asserted together with the last valid byte of a frame |
| `macrx_frame_ok` | 1 | asserted for exactly one cycle at `macrx_eof` time: `1` = CRC passed and length legal, `0` = frame should be discarded by consumer |
| `macrx_ready` | 1 | backpressure to whatever feeds `phy_data` (included for completeness; in v0.1 the PHY stub is not expected to honor backpressure, but the port exists for future realism) |

### Downstream consumer contract
`hw_timestamp` and `udp_classifier` both snoop this bus (see §5 — timestamp is a passive tap, not an inline stage). The descriptor ring is the actual consumer that asserts `*_ready`.

### Internal behavior notes (for implementer, not a signal contract)
- FSM states: `IDLE` → `PREAMBLE` → `SFD` → `PAYLOAD` → `FCS_CHECK` → back to `IDLE`
- Min frame length 64 bytes, max 1518 bytes (standard Ethernet) — enforce both; violation forces `macrx_frame_ok = 0`
- CRC32 computed incrementally over payload bytes as they stream, compared against last 4 received bytes

---

## 3. Module: `hw_timestamp`

**Responsibility:** Free-running counter + latch-on-event. This is the module that makes the NIC "HFT-grade" — timestamp happens in hardware, at the earliest possible point (SOF detection), not in software after a DMA and an interrupt.

### Inputs
| Signal | Width | Description |
|---|---|---|
| `clk` | 1 | clock |
| `rst` | 1 | sync reset |
| `macrx_sof` | 1 | tap from `mac_rx` — triggers a latch |

### Outputs
| Signal | Width | Description |
|---|---|---|
| `hwts_counter` | 64 | free-running counter, increments every `clk` cycle from `rst` deassertion. Units are **clock cycles**, not nanoseconds — conversion to wall-clock time is a testbench/post-processing concern, not an RTL concern (keeps the module agnostic of actual clock frequency) |
| `hwts_value` | 64 | latched value of `hwts_counter` at the cycle `macrx_sof` was asserted |
| `hwts_valid` | 1 | one-cycle pulse, asserted the cycle after `macrx_sof`, indicating `hwts_value` is fresh and should be captured by the descriptor ring |

### Design notes
- This is a **passive tap**, not an inline pipeline stage — it does not gate or delay `mac_rx`'s output in any way. It just watches `macrx_sof` and produces a timestamp on the side.
- `hwts_value` must be held stable until the next `macrx_sof`, so `rx_descriptor_ring` has a full frame's worth of cycles to sample it (it only needs to sample it once, at `macrx_eof`, but the value must not have changed in between).
- No wraparound handling in v0.1 (64 bits at any realistic clock is years of runtime — treat wraparound as out of scope, note it as a known simplification).

---

## 4. Module: `udp_classifier`

**Responsibility:** Parse Ethernet → IP → UDP headers from the `mac_rx` byte stream, extract dest MAC / dest IP / dest UDP port, compare against a small table of "markets I care about," and tag the frame accept/reject. This is where multicast market-data filtering happens.

### Inputs
| Signal | Width | Description |
|---|---|---|
| `clk` | 1 | clock |
| `rst` | 1 | sync reset |
| `macrx_data` | 8 | tap from `mac_rx` payload stream |
| `macrx_data_valid` | 1 | tap |
| `macrx_sof` | 1 | tap |
| `macrx_eof` | 1 | tap |
| `macrx_frame_ok` | 1 | tap — if `0`, classifier should force reject regardless of header content |
| `cfg_wr_en` | 1 | config write enable — loads one entry into the match table |
| `cfg_wr_idx` | 4 | which of up to 16 match-table entries to write |
| `cfg_dst_ip` | 32 | config: dest IP to match (one entry) |
| `cfg_dst_port` | 16 | config: dest UDP port to match (one entry) |
| `cfg_entry_en` | 1 | config: enable bit for this entry (allows disabling entries without clearing them) |

> Match table is intentionally simple (16 entries, IP+port exact match) rather than a general CAM — sufficient for "list of multicast market data groups I subscribe to," which is the real-world use case. A TCAM-style prefix match is a documented future extension, not v0.1 scope.

### Outputs
| Signal | Width | Description |
|---|---|---|
| `classifier_valid` | 1 | asserted for one cycle at end-of-frame, indicating a classification decision is ready |
| `classifier_accept` | 1 | `1` = frame matched an enabled table entry and had good CRC; `0` = reject (drop, don't enqueue) |
| `classifier_dst_ip` | 32 | extracted dest IP, valid when `classifier_valid` |
| `classifier_dst_port` | 16 | extracted dest UDP port, valid when `classifier_valid` |
| `classifier_payload_len` | 16 | extracted UDP payload length (from UDP header length field, minus 8-byte UDP header), valid when `classifier_valid` |

### Internal behavior notes
- Byte-offset tracking: needs an internal byte counter from `macrx_sof` to know when it's looking at dest MAC (offset 0–5), ethertype (offset 12–13, must be `0x0800` for IPv4), IP header (offset 14+, check protocol field = `17` for UDP), UDP header (dest port at a computed offset after IHL-dependent IP header length).
- **IP header length is variable** (IHL field) — classifier must read IHL before it knows where the UDP header starts. This is the trickiest part of this module; budget real design time here, don't treat it as "just an offset."
- Classification decision (`classifier_valid`) fires at `macrx_eof`, same cycle as `mac_rx`'s `macrx_frame_ok` — so `rx_descriptor_ring` sees both at once.

---

## 5. Module: `rx_descriptor_ring`

**Responsibility:** The hardware analog of what `rte_mbuf` + a DPDK RX ring does in software. Receives classified, timestamped frame metadata + payload, writes it into a circular buffer, and exposes a simple software-facing interface (head/tail pointers) that a "driver" (your integration testbench, standing in for a DPDK poll loop) drains.

### Inputs
| Signal | Width | Description |
|---|---|---|
| `clk` | 1 | clock |
| `rst` | 1 | sync reset |
| `macrx_data` | 8 | payload byte tap (ring stores payload bytes, not headers — see note) |
| `macrx_data_valid` | 1 | tap |
| `macrx_sof` / `macrx_eof` | 1 / 1 | tap |
| `classifier_valid` | 1 | from `udp_classifier` |
| `classifier_accept` | 1 | from `udp_classifier` — if `0`, ring must **not** enqueue this frame at all |
| `classifier_dst_ip` | 32 | metadata to store alongside payload |
| `classifier_dst_port` | 16 | metadata to store alongside payload |
| `classifier_payload_len` | 16 | metadata to store alongside payload |
| `hwts_value` | 64 | from `hw_timestamp` — metadata to store alongside payload |
| `sw_ren` | 1 | "software" read-enable — driver pops one descriptor |

> Design choice: the ring buffers payload bytes as they stream (writes them cycle-by-cycle into a byte-addressed buffer memory as `mac_rx` produces them), but the **descriptor is only committed** (made visible to the software side) if `classifier_accept == 1` at end-of-frame. If rejected, the write pointer for the payload buffer simply rewinds — no separate "delete" needed. This mirrors how real NICs avoid double-buffering: write speculatively, commit conditionally.

### Outputs
| Signal | Width | Description |
|---|---|---|
| `ring_desc_valid` | 1 | asserted when at least one committed descriptor is available for software to read |
| `ring_desc_ip` | 32 | head descriptor's dest IP |
| `ring_desc_port` | 16 | head descriptor's dest UDP port |
| `ring_desc_len` | 16 | head descriptor's payload length |
| `ring_desc_timestamp` | 64 | head descriptor's hardware timestamp |
| `ring_desc_payload_addr` | 12 | head descriptor's start address in the payload buffer memory (see §5.1 sizing) |
| `ring_full` | 1 | asserted when the descriptor ring itself is full (16 descriptors — see below); `mac_rx`/classifier side should be understood to drop new frames when this is asserted (packet loss under overload is realistic and intentional, not a bug to design away) |
| `ring_head_ptr` | 4 | current head pointer (for testbench observability) |
| `ring_tail_ptr` | 4 | current tail pointer (for testbench observability) |

### 5.1 Sizing (v0.1 fixed constants — change here first if you need more)
- **Descriptor ring depth:** 16 entries (4-bit head/tail pointers, matches `ring_head_ptr`/`ring_tail_ptr` width)
- **Payload buffer:** 4096 bytes total (12-bit addressing, matches `ring_desc_payload_addr` width), organized as a flat byte-addressed memory shared across all descriptors (not fixed-size slots per descriptor — variable-length payloads packed contiguously, like a real ring)
- These are v0.1 defaults sized for testbench-scale traffic, not a claimed "real" sizing — call this out explicitly if anyone reads this doc expecting production numbers.

---

## 6. Top-Level Integration Map

```
                 ┌─────────────┐
  phy_data ────► │   mac_rx    │
                 └──────┬──────┘
                        │ macrx_data / valid / sof / eof / frame_ok
              ┌─────────┼─────────────┐
              ▼         ▼             ▼
      ┌───────────┐ ┌───────────┐   (rx_descriptor_ring
      │hw_timestamp│ │udp_classi │    also taps macrx_*
      └─────┬─────┘ │  fier     │    directly for payload
            │        └─────┬─────┘    bytes — see §5)
            │ hwts_value    │ classifier_valid/accept/
            │ hwts_valid    │ dst_ip/dst_port/payload_len
            └───────┬───────┘
                     ▼
             ┌───────────────┐
             │rx_descriptor_ │◄──── sw_ren (from testbench "driver")
             │     ring      │
             └───────┬───────┘
                      │ ring_desc_* / ring_desc_valid / ring_full
                      ▼
              (testbench driver / DPDK-poll-loop stand-in)
```

**Key property to preserve:** `mac_rx` never stalls waiting on the classifier or the ring. All three downstream modules (`hw_timestamp`, `udp_classifier`, `rx_descriptor_ring`) are taps that consume the same byte stream in parallel, each maintaining their own offset/state tracking. This mirrors the real hardware constraint that line-rate ingest can't wait on a classification decision — you commit or drop *after* the fact, not gate ingest on it.

---

## 7. Simulation & Verification Plan

- **Per-module testbenches first** (`tb_mac_rx.v`, `tb_hw_timestamp.v`, `tb_udp_classifier.v`, `tb_rx_descriptor_ring.v`), each self-checking (assert-based pass/fail, not eyeballed waveforms), before integration.
- **`mac_rx` testbench** needs both good frames (valid CRC, legal length) and bad ones (bad CRC, runt, oversize) to verify `macrx_frame_ok` gating.
- **`udp_classifier` testbench** needs frames with varying IP header lengths (IHL != 5, i.e. with IP options) to actually exercise the variable-offset logic, plus frames to non-matching IPs/ports to verify reject path.
- **`rx_descriptor_ring` testbench** needs a burst that exceeds `ring_full` to verify overload/drop behavior, and back-to-back accept+reject frames to verify the speculative-write-rewind-on-reject logic.
- **`tb_top_integration.v`**: feeds a realistic mixed stream (good matching frames, good non-matching frames, bad-CRC frames, back-to-back frames with no gap) through the full pipeline and checks that only the correct frames land in the ring with correct metadata and monotonically increasing timestamps.
- Toolchain commands (add to `Makefile` once RTL exists):
  ```
  iverilog -g2012 -o sim/tb_mac_rx.out rtl/mac_rx.v tb/tb_mac_rx.v
  vvp sim/tb_mac_rx.out
  ```

---
