# Almond LCD Menu

OpenWrt LCD UI for devices with touchscreen displays.

## Quick Install

Run this one-line command on your OpenWrt device:

```sh
sh <(wget -O - https://raw.githubusercontent.com/zipfo/almond-lcd-menu/refs/heads/main/install.sh)
```

## Manual Installation

1. Copy `lcd_ui.uc` to `/usr/bin/lcd_ui.uc`
2. Copy `uqmi_status.sh` to `/usr/bin/uqmi_status.sh`
3. Make both files executable: `chmod +x /usr/bin/lcd_ui.uc /usr/bin/uqmi_status.sh`

## Usage

Restart LCD UI (if need):

```sh
/etc/init.d/lcd_ui restart
```

## Files

- `lcd_ui.uc` - Main LCD UI application
- `uqmi_status.sh` - LTE status collection script
- `install.sh` - Automated installation script
