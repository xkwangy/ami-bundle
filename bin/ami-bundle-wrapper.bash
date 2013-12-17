#!/usr/bin/env bash

# Name to give the AMI
NAME=$1
# Bucket prefix.  Region is automatically appended. If foo is the provided
# prefix then the image will be stored in foo-us-east-1 if bundling in us-east-1
PREFIX=$2
# Comma separated list of files to exclude
EXCLUDE=$3
# Comma separated list of files to include
INCLUDE=$4
AMIKEY=$5
AMICRT=$6
# Path to CloudFormation wait condition handle
HANDLE=$7

REGION=$(wget -q -O - http://169.254.169.254/latest/meta-data/placement/availability-zone | sed '$s/.$//')
USER=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document|grep accountId | awk -F\" '{print $4}')

# Signal stack completion or failure to CloudFormation
function signal() {
    if [ -n "$HANDLE" ]; then
        ENDPOINT=$(cat $HANDLE)
        REASON=$2
        # -k because this started to throw random certificate verification
        # errors after working fine several times beforehand.
        curl -k -X PUT -H 'Content-Type:' --data-binary \
            '{"Status":"'$1'","UniqueId":"1","Data":"","Reason":"'"$REASON"'"}' \
            $ENDPOINT
    else
        exit 0
    fi
}

# Do not bundle if an AMI already exists.
# TODO Also check S3 because image parts are uploaded to S3 before the AMI
# is registered.
aws --region=$REGION ec2 describe-images --owners "self" |grep $NAME
if [ $? -eq 0 ]; then
    signal SUCCESS "Requested AMI already exists in S3 bucket"
fi

timeout 1200 /usr/local/bin/ami-bundle.bash \
    -r $REGION \
    -b $PREFIX \
    -n $NAME \
    -u $USER \
    -k $AMIKEY \
    -c $AMICRT \
    -e "$EXCLUDE" \
    -i "$INCLUDE" 2> /tmp/ami-bundle-output

if [ $? -eq 0 ]; then
    signal SUCCESS "ami-bundle.bash succeeded"
else
    if [[ -s /tmp/ami-bundle-output ]]; then
        ERROR=$(cat /tmp/ami-bundle-output)
    else
        ERROR="timed out"
    fi
    signal FAILURE "ami-bundle.bash error: $ERROR"
fi
