#!/bin/sh
set -eu

case $1 in
    amd64)
        ARCH="64"
        FNAME="amd64"
        ;;
    386 | i386)
        ARCH="32"
        FNAME="386"
        ;;
    armv8 | arm64 | aarch64)
        ARCH="arm64-v8a"
        FNAME="arm64"
        ;;
    armv7 | arm | arm32)
        ARCH="arm32-v7a"
        FNAME="arm"
        ;;
    armv6)
        ARCH="arm32-v6"
        FNAME="arm"
        ;;
    *)
        echo "Unsupported Docker architecture: $1" >&2
        exit 1
        ;;
esac
mkdir -p build/bin
cd build/bin || exit 1
curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --remote-name \
  "https://github.com/XTLS/Xray-core/releases/download/v26.4.25/Xray-linux-${ARCH}.zip"
unzip "Xray-linux-${ARCH}.zip"
rm -f "Xray-linux-${ARCH}.zip" geoip.dat geosite.dat
mv xray "xray-linux-${FNAME}"
curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --remote-name https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --remote-name https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --output geoip_IR.dat https://github.com/chocolate4u/Iran-v2ray-rules/releases/latest/download/geoip.dat
curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --output geosite_IR.dat https://github.com/chocolate4u/Iran-v2ray-rules/releases/latest/download/geosite.dat
curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --output geoip_RU.dat https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat
curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --output geosite_RU.dat https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat
test -x "xray-linux-${FNAME}"
for file in geoip.dat geosite.dat geoip_IR.dat geosite_IR.dat geoip_RU.dat geosite_RU.dat; do
  test -s "$file"
done
cd ../../
