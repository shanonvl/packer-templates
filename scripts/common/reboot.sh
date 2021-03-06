#!/bin/bash

#
# reboot.sh
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

# Make sure to shut the network interface down, thus close the
# connections allowing for Packer to notice and reconnect.
cat <<'EOF' > /tmp/reboot.sh
sleep 10

pgrep -f sshd | xargs kill -9

if ifconfig &>/dev/null; then
    ifconfig eth0 down
    ifconfig eth0 up
else
    ip link set eth0 down
    ip link set eth0 up
fi

reboot -f
EOF

nohup bash /tmp/reboot.sh &>/dev/null &

sleep 60
