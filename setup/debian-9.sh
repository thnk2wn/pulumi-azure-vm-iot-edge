#!/bin/bash

hub_connection=""

while [[ $# -ge 1 ]]; do
    i="$1"
    case $i in
        -h|--hub)
            hub_connection=$2
            shift
            ;;
        *)
            echo "Unrecognized option $1"
            exit 1
            ;;
    esac
    shift
done

if [ -z "$hub_connection" ]; then
  echo "Hub connection is required (-h | --hub)" >&2
  exit 1
fi

# Output host info
uname -a
lscpu

echo "Updating system"
apt update && apt upgrade

if [ $? -ne 0 ]; then
    # E: Could not get lock /var/lib/apt/lists/lock - open (11: Resource temporarily unavailable)
    ps aux | grep '[a]pt'

    attempt=0
    until [ $attempt -ge 5 ]
    do
        sleep 5s
        echo "Retrying updating package lists"
        apt update && apt upgrade && break
        attempt=$[$attempt+1]
    done
fi

echo "Installing curl"
apt-get -y install curl

echo "Installing repository configuration"
curl https://packages.microsoft.com/config/debian/stretch/multiarch/prod.list > ./microsoft-prod.list
cp ./microsoft-prod.list /etc/apt/sources.list.d/

echo "Installing gpg for public key"
apt-get -y install gnupg

echo "Installing the Microsoft GPG public key"
curl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > microsoft.gpg
cp ./microsoft.gpg /etc/apt/trusted.gpg.d/

# IoT Edge can't be installed via apt-get here since this is a Tier 2 linux VM and not Tier 1 target device.

echo "Installing Moby Engine"
curl -L \
    https://github.com/Azure/azure-iotedge/releases/download/1.0.7/moby-engine_3.0.5_amd64.deb \
    -o moby_engine.deb \
    && dpkg -i ./moby_engine.deb

echo "Installing Moby CLI"
curl -L \
    https://github.com/Azure/azure-iotedge/releases/download/1.0.7/moby-cli_3.0.5_amd64.deb \
    -o moby_cli.deb \
    && dpkg -i ./moby_cli.deb

echo "Installing IoT Edge hsmlib and security daemon"
curl -L \
    https://github.com/Azure/azure-iotedge/releases/download/1.0.9/libiothsm-std_1.0.9-1-1_debian9_amd64.deb \
    -o libiothsm-std.deb \
    && dpkg -i ./libiothsm-std.deb

curl -L \
    https://github.com/Azure/azure-iotedge/releases/download/1.0.9/iotedge_1.0.9-1_debian9_amd64.deb \
    -o iotedge.deb \
    && dpkg -i ./iotedge.deb

# Certs expire after 90 days but may not need to setup if VM is being created each time.
# https://docs.microsoft.com/en-us/azure/iot-edge/how-to-install-production-certificates

# Configure the Security Daemon
# TODO: Device Provisioning Service instead of manual configuration
# https://github.com/MicrosoftDocs/azure-docs/blob/master/articles/iot-edge/how-to-install-iot-edge-linux.md#configure-the-security-daemon
configFile=/etc/iotedge/config.yaml

# wait to set connection string until config.yaml is available
until [ -f $configFile ]
do
    sleep 2
done

sed -i "s#\(device_connection_string: \).*#\1\"$hub_connection\"#g" $configFile
# TODO: update certificate paths in config file if certs are created later

dockerPath=/etc/docker

[[ -d $dockerPath ]] || mkdir $dockerPath

cat > $dockerPath/daemon.json <<EOL
{
    "dns": [
    ],

    "log-driver": "json-file",

    "log-opts": {
        "max-size": "5m",
        "max-file": "3"
    }
}
EOL

# After configuration is done, restart iotedge
systemctl restart iotedge

# After a restart, run checks on configuration, connectivity...
iotedge check

# Check status of IoT Edge Daemon
systemctl status iotedge

# Cleanup temporary downloaded items that were installed / copied elsewhere
rm iotedge.deb  libiothsm-std.deb  microsoft.gpg  microsoft-prod.list  moby_cli.deb  moby_engine.deb