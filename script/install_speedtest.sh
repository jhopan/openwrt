#!/bin/sh
echo "Downloading Speedtest CLI..."
wget --no-check-certificate https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz -O /tmp/speedtest.tgz

echo "Extracting..."
tar -xzvf /tmp/speedtest.tgz -C /usr/bin/

echo "Setting permissions..."
chmod +x /usr/bin/speedtest

echo "Cleaning up..."
rm -f /tmp/speedtest.tgz

echo "Installation complete. You can now run 'speedtest'."