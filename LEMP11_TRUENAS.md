<!--
SPDX-License-Identifier: GPL-3.0-only
SPDX-FileCopyrightText: NONE
-->

# lemp11 I226-V NIC under TrueNAS

What TrueNAS needs to use the Intel I226-V in the M.2 A+E slot, and how to
power the machine on remotely without wake on LAN. This covers the Linux-based
TrueNAS (Community Edition, formerly SCALE). The EC side is described in
`LEMP11_CHANGES.md`.

## Hardware state this assumes

- **Adapter:** UEEGO M.2 A+E to I226-V (Amazon B0G4J54K18), in J_WLAN1. The
  I226 sits on the M.2 card itself, so the PCIe path is just slot to chip. The
  20 cm cable carries only the Ethernet pairs to a second board with the
  magnetics and RJ45.
- **CLKREQ# mod:** the adapter leaves finger 53 (CLKREQ0#) as a bare pad.
  lemp11's coreboot gates the slot's reference clock on CLKREQ#
  (`pch_pcie_rp[PCH_RP(5)]`, `.clk_req = 2`), so the card never got a clock
  and was invisible (`PresDet-`). Finger 53 is now wired to ground, which
  keeps the clock running.
- **PERST#:** finger 52 (bottom side) is routed to the I226 through a 0 Ω
  resistor. A nearby unpopulated footprint looks like a pull-down to ground.
  Leave it empty: fitted, it would hold the card in reset. Keep solder from
  the finger-53 mod away from it.
- **PEWAKE#:** finger 55 has a trace to the I226, but on the laptop side the
  slot's pin 55 reaches neither the EC (C3) nor the PCH (`GPP_D13`). The card
  has no way to wake the system, so wake on LAN is not available. See
  `LEMP11_CHANGES.md`, section 1.

| Item | Value |
| --- | --- |
| Root port | `0000:00:1c.0` (PCH RP#5, ACPI `\_SB_.PCI0.RP01`) |
| NIC | `0000:2d:00.0`, `8086:125c` rev 04 |
| Driver | `igc`, in the stock kernel; nothing to install |
| Interface name | `enp45s0` (bus 0x2d = 45); confirm on TrueNAS |
| MAC | `c4:62:37:0f:aa:22` |
| Link | 5 GT/s x1, 4 Gb/s, enough for 2.5GbE |

## The problem TrueNAS has to work around

Right after the CLKREQ# mod, the link trained **after** the kernel's boot-time
PCI scan. The kernel logged:

```
pci 0000:00:1c.0: broken device, retraining non-functional downstream link at 2.5GT/s
pci 0000:00:1c.0: retraining failed
```

and the NIC was missing until something rescanned. The port has no hotplug
(no `pciehp` on `1c.0`), so nothing does that on its own. After a manual
retrain and rescan the link came up at 5 GT/s and `igc` bound normally. A few
correctable `RxErr` messages during training are expected and stop once the
link is up.

After the card was reseated, it enumerated at boot on every later boot, with no
retrain messages. The cause of the earlier failures is not known, so keep the
boot command below as insurance: it does nothing when the NIC is already there.

The empty port also runtime-suspends to D3cold, which drives `WLAN_RST#`
(`GPP_B17`) low. Given how unreliably this link has trained, keep both the port
and the NIC out of runtime suspend so a resume never has to retrain it.

## What to configure

TrueNAS is an appliance: packages or files added to the boot pool by hand are
unsupported and are lost on update. `igc` and `setpci` (pciutils) are in the
base image, so the only thing to add is a boot-time command, stored in the
TrueNAS config database so it survives updates.

**System → Advanced Settings → Init/Shutdown Scripts → Add**

- Type: **Command**
- When: **Pre Init**, so the interface exists before network configuration.
  If the IP is not applied at boot, see Troubleshooting.
- Enabled: yes
- Command:

```sh
sh -c 'D=/sys/bus/pci/devices; echo on > $D/0000:00:1c.0/power/control; for i in 1 2 3 4 5; do [ -e $D/0000:2d:00.0 ] && break; setpci -s 00:1c.0 CAP_EXP+10.w=0020:0020; sleep 1; echo 1 > /sys/bus/pci/rescan; done; [ -e $D/0000:2d:00.0 ] || { logger -t lemp11-nic "I226 did not enumerate"; exit 1; }; echo on > $D/0000:2d:00.0/power/control'
```

It does the same steps you would by hand:

1. Keep root port `1c.0` powered (`power/control = on`).
2. Retrain the link (Link Control bit 5 via `setpci`) and rescan, up to five
   times, until `2d:00.0` appears. If it never does, log `I226 did not
   enumerate` to syslog.
3. Keep the NIC out of runtime suspend.

## Installing

1. Install TrueNAS as usual. The installer does not need the I226.
2. If the I226 is missing on first boot, use the USB-C dongle, which the stock
   kernel supports, or the local console to reach the web UI.
3. Add the Init command above, and reboot.
4. Check that `enp45s0` is present and configure it under **Network**. Once
   it works, the dongle can be removed.

## Remote power-on

Wake on LAN is not possible on this board (see the PEWAKE# note above). Use
stage 2 of the EC changes instead, which boots the machine when AC arrives
while it is off:

- Put the laptop's adapter on a smart plug. To power the NAS on remotely,
  switch the plug off, then on again.
- The same behaviour brings the machine back after a power outage.
- A shutdown with AC attached should leave the machine off: there is no AC
  edge. After flashing stage 2 on AC the machine did stay off, but a normal OS
  shutdown on AC under stage 2 has not been checked yet. Try it once before
  relying on it.

Wake from suspend (`s2idle`) might still work, since it can use an in-band PCIe
PME instead of the missing wake pin. It is untested, and TrueNAS does not
support suspend, so it is not pursued here.

## Verifying on TrueNAS

From the TrueNAS shell, after a reboot:

```sh
lspci -nnk -s 2d:00.0                                  # I226-V, driver igc
cat /sys/bus/pci/devices/0000:2d:00.0/current_link_speed   # 5.0 GT/s PCIe
journalctl -b -t lemp11-nic                             # empty if it enumerated
```

## Troubleshooting

- **Link at 2.5 GT/s instead of 5.** The kernel's failed-retrain quirk can
  leave the port's target speed at 2.5 GT/s, which caps throughput around
  2 Gb/s. Restore the target speed to 5 GT/s and retrain:
  `setpci -s 00:1c.0 CAP_EXP+30.w=0002:000f; setpci -s 00:1c.0 CAP_EXP+10.w=0020:0020`.
- **NIC present but its IP is not applied at boot.** The Init command ran after
  TrueNAS configured interfaces. Try **Post Init** instead. If that is still too
  late, append `; midclt call interface.sync` to the command. That method is a
  TrueNAS middleware internal, so check that it exists on your release first.
- **Link drops or flaps.** Check the finger-53 wire first, since it sits next to
  REFCLK− on pin 49. Pins 47 and 49 must not read near 0 Ω to ground. If the
  PCIe link is stable but the Ethernet link renegotiates, check the cable to
  the RJ45 board, then try `ethtool --set-eee enp45s0 eee off`,
  a common I225/I226 workaround.
- **Never enumerates** (`I226 did not enumerate` in the journal). Check the
  seating of the M.2 card and the finger-53 wire, and check that nothing
  bridges the unpopulated PERST# pull-down footprint. The 20 cm cable carries
  only Ethernet, so it cannot affect enumeration.
