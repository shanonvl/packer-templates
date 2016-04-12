#!/bin/bash

#
# update.sh
#
# Copyright 2016 Krzysztof Wilczynski
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -e

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

export DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical
export DEBCONF_NONINTERACTIVE_SEEN=true

readonly UBUNTU_RELEASE=$(lsb_release -sc)
readonly UBUNTU_VERSION=$(lsb_release -r | awk '{ print $2 }')

# Get the major release version only.
readonly UBUNTU_MAJOR_VERSION=$(lsb_release -r | awk '{ print $2 }' | cut -d . -f 1)

readonly COMMON_FILES='/var/tmp/common'

# This is only applicable when building Amazon EC2 image (AMI).
AMAZON_EC2='no'
if wget -q --timeout 1 --tries 2 --wait 1 -O - http://169.254.169.254/ &>/dev/null; then
    AMAZON_EC2='yes'
fi

cat <<'EOF' > /etc/apt/apt.conf.d/00trustcdrom
APT
{
    Authentication
    {
        TrustCDROM "false":
    };
};
EOF

chown root: /etc/apt/apt.conf.d/00trustcdrom
chmod 644 /etc/apt/apt.conf.d/00trustcdrom

cat <<'EOF' > /etc/apt/apt.conf.d/15update-stamp
APT
{
    Update
    {
        Post-Invoke-Success
        {
            "touch /var/lib/apt/periodic/update-success-stamp 2>/dev/null || true";
        };
    };
};
EOF

chown root: /etc/apt/apt.conf.d/15update-stamp
chmod 644 /etc/apt/apt.conf.d/15update-stamp

# Any Amazon EC2 instance can use local packages mirror, but quite often
# such mirrors are backed by an S3 buckets causing performance drop due
# to a known problem outside of the "us-east-1" region when using HTTP
# pipelining for more efficient downloads.
PIPELINE_DEPTH=5
if [[ $AMAZON_EC2 == 'yes' ]]; then
     PIPELINE_DEPTH=0
fi

cat <<EOF > /etc/apt/apt.conf.d/99apt-acquire
Acquire
{
    PDiffs "0";

    Retries "3";
    Queue-Mode "access";
    Check-Valid-Until "0";

    ForceIPv4 "1";

    http
    {
        Timeout "120";
        Pipeline-Depth "${PIPELINE_DEPTH}";

        No-cache "0";
        Max-Age "86400";
        No-store "0";
    };

    Languages "none";

    GzipIndexes "1";
    CompressionTypes
    {
        Order
        {
            "gz";
        };
    };
};
EOF

chown root: /etc/apt/apt.conf.d/99apt-acquire
chmod 644 /etc/apt/apt.conf.d/99apt-acquire

cat <<'EOF' > /etc/apt/apt.conf.d/99apt-get
APT
{
    Install-Suggests "0";
    Install-Recommends "0";
    Clean-Installed "0";

    AutoRemove
    {
        SuggestsImportant "0";
    };

    Get
    {
        AllowUnauthenticated "0";
    };
};
EOF

chown root: /etc/apt/apt.conf.d/99apt-get
chmod 644 /etc/apt/apt.conf.d/99apt-get

cat <<'EOF' > /etc/apt/apt.conf.d/99dpkg
DPkg
{
    Options
    {
        "--force-confdef";
        "--force-confnew";
    };
};
EOF

chown root: /etc/apt/apt.conf.d/99dpkg
chmod 644 /etc/apt/apt.conf.d/99dpkg

if [[ $UBUNTU_VERSION == '12.04' ]]; then
    apt-get -y --force-yes clean all
    rm -rf /var/lib/apt/lists
fi

# Ubuntu (up to) 12.04 require a third-party repository
# to install latest version of the OpenSSH Server.
if [[ $UBUNTU_VERSION == '12.04' ]]; then
    cat << 'EOF' > /etc/apt/sources.list.d/precise-backports.list
deb http://ppa.launchpad.net/natecarlson/precisebackports/ubuntu precise main
deb-src http://ppa.launchpad.net/natecarlson/precisebackports/ubuntu precise main
EOF

    # Fetch Nate Carlson's PPA key from the key server.
    if [[ ! -f ${COMMON_FILES}/precise-backports.key ]]; then
        apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 3DD9F856
    fi

    apt-key add ${COMMON_FILES}/precise-backports.key
