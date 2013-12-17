#!/usr/bin/env bash

# Name to give the AMI
NAME=$1
# AMI will be uploaded to a bucket called $PREFIX-$REGION
PREFIX=$2
# Comma separated list of files to exclude from AMI
EXCLUDE=$3
# Comma separated list of files to include on AMI
INCLUDE=$4
# Key used to sign the AMI bundle
AMIKEY=$5
# Certificate used to sign the AMI bundle
AMICRT=$6
# Path to CloudFormation wait condition handle
HANDLE=$7

REGION=$(wget -q -O - http://169.254.169.254/latest/meta-data/placement/availability-zone | sed '$s/.$//')
USER=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document|grep accountId | awk -F\" '{print $4}')

# Do not bundle if an AMI already exists.
# TODO Also check S3 because image parts are uploaded to S3 before the AMI
# is registered.
aws --region=$REGION ec2 describe-images --owners "self" |grep $NAME
if [ $? -eq 0 ]; then
    /usr/local/bin/ami-bundle-signal.bash SUCCESS "Requested AMI already exists in S3 bucket" $HANDLE
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
    /usr/local/bin/ami-bundle-signal.bash SUCCESS "ami-bundle.bash succeeded" $HANDLE
else
    if [[ -s /tmp/ami-bundle-output ]]; then
        ERROR=$(cat /tmp/ami-bundle-output)
    else
        ERROR="timed out"
    fi
    /usr/local/bin/ami-bundle/signal.bash FAILURE "ami-bundle.bash error: $ERROR" $HANDLE
fi
