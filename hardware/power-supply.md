# Power supply

Linear, **unregulated** S-100 supply: transformer, rectifiers and big filter
caps. Each card regulates its own voltages on-board, so there are no
regulators or remote-sense lines in the supply itself.

## Filter capacitors

| Qty | Part | Rating | Rail |
|---|---|---|---|
| 2 | Sangamo DCM 64,000 µF | 15 VDC | +8 V bus rail (high current) |
| 2 | Mepco/Electra 11,000 µF | 25 VDC, 30 V surge, −10/+75 % | ±16 V bus rails |
| 1 | 12,000 µF | 40 V | 8" floppy drive supply |

## Reforming

Method: one cap at a time, lifted out of circuit, on a current-limited bench
supply (10–20 mA limit) set to the cap's rated DC voltage (not the surge
rating). Hold at voltage until the current stops falling, then discharge
through 100 Ω / 5 W.

Rough targets after ~5 minutes at rated voltage (3·√(C·V) µA, modern
datasheet style):

| Cap | Target |
|---|---|
| 64,000 µF / 15 V | under ~3 mA |
| 11,000 µF / 25 V | under ~1.5 mA |
| 12,000 µF / 40 V | under ~2 mA |

Results:

- **64,000 µF #1:** sat in current limit while reforming (about 12.5 V after
  15 min), reached 15 V, **6 mA** five minutes later, then dropped below the
  bench supply's display resolution.
- **64,000 µF #2:** behaved the same as #1.
- **11,000 µF × 2:** reformed at 25 V.
- **12,000 µF:** reformed off-board. Result not logged yet.

Capacitance and ESR not yet measured. Many meters stop around 10,000 µF; for
the big ones, time an RC discharge through 1 kΩ (time to 37 % in seconds ÷
1000 = farads).

## Rail measurements

Unloaded, all cards and drives disconnected, 12,000 µF cap out of circuit:

| Rail | Measured |
|---|---|
| +8 V | +11.9 V |
| +16 V | +20 V |
| −16 V | −20 V |

High readings are normal for an unregulated supply with no load.

## IEEE-696 limits

| Rail | Bus pins | Instantaneous minimum | Average maximum |
|---|---|---|---|
| +8 V | 1, 51 | 7 V | 11 V |
| +16 V | 2 | 14.5 V | 21.5 V |
| −16 V | 52 | −14.5 V | −21.5 V |
| Ground | 50, 100 (also 20, 53) | | |

The instantaneous minimum is the bottom of the ripple trough under load. It
keeps the on-card regulators out of dropout, so check it with a scope, not a
DMM.

## Load test (2026-10-07)

| Rail | Load | DC | Ripple |
|---|---|---|---|
| +8 V | 12 V / 100 W bulb | 9.5 V | 0.085 V AC on DMM (≈ 0.3 V p-p) |
| ±16 V | 180 Ω between the rails (≈ 0.22 A) | 40 V across both (≈ ±20 V) | within spec |

Result: **pass.**

Still to check: floppy supply with the 12,000 µF cap reinstalled, and the
outputs of the TO-3 regulator board next to the floppy.
