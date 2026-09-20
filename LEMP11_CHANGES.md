<!--
SPDX-License-Identifier: GPL-3.0-only
SPDX-FileCopyrightText: NONE
-->

# lemp11 local modifications

Three out-of-tree changes to `system76/lemp11`, for a machine with the M.2 A+E
WiFi card replaced by an Intel I226-V 2.5G NIC on an A+E adapter.

Build: `make BOARD=system76/lemp11` → `build/ec.rom`.
Flash: `make BOARD=system76/lemp11 flash_internal` (powers the system off
immediately; `CONFIG_SECURITY` is not set on this board, so no unlock needed).

## 1. Wake on LAN

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
battery.

Because the card is unpowered on battery, the line cannot be driven
legitimately then, so an assertion is only honored while on AC. That gate
replaces adding an internal pull up to C3: the board ships without one, and
system76/ec's unmerged `darp10-wol` branch removes it on the boards that have
it. Boards that do not set `CONFIG_WAKE_ON_LAN` build byte-identical firmware
(verified against upstream for darp10, lemp12, serw13, gaze20 and oryp12).

Two hardware facts this depends on, neither verifiable from this repo:

- the A+E slot must carry PCIe lanes **and** have its root port enabled in
  coreboot's devicetree (the board has `CNVI_DET#` on C4, implying a dual-mode
  slot, but that is not proof);
- the slot's `PEWAKE#` must actually connect to the `PCIE_WAKE#` net on C3.

Arm WoL in the NIC with `ethtool -s <dev> wol g` before shutting down.

## 2. Power on when AC is restored

`src/app/main/power/intel.c`, in the existing AC-connected branch of
`power_event()`: if `power_state == POWER_STATE_OFF`, call `power_on()` and set
`POWER_WAKEUP_TYPE_AC_POWER_RESTORED` (an SMBIOS wake type already defined in
`app/power.h` but never used). Gated on `CONFIG_POWER_ON_AC`.

Behaviour worth knowing:

- a normal shutdown with AC already attached produces no edge, so it does not
  fight you;
- unplugging and replugging AC while off **will** boot the machine;
- if the EC cold-boots because AC arrived on a dead battery, the machine boots —
  the intended outage-recovery case.

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
| 3 | `lemp11: Add wake on LAN via PCIE_WAKE#` | off-state rail behaviour |

Stage 0 is a year-forward jump, not a neutral baseline: the shipped EC reports
`2025-08-11_fe9c05c`, a commit that is not on upstream master and cannot be
fetched, so there is no way back to it. Master has ~34 commits since that date,
including a change of the default fan algorithm to interpolation — expect the
fan curve to behave differently even before stage 1.

Stages are cumulative, so stage 3 is the full set. Each was built and linted
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

The EC keeps running while the system is off, and its debug ring buffer is
plain RAM, so events that happen with the host down are still readable after
booting: `make BOARD=system76/lemp11 console_internal` shows the `AC restored`
and `LAN_WAKEUP# asserted` lines from before the boot.

Rolling back: flash the previous stage's `.rom` with `flash_internal` if the
system still boots, or with the external programmer if it does not.

## Verification status

- Builds clean on SDCC 4.5.0; `check-home-segment.sh` passes.
- `make lint` passes (reuse, uncrustify, shellcheck).
- **No hardware testing.** Suggested order: thresholds → AC restore → WoL, with
  an external programmer and a configured Mega 2560 on hand before flashing the
  power-sequencing changes.
