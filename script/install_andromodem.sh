#!/bin/sh
echo "Installing Andromodem..."
wget -O - https://raw.githubusercontent.com/basiooo/andromodem/main/andromodem_openwrt.sh | sh -s install
echo "Andromodem installation completed."