#!/bin/sh
set -e

rm -rf /data/0_0.tigerbeetle

# if [ ! -f /data/0_0.tigerbeetle ]
# then
	/tigerbeetle format --cluster=0 --replica=0 --replica-count=1 /data/0_0.tigerbeetle
# fi
/tigerbeetle start --addresses="[::1]:3000" /data/0_0.tigerbeetle
