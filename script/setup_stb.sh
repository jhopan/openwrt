#!/bin/sh

echo "Updating opkg..."
opkg update >/dev/null 2>&1

echo "Removing Mihomo..."
opkg remove --force-removal-of-dependent-packages mihomo luci-app-mihomo luci-i18n-mihomo-id luci-i18n-mihomo-en luci-i18n-mihomo-zh-cn >/dev/null 2>&1
rm -rf /etc/mihomo /etc/config/mihomo /var/log/mihomo /usr/bin/mihomo /etc/init.d/mihomo /tmp/log/mihomo /usr/libexec/mihomo-call /etc/rc.d/*mihomo /usr/lib/lua/luci/controller/mihomo* /usr/lib/lua/luci/model/cbi/mihomo* /usr/lib/lua/luci/view/mihomo*

echo "Removing Passwall & Dependencies..."
opkg remove --force-removal-of-dependent-packages luci-app-passwall kmod-nf-tproxy kmod-nft-tproxy >/dev/null 2>&1
rm -rf /etc/config/passwall /usr/share/passwall /etc/passwall /var/etc/passwall /tmp/etc/passwall /tmp/log/passwall /etc/init.d/passwall /usr/lib/lua/luci/controller/passwall* /usr/lib/lua/luci/model/cbi/passwall* /usr/lib/lua/luci/view/passwall*
rm -f /usr/bin/xray /usr/bin/v2ray /usr/bin/trojan

echo "Replacing Tailscale GUI with CLI..."
opkg remove --force-removal-of-dependent-packages luci-app-tailscale >/dev/null 2>&1
opkg install tailscale

echo "Installing Andromodem..."
wget -qO- https://raw.githubusercontent.com/basiooo/andromodem/main/andromodem_openwrt.sh | sh -s install

echo "Cleanup & Install Complete."