fi

# By default, the "cloud-init" will override the default mirror when run as
# Amazon EC2 instance, thus we replace this file only when building Vagrant
# boxes.
if [[ $AMAZON_EC2 == 'no' ]]; then
    # Render template overriding default list.
    eval "echo \"$(cat /var/tmp/vagrant/sources.list.template)\"" \
        > /etc/apt/sources.list

    chown root: /etc/apt/sources.list
    chmod 644 /etc/apt/sources.list

    rm -f /var/tmp/vagrant/sources.list.template
else
    # Allow some grace time for the "cloud-init" to finish
    # and to override the default package mirror.
    for n in {1..30}; do
        echo "Waiting for cloud-init to finish ..."

        if test -f /var/lib/cloud/instance/boot-finished; then
            break
        else
            # Wait a little longer every time.
            sleep $(( 1 * $n ))
        fi
    done
fi

# Update everything.
apt-get -y --force-yes update

export UCF_FORCE_CONFFNEW=1
ucf --purge /boot/grub/menu.lst

apt-get -y --force-yes dist-upgrade

if [[ $UBUNTU_VERSION == '12.04' ]]; then
    apt-get -y --force-yes install libreadline-dev dpkg
fi

UBUNTU_BACKPORT='wily'
if [[ $UBUNTU_VERSION == '12.04' ]]; then
    UBUNTU_BACKPORT='trusty'
fi

# Upgrade to latest available back-ported Kernel version.
for package in '' 'image' 'headers'; do
    PACKAGE_NAME=$(echo \
            "linux-${package}-generic-lts-${UBUNTU_BACKPORT}" | \
                sed -e 's/\-\+/\-/')

    apt-get -y --force-yes install $PACKAGE_NAME
done

apt-get -y --force-yes install linux-headers-$(uname -r)

cat <<'EOF' > /etc/timezone
Etc/UTC
EOF

chown root: /etc/timezone
chmod 644 /etc/timezone

dpkg-reconfigure tzdata

# This package is needed to suppprt English localisation correctly.
apt-get -y --force-yes install language-pack-en 1> /dev/null

# Remove current version ...
rm -f /usr/lib/locale/locale-archive

cat <<'EOF' > /var/lib/locales/supported.d/en
en_US UTF-8
en_US.UTF-8 UTF-8
en_US.Latin1 ISO-8859-1
en_US.Latin9 ISO-8859-15
en_US.ISO-8859-1 ISO-8859-1
en_US.ISO-8859-15 ISO-8859-15
EOF

cat <<'EOF' > /var/lib/locales/supported.d/local
en_US.UTF-8 UTF-8
EOF

chown root: /var/lib/locales/supported.d/{en,local}
chmod 644 /var/lib/locales/supported.d/{en,local}

locale-gen en_US.UTF-8

update-locale \
    LANG="en_US.UTF-8" \
    LC_ALL="en_US.UTF-8" \
    LANGUAGE="en_US.UTF-8:en_US:en"

dpkg-reconfigure locales

rm -f /etc/resolvconf/resolv.conf.d/head
touch /etc/resolvconf/resolv.conf.d/head

chown root: /etc/resolvconf/resolv.conf.d/head
chmod 644 /etc/resolvconf/resolv.conf.d/head

NAME_SERVERS=( 8.8.8.8 8.8.4.4 )
if [[ $AMAZON_EC2 == 'yes' ]]; then
    NAME_SERVERS=()
fi

if [[ $PACKER_BUILDER_TYPE =~ ^vmware.*$ ]]; then
    NAME_SERVERS+=( $(route -n | \
        grep -E 'UG[ \t]' | \
            awk '{ print $2 }') )
fi

cat <<EOF | sed -e '/^$/d' > /etc/resolvconf/resolv.conf.d/tail
$(for server in "${NAME_SERVERS[@]}"; do
    echo "nameserver $server"
done)
options timeout:2 attempts:1 rotate single-request-reopen
EOF

chown root: /etc/resolvconf/resolv.conf.d/tail
chmod 644 /etc/resolvconf/resolv.conf.d/tail

resolvconf -u

apt-get -y --force-yes install libnss-myhostname

cat <<'EOF' > /etc/nsswitch.conf
passwd:         compat
group:          compat
shadow:         compat

hosts:          files myhostname dns
networks:       files

protocols:      files db
services:       files db
ethers:         files db
rpc:            files db

netgroup:       nis
EOF

chown root: /etc/nsswitch.conf
chmod 644 /etc/nsswitch.conf

update-ca-certificates -v

if [[ $AMAZON_EC2 == 'yes' ]]; then
    # The cloud-init package available on Ubuntu 12.04 is too old,
    # and would fail with "None" being a data source.
    DATA_SOURCES=( NoCloud Ec2 None )
    if [[ $UBUNTU_VERSION == '12.04' ]]; then
        DATA_SOURCES=( NoCloud Ec2 )
    fi

    cat <<EOF > /etc/cloud/cloud.cfg.d/90_overrides.cfg
datasource_list: [ $(IFS=',' ; echo "${DATA_SOURCES[*]}" | sed -e 's/,/, /g') ]
EOF

    dpkg-reconfigure cloud-init
fi

if dpkg -s ntpdate &>/dev/null; then
    # The patch that fixes the race condition between the nptdate
    # and ntpd which occurs during the system startup (more precisely
    # when the network interface goes up and the helper script at
    # "/etc/network/if-up.d/ntpdate" runs).
    PATCH_FILE='ntpdate-if_up_d.patch'

    pushd /etc/network/if-up.d &>/dev/null

    for option in '--dry-run -s -i' '-i'; do
        # Note: This is expected to fail to apply cleanly on a sufficiently
        # up-to-date version the ntpdate package.
        if ! patch -l -t -p0 $option ${COMMON_FILES}/${PATCH_FILE}; then
            break
        fi
    done

    popd &> /dev/null
fi

if [[ -d /etc/dhcp ]]; then
    ln -sf /etc/dhcp /etc/dhcp3
fi

# Make sure that /srv exists.
[[ -d /srv ]] || mkdir -p /srv
chown root: /srv
chmod 755 /srv

if [[ $AMAZON_EC2 == 'yes' ]]; then
    # Disable Xen framebuffer driver causing 30 seconds boot delay.
cat <<'EOF' > /etc/modprobe.d/blacklist-xen.conf
blacklist xen_fbfront
EOF

    chown root: /etc/modprobe.d/blacklist-xen.conf
    chmod 644 /etc/modprobe.d/blacklist-xen.conf
fi

cat <<'EOF' > /etc/modprobe.d/blacklist-legacy.conf
blacklist floppy
blacklist joydev
blacklist lp
blacklist ppdev
blacklist parport
blacklist psmouse
blacklist serio_raw
EOF

chown root: /etc/modprobe.d/blacklist-legacy.conf
chmod 644 /etc/modprobe.d/blacklist-legacy.conf

# Prevent the lp and rtc modules from being loaded.
sed -i -e \
    '/^lp/d;/^rtc/d' \
    /etc/modules

for package in procps sysfsutils; do
    apt-get -y --force-yes install $package
done

for directory in /etc/sysctl.d /etc/sysfs.d; do
    if [[ ! -d $directory ]]; then
        mkdir -p $directory
        chown root: $directory
        chmod 755 $directory
    fi
done

find /etc/sysctl.d/*.conf -type f | \
    xargs sed -i -e '/^#.*/d;/^$/d;s/\(\w\+\)=\(\w\+\)/\1 = \2/'

cat <<'EOF' > /etc/sysctl.conf
#
# /etc/sysctl.conf - Configuration file for setting system variables
# See /etc/sysctl.d/ for additional system variables.
# See sysctl.conf (5) for information.
#
EOF

# Disabled for now, as hese values are too aggressive to consider these a safe defaults:
#   vm.overcommit_ratio = 80 (default: 50)
#   vm.overcommit_memory = 2 (default: 0)
cat <<'EOF' > /etc/sysctl.d/10-virtual-memory.conf
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 80
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 12000
EOF

cat <<'EOF' > /etc/sysctl.d/10-network.conf
net.core.default_qdisc = fq_codel
net.core.somaxconn = 1024
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 8192
net.ipv4.tcp_wmem = 4096 12582912 16777216
net.ipv4.tcp_rmem = 4096 12582912 16777216
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_early_retrans = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.ip_local_port_range = 1024 65535
EOF

