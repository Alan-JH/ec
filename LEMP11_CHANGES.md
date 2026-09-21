<!--
SPDX-License-Identifier: GPL-3.0-only
SPDX-FileCopyrightText: NONE
-->

# lemp11 local modifications

Three out-of-tree changes to `system76/lemp11`, for a machine with the M.2 A+E
WiFi card replaced by an Intel I226-V 2.5G NIC on an A+E adapter. Wake on LAN
(section 1) failed on hardware and is switched off; the other two are in use.
The NIC itself, including the adapter mod it needs, is covered in
`LEMP11_TRUENAS.md`.

Build: `make BOARD=system76/lemp11` → `build/ec.rom`.
Flash: `make BOARD=system76/lemp11 flash_internal` (powers the system off
immediately; `CONFIG_SECURITY` is not set on this board, so no unlock needed).

## 1. Wake on LAN — shelved, `CONFIG_WAKE_ON_LAN = n`

**This does not work on this board, and the switch is off.** The code stays so
that it can be revisited after a hardware mod. With it off, the branch tip
builds a ROM byte-identical to stage 2 (checked with
`VERSION=stage2-ac-restore`). What went wrong is under
[Stage 3 results](#stage-3-results); the original design follows.

`PCIE_WAKE#` reaches the EC on GPIO C3 but was declared and unused. Wiring it
up as `LAN_WAKEUP_N` activates the existing handler in `power/intel.c`.

| File | Change |
| --- | --- |
| `src/board/system76/lemp11/include/board/gpio.h` | declare `LAN_WAKEUP_N` under `CONFIG_WAKE_ON_LAN`, else keep `HAVE_LAN_WAKEUP_N 0` |
| `src/board/system76/lemp11/gpio.c` | `LAN_WAKEUP_N = GPIO(C, 3)` (guarded); `GPCRC3` left as plain `GPIO_IN` |
| `src/app/main/power/intel.c` | `power_wol_keep_powered()` helper; gates both `power_off()`'s `wireless_power()` and the wake handler on AC |
| `src/app/main/Makefile.mk`, board `Makefile.mk` | `CONFIG_WAKE_ON_LAN` |

`power_off()` previously called `wireless_power(false)`, cutting power to the
M.2 slot — an unpowered card cannot assert `WAKE#`. It is now left powered, but
**only while on AC**, so a NIC waiting for a magic packet never drains the
battery. The AC branch of `power_event()` follows the adapter while off:
unplugging cuts the card, and replugging powers it again. Without that, a
shutdown on AC followed by an unplug would leave the card on the battery
indefinitely.

Because the card is unpowered on battery, the line cannot be driven
legitimately then, so an assertion is only honored while on AC. That gate
replaces adding an internal pull up to C3: the board ships without one, and
system76/ec's unmerged `darp10-wol` branch removes it on the boards that have
it. Boards that do not set `CONFIG_WAKE_ON_LAN` build byte-identical firmware
(verified against upstream for darp10, lemp12, serw13, gaze20 and oryp12).

The hardware facts this depended on, as tested:

- the A+E slot carries PCIe and its root port is enabled — **true** (PCH RP#5,
  `00:1c.0`; coreboot's `.clk_req = 2` also needed an adapter mod);
- the slot's `PEWAKE#` connects to the `PCIE_WAKE#` net on C3 — **false**;
- `PCIE_WAKE#` stays high while the system is off — **false**;
- the slot's 3.3 V survives `power_off()` when `WLAN_PWR_EN` is kept high —
  **true** (the card's RJ45 link LED stays lit while off on AC).

### Stage 3 results

Flashed 2026-09-21 with the I226 installed. On AC, every shutdown was followed
by a boot about 12 s later, the time it takes to reach `power_off()`.

| Test | Result |
| --- | --- |
| shutdown on AC, `wol g` or `wol d` | boots again after ~12 s |
| shutdown on battery, `wol g` or `wol d` | stays off |
| rebuilt with `CONFIG_POWER_ON_AC=n`, shutdown on AC | boots again, so not stage 2 |
| internal pull-up on C3 (`GPIO_IN \| GPIO_UP`) | no change |
| card removed, shutdown on AC | boots again, so not the card |
| slot pin 55 grounded through 1 kΩ, host on, `console_internal` running | no `LAN_WAKEUP#` message |
| same, watching `GPP_D13` (`WLAN_WAKEUP#`, pinctrl pin 112) | no change |
| control: slot pin 53 grounded, watching `SRCCLKREQB_2` (pin 106) | `0x44000702` → `0x44000700` |

Two independent faults:

1. **C3 falls once the system is off.** Its board pull up does not survive
   `power_off()` and wins against the EC's internal pull up. On AC the wake
   handler takes that as `LAN_WAKEUP#` and boots. This alone makes stage 3
   unusable: the machine cannot stay off on AC.
2. **The slot's `PEWAKE#` reaches neither C3 nor the PCH's `GPP_D13`.** Given
   the control, it is most likely not connected on this board, which fits a
   slot built for a CNVi card. So even a fixed C3 would never see a magic
   packet, and there is no firmware-only route, EC or coreboot.

The only remaining route is hardware: cut the adapter's finger-55 trace and
wire the I226's `PE_WAKE_N` to an unconnected EC input (`GPA4` and `GPA5` are
marked not connected in `gpio.c`), with its own pull up from the card's 3.3 V,
then point `LAN_WAKEUP_N` at that pin. That means soldering to a 0.4 mm pitch
LQFP with no external EC programmer for recovery, so it has not been tried.

For remote power-on, stage 2 is enough: put the adapter on a smart plug and
switch it off and on.

## 2. Power on when AC is restored

`src/app/main/power/intel.c`, in the existing AC-connected branch of
`power_event()`: if `power_state == POWER_STATE_OFF`, call `power_on()` and set
`POWER_WAKEUP_TYPE_AC_POWER_RESTORED` (an SMBIOS wake type already defined in
`app/power.h` but never used). Gated on `CONFIG_POWER_ON_AC`.

Behaviour worth knowing:

- a normal shutdown with AC already attached produces no edge, so it should
  not fight you (not yet checked on hardware with stage 2 alone);
- unplugging and replugging AC while off **will** boot the machine;
- if the EC cold-boots because AC arrived on a dead battery, the machine boots —
  the intended outage-recovery case (not tested);
- flashing stage 2 over stage 3 with AC attached left the machine off. The
  stage 3 builds did boot after their flashes, but that was C3, not an AC edge.

## 3. Charge thresholds 60–75%

`src/board/system76/lemp11/Makefile.mk`: `BATTERY_START_THRESHOLD = 60`,
`BATTERY_END_THRESHOLD = 75`. Board Makefiles are included before the `?=`
defaults in `src/app/main/Makefile.mk`, so these win.

Charging stops above 75 and resumes below 60 (`battery_charger_configure()`).

**Gotcha:** thresholds are persisted to flash at `CONFIG_EC_FLASH_SIZE - 2K`
and `battery_load_thresholds()` overrides the compile-time defaults whenever
the magic is present. If thresholds were ever set from the OS, the saved pair
wins. Either hold Fn+Esc at power-on to reset the config, or set them at
runtime, which persists:

```sh
echo 60 | sudo tee /sys/class/power_supply/BAT0/charge_control_start_threshold
echo 75 | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold
```

Note the consequence either way: `acpi.c:226` calls `battery_save_thresholds()`
on *every* OS write, so as soon as anything writes those files the flash copy
wins at each boot and editing the board Makefile has no further effect. That
includes GNOME's battery-preservation toggle, which writes UPower's own
unrelated 75/80 pair — leave it alone unless you want that to stick.

Between the thresholds `should_charge` keeps its previous value, so the band is
hysteresis, not a target. Plugging in at 61% or 70% does nothing at all — that
is correct behaviour, not a failure to charge.

The gauge may report nonsense at the moment of cutoff. On one 8% → 75% charge
the indicator jumped straight to 100% and Ubuntu said "fully charged"; on a
58% → 76% charge it correctly read `Not charging` and held. `charge_now` was
continuous across both, and the relaxed cell voltage confirms the pack really
is held low, so this is a reporting artifact, not a charging failure. Trust
`voltage_now` at zero current over the percentage.

## Not implemented: scheduled boot

An EC-side countdown (armed by the host, kept in battery-backed RAM, new
`wake_timer.c` plus SMFI/ACPI/ectool plumbing) was written and then removed as
too convoluted for what it bought.

The EC has no RTC, and `power_off()` drops the PCH deep well, so the PCH's own
RTC alarm cannot wake the machine from a normal off state. The change that
gets scheduled boot with **no EC code** is to disable Deep Sx in coreboot:
`VW_SUS_PWRDN_ACK` then stays low, the `power_off()` call in `power_event()`
never runs, S5 rails stay up, and `rtcwake` works natively. That is a
firmware-open change, and it costs idle power in S5.

## Flashing in stages

Each feature is one commit on the `lemp11-mods` branch, in increasing order of
risk. Check one out, build, flash, test, then move to the next.

| Stage | Commit | Touches power sequencing? |
| --- | --- | --- |
| 0 | `master` | no — baseline, keep this `ec.rom` as the rollback target |
| 1 | `lemp11: Cap battery charge at 60-75%` | no |
| 2 | `power: Add option to power on when AC is restored` | boot path only |
| 3 | `lemp11: Add wake on LAN via PCIE_WAKE#` plus `power: Follow AC for the M.2 card while off` | off-state rail behaviour; **failed, see section 1** |

The branch tip has `CONFIG_WAKE_ON_LAN = n`, so it builds stage 2. That is the
image to run.

Stage 0 is a year-forward jump, not a neutral baseline: the shipped EC reports
`2025-08-11_fe9c05c`, a commit that is not on upstream master and cannot be
fetched. The source is gone, but the image is not — `flash_internal` dumps the
running ROM to `./backup.rom` before writing, so the first stage 0 flash
produced a byte-exact copy of the shipped firmware, and flashing that back is a
full return to factory.

**`backup.rom` is rewritten by every `flash_internal`, and it is
`.gitignore`d.** Copy it out of the repo before the next flash or stage 0's
image takes its place. The copy from the first flash is
`~/ec-roms/factory-2025-08-11_fe9c05c.rom`, sha256 `4cc7e381…`.

Master has ~34 commits since that date, including a change of the default fan
algorithm to interpolation — expect the fan curve to behave differently even
before stage 1.

Stages are cumulative, so stage 3 is the full set, but only stage 2 is in use. Each was built and linted
before being committed.

```sh
git checkout <commit>
make clean
make BOARD=system76/lemp11 VERSION=stage2-ac-restore
cp build/ec.rom ~/ec-roms/stage2-ac-restore.rom
make BOARD=system76/lemp11 flash_internal
```

Tag each build with `VERSION`, which is `?=` in the top-level Makefile.
Otherwise every stage reports `<date>_<rev>-dirty` and `ectool info` cannot
tell you which one is running.

To disable one feature without moving off the tip, flip its switch in
`src/board/system76/lemp11/Makefile.mk` to `n` — `CONFIG_POWER_ON_AC` and
`CONFIG_WAKE_ON_LAN` each gate their whole feature, including the
`LAN_WAKEUP_N` GPIO declaration.

`console_internal` is a **live tail, not a scrollback dump.** It seeds its read
pointer from the current head and prints only bytes written after you attach
(`tools/system76_ectool/src/main.rs:14-33`), and the buffer is `smfi_dbg[256]`
with index 0 holding the tail pointer (`src/app/main/smfi.c:77,492`) — 255
bytes, about three lines. A single `battery_debug()` dump overruns it. Events
that happened before you attached are gone.

That rules out verifying stages 2 and 3 by booting and reading back what the EC
logged while the host was down. Use `console_external` over the Mega 2560 into
a second machine, which streams while this one is off.

Run `console_internal` **without** `sudo` — the target already sudoes just the
binary, and running make itself under sudo drops `~/.cargo/bin` from `PATH`, so
`cargo` is not found. If the tool is already built, skip make entirely:

```sh
sudo tools/system76_ectool/target/release/system76_ectool console
```

It busy-polls with a 1 ms sleep, so do not leave it running during any
measurement of idle power draw.

Rolling back: flash the previous stage's `.rom` with `flash_internal` if the
system still boots, or with the external programmer if it does not. The same
two paths apply to `factory-2025-08-11_fe9c05c.rom` to go back to the shipped
firmware.

## Verification status

- Builds clean on SDCC 4.5.0; `check-home-segment.sh` passes.
- `make lint` passes (reuse, uncrustify, shellcheck).
- Stage 0 (master, built as `stage0-baseline`) flashed with `flash_internal`
  and booted on 2026-09-20.
- Stage 1 (`stage1-charge-thresholds`) flashed 2026-09-20 and **confirmed on
  hardware** overnight into 2026-09-21. Every branch of
  `battery_charger_configure()` that these thresholds can reach was exercised:

  | Observation | Branch | Result |
  | --- | --- | --- |
  | AC at 96% | not discriminating — the gauge's `FULLY_CHARGED` bit trips line 74 first | no charge |
  | AC at 70%, at 61% | fall-through, hysteresis holds | no charge |
  | AC at 58% | `charge < start_threshold` | `Charger enabled`, 3.10 A |
  | cutoff at 76% | `charge > end_threshold` | `Not charging`, 0 A, 5793 mAh |
  | held 7 h on AC | — | 5787 mAh, 8.216 V, 6 mAh self-discharge |

  The `start_threshold == BATTERY_START_DEFAULT` branch is unreachable here,
  since 60 is not 0.

  The pack rests at 8.216 V, 4.108 V/cell against the charger's 4.4 V/cell
  target (`ChargeVoltage 2260`), so it is genuinely held well below full. No
  trickle and no cycling at the threshold.
- Stage 2 (`stage2-ac-restore`) flashed 2026-09-21 with `flash_internal`;
  **confirmed on hardware** — connecting AC while off boots the machine.
- Stage 3 (`stage3-wol`, and test builds `stage3-wol-pullup` and
  `stage3-no-acrestore`) flashed 2026-09-21 and **failed on hardware**. See
  [Stage 3 results](#stage-3-results). Stage 2 was flashed back the same day.
  The branch tip with `CONFIG_WAKE_ON_LAN = n` builds a ROM byte-identical to
  `~/ec-roms/stage2-ac-restore.rom`.
