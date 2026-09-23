# SPDX-License-Identifier: GPL-3.0-only

board-y += board.c
board-y += gpio.c

EC = ite
CONFIG_EC_ITE_IT5570E = y
CONFIG_EC_FLASH_SIZE_128K = y

# Intel-based host
CONFIG_PLATFORM_INTEL = y
CONFIG_BUS_ESPI = y

# Include keyboard
KEYBOARD = 14in_83

# Set keyboard LED mechanism
CONFIG_HAVE_KBLED = y
CONFIG_KBLED = white_dac
CONFIG_KBLED_DAC = 2

# Set battery I2C bus
CONFIG_I2C_SMBUS = I2C_4

# Set touchpad PS2 bus
CONFIG_PS2_TOUCHPAD = PS2_3

# Set smart charger parameters
CONFIG_CHARGER = oz26786
CONFIG_CHARGER_ADAPTER_RSENSE = 5
CONFIG_CHARGER_BATTERY_RSENSE = 5
CONFIG_CHARGER_CHARGE_CURRENT = 3072
CONFIG_CHARGER_CHARGE_VOLTAGE = 8800
CONFIG_CHARGER_INPUT_CURRENT = 3420

# Power on when the AC adapter is connected
CONFIG_POWER_ON_AC = y

# Wake on LAN via PCIE_WAKE# (C3). Off: on this board the M.2 A+E slot's
# PEWAKE# does not reach C3, and C3 reads low once power_off() runs, so the
# system powers straight back on while off on AC. See LEMP11_CHANGES.md.
CONFIG_WAKE_ON_LAN = n

# Set battery charging thresholds
BATTERY_START_THRESHOLD = 60
BATTERY_END_THRESHOLD = 75

# Set CPU power limits in watts
CONFIG_POWER_LIMIT_AC = 65
CONFIG_POWER_LIMIT_DC = 45

# Fan configs
CONFIG_FAN1_PWM = DCR2
# The first two points are a floor for running outside the chassis, where
# nothing else moves air over the board or the drives. Stock starts at 70 C,
# leaving the fan off below that (fan_duty() returns 0% below the first point).
CONFIG_FAN1_POINTS = " \
	FAN_POINT(0, 20), \
	FAN_POINT(50, 20), \
	FAN_POINT(70, 40), \
	FAN_POINT(75, 50), \
	FAN_POINT(80, 60), \
	FAN_POINT(85, 65), \
	FAN_POINT(90, 65), \
"
