#!/bin/sh
# OpenWrt installation script for Almond LCD Menu
# Automatically downloads and installs lcd_ui.uc and uqmi_status.sh

set -e

REPO_URL="https://raw.githubusercontent.com/zipfo/almond-lcd-menu/main"
LCD_UI_DEST="/usr/bin/lcd_ui.uc"
UQMI_STATUS_DEST="/usr/bin/uqmi_status.sh"

echo "Installing Almond LCD Menu..."

# Download lcd_ui.uc
echo "Downloading lcd_ui.uc..."
wget -O "$LCD_UI_DEST" "$REPO_URL/lcd_ui.uc"
chmod +x "$LCD_UI_DEST"

# Download uqmi_status.sh
echo "Downloading uqmi_status.sh..."
wget -O "$UQMI_STATUS_DEST" "$REPO_URL/uqmi_status.sh"
chmod +x "$UQMI_STATUS_DEST"
/etc/init.d/lcd_ui restart
echo "Installation complete!"
echo "Files installed:"
echo "  - $LCD_UI_DEST"
echo "  - $UQMI_STATUS_DEST"
