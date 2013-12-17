#!/usr/bin/env bash

STATUS=$1
REASON=$2
ENDPOINT=$(cat $3)

# Signal stack completion or failure to CloudFormation
# -k because this started to throw random certificate verification
# errors after working fine several times beforehand.
curl -k -X PUT -H 'Content-Type:' --data-binary \
    '{"Status":"'$1'","UniqueId":"1","Data":"","Reason":"'"$REASON"'"}' \
    $ENDPOINT