cat <<'EOF' > /etc/sysctl.d/10-network-security.conf
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_max_syn_backlog = 256
net.ipv4.tcp_max_tw_buckets = 131072
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.secure_redirects = 1
net.ipv4.conf.default.secure_redirects = 1
EOF

cat <<'EOF' > /etc/sysctl.d/10-magic-sysrq.conf
kernel.sysrq = 0
EOF

cat <<'EOF' > /etc/sysctl.d/10-kernel-security.conf
fs.suid_dumpable = 0
net.core.bpf_jit_enable = 0
kernel.maps_protect = 1
kernel.core_uses_pid = 1
kernel.kptr_restrict = 1
kernel.dmesg_restrict = 1
kernel.randomize_va_space = 2
kernel.perf_event_paranoid = 2
kernel.yama.ptrace_scope = 1
EOF

cat <<'EOF' > /etc/sysctl.d/10-link-restrictions.conf
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
EOF

cat <<'EOF' > /etc/sysctl.d/10-kernel-panic.conf
kernel.panic = 60
EOF

cat <<'EOF' > /etc/sysctl.d/10-console-messages.conf
kernel.printk = 4 4 1 7
kernel.printk_ratelimit = 5
kernel.printk_ratelimit_burst = 10
EOF

cat <<'EOF' > /etc/sysctl.d/10-kernel-limits.conf
fs.file-max = 262144
kernel.pid_max = 65535
EOF

chown -R root: /etc/sysctl.conf \
               /etc/sysctl.d

chmod -R 644 /etc/sysctl.conf \
             /etc/sysctl.d

service procps start

cat <<'EOF' > /etc/sysfs.d/clock_source.conf
devices/system/clocksource/clocksource0/current_clocksource = tsc
EOF

# Adjust the queue size (for a moderate load on the node)
# accordingly when using Receive Packet Steering (RPS)
# functionality (setting the "rps_flow_cnt" accordingly).
for nic in $(ls -1 /sys/class/net | grep -E 'eth*' 2>/dev/null | sort); do
    cat <<EOF > /etc/sysfs.d/network.conf
class/net/${nic}/tx_queue_len = 5000
class/net/${nic}/queues/rx-0/rps_cpus = f
class/net/${nic}/queues/tx-0/xps_cpus = f
class/net/${nic}/queues/rx-0/rps_flow_cnt = 32768
EOF
done

for block in $(ls -1 /sys/block | grep -E '(sd|xvd|dm).*' 2>/dev/null | sort); do
    SCHEDULER="block/${block}/queue/scheduler = noop"
    if [[ $block =~ ^dm.*$ ]]; then
        SCHEDULER=''
    fi

    cat <<EOF | sed -e '/^$/d' > /etc/sysfs.d/disk.conf
block/${block}/queue/add_random = 0
block/${block}/queue/rq_affinity = 2
block/${block}/queue/read_ahead_kb = 256
block/${block}/queue/nr_requests = 256
block/${block}/queue/rotational = 0
${SCHEDULER}
EOF
done

cat <<'EOF' > /etc/sysfs.d/transparent_hugepage.conf
kernel/mm/transparent_hugepage/enabled = never
kernel/mm/transparent_hugepage/defrag = never
EOF

chown -R root: /etc/sysfs.conf \
               /etc/sysfs.d

chmod -R 644 /etc/sysfs.conf \
             /etc/sysfs.d

service sysfsutils restart

# The "/dev/shm" is going to be a symbolic link to "/run/shm" on
# both the Ubuntu 12.04 and 14.04, and most likely onwards.
cat <<EOS | sed -e 's/\s\+/\t/g' >> /etc/fstab
none /run/shm tmpfs rw,nosuid,nodev,noexec,relatime 0 0
EOS

chown root: /etc/fstab
chmod 644 /etc/fstab

# Remove support for logging to xconsole.
for option in '/.*\/dev\/xconsole/,$d' '$d'; do
    sed -i -e $option \
        /etc/rsyslog.d/50-default.conf
done

chown root: /etc/rsyslog.d/50-default.conf
chmod 644 /etc/rsyslog.d/50-default.conf