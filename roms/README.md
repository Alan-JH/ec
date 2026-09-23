<!--
SPDX-License-Identifier: GPL-3.0-only
SPDX-FileCopyrightText: NONE
-->

# Built EC images for lemp11

Every image flashed to this machine, kept here because one of them cannot be
rebuilt and the rest are tedious to reproduce. See `../LEMP11_CHANGES.md` for
what each change does and how the stages were tested.

Built with **SDCC 4.5.0** (`TD- 4.5.0 #15242`). A different SDCC will not
reproduce these byte for byte.

| Image | sha256 | Built from |
| --- | --- | --- |
| `factory-2025-08-11_fe9c05c.rom` | `4cc7e381…` | **not reproducible**, see below |
| `stage0-baseline.rom` | `6f3c26fc…` | `5f36175` (`master`) |
| `stage1-charge-thresholds.rom` | `d9eb640b…` | `1ffdbd7` |
| `stage2-ac-restore.rom` | `ead6ecc7…` | `2e135b3` |
| `stage3-wol.rom` | `75cb8d27…` | `b407aee` |
| `stage3-wol-pullup.rom` | `a0dead05…` | `b407aee` plus an uncommitted `GPIO_UP` on C3 |
| `stage3-no-acrestore.rom` | `bb381830…` | `b407aee` plus that pull-up, built `CONFIG_POWER_ON_AC=n` |
| `stage4-fan-floor.rom` | `ba7f874e…` | `d1267ca` — **currently running** |
| `stage5-usb-charge.rom` | `da98b5df…` | `eada292` |

Every "built from" row except the factory image was verified by rebuilding it
and comparing byte for byte, including the two experiments: the pull-up was
`{ &GPCRC3, GPIO_IN | GPIO_UP }` in the board's `gpio.c`.

The `VERSION` string is part of the image, so a rebuild must pass the same one,
which is the file's basename:

```sh
make BOARD=system76/lemp11 VERSION=stage4-fan-floor
```

Two images match no commit on their own: `stage3-wol-pullup` came from a
pull-up experiment that was reverted (`LEMP11_CHANGES.md` section 1), and
`stage3-no-acrestore` is that same tree built with a command-line override, to
rule stage 2 out as the cause of the false wakes. Both exist only here.

## The factory image

`factory-2025-08-11_fe9c05c.rom` is the firmware the machine shipped with, as
dumped by the first `flash_internal` (it writes `backup.rom` before flashing).
The EC reported it as `2025-08-11_fe9c05c`, a commit that is not on upstream
master and cannot be fetched, so this image **cannot be rebuilt from source.**
Flashing it back is a full return to factory.

It is a build of `system76/ec`, which is GPL-3.0-only, and the corresponding
source for this particular build is not publicly available. It is kept here
purely as a recovery image for this one machine.

## Flashing

```sh
sudo tools/system76_ectool/target/release/system76_ectool flash roms/<image>.rom
```

The machine powers off as it finishes. `system76_ectool` needs a Rust
toolchain to build and is gitignored, so from a wiped machine, boot a live
Ubuntu USB and build it there — see "Before reinstalling the OS" in
`../LEMP11_TRUENAS.md`.

Verify what is running with:

```sh
sudo tools/system76_ectool/target/release/system76_ectool info
```
