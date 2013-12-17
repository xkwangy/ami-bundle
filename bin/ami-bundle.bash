#!/usr/bin/env bash
#
# AMI Packaging Script.
#
# Install dependencies:
#     apt-get install unzip
#     apt-get install ruby
#     apt-get install python-pip
#     pip install --upgrade boto
#
# Can be run as part of UserData in a cloudformation template. The UserData
# would need to install boto via python-pip, and retrieve This script from
# somewhere. It's a bit unclear the best way to set the config this script
# needs, it could be done via the environment or sed.
#
# EC2 which runs this will need an IAM role with something like these policies:
#
# {
#     "PolicyName": "credentials",
#     "PolicyDocument": {
#         "Statement": [{
#             "Action": [
#                 "s3:GetObject",
#                 "s3:ListBucket"
#             ],
#             "Effect": "Allow",
#             "Resource": [
#                 "arn:aws:s3:::<bucket-with-creds>",
#                 "arn:aws:s3:::<bucket-with-creds>/*"
#             ]
#         }]
#     }
# },
# {
#     "PolicyName": "packaging",
#     "PolicyDocument": {
#         "Statement": [ {
#             "Action": [
#                 "s3:GetBucketLocation",
#                 "s3:GetObject",
#                 "s3:PutObject",
#                 "s3:PutObjectAcl",
#                 "s3:ListBucket"
#             ],
#             "Effect": "Allow",
#             "Resource": [
#                 "arn:aws:s3:::<bucket-for-ami>",
#                 "arn:aws:s3:::<bucket-for-ami>/*"
#             ]
#         }]
#     }
# },
# {
#     "PolicyName": "registration"
#     "PolicyDocument": {
#         "Statement": [ {
#             "Action": [
#                 "ec2:RegisterImage"
#             ],
#             "Effect": "Allow",
#             "Resource": "*"
#         }]
#     }
# }

export TIME='%C ran in %E'

#
# Configuration
#

### Parse arguments
while getopts ":n:r:k:c:b:u:e:i:" opt; do
  case $opt in
    n ) AMINAME="$OPTARG" ;;
    r ) REGIONS="$OPTARG" ;;
    k ) AMIKEY="$OPTARG" ;;
    c ) AMICRT="$OPTARG" ;;
    b ) BUCKETPREFIX="$OPTARG" ;;
    u ) IAMUSER="$OPTARG" ;;
    e ) EXCLUDE="$OPTARG" ;;
    i ) INCLUDE="$OPTARG" ;;
    : )
      echo "Option -$OPTARG requires an argument." >&2
      exit 1 ;;
  esac
done

AMIDESC=$(date)
declare -A KERNELS
KERNELS=(
    [us-east-1]="aki-88aa75e1"
    [eu-west-1]="aki-71665e05"
)

#
# END CONFIGURATION
#

mkdir /tmp/aws
cd /tmp/aws
wget http://s3.amazonaws.com/ec2-downloads/ec2-ami-tools.zip
unzip ec2-ami-tools.zip
mv ec2-ami-tools-* ec2-ami-tools

export EC2_AMITOOL_HOME=/tmp/aws/ec2-ami-tools/

/usr/bin/time ./ec2-ami-tools/bin/ec2-bundle-vol \
    -k $AMIKEY \
    -c $AMICRT \
    -u $IAMUSER \
    -r x86_64 \
    -e $EXCLUDE \
    -i $INCLUDE

# It looks like ami tools will support auto detecting these in the future.
ROLE=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/)
CREDS=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE)
KEY=$(echo $CREDS | sed -E 's/^.*"AccessKeyId" : "([^"]+)".*$/\1/')
SECRET=$(echo $CREDS | sed -E 's/^.*"SecretAccessKey" : "([^"]+)".*$/\1/')
TOKEN=$(echo $CREDS | sed -E 's/^.*"Token" : "([^"]+)".*$/\1/')

# TODO run in paralell
for REGION in ${REGIONS//,/ }
do

  ./ec2-ami-tools/bin/ec2-migrate-manifest \
      -k $AMIKEY \
      -c $AMICRT \
      -m /tmp/image.manifest.xml \
      --region $REGION \
      --no-mapping \
      --kernel ${KERNELS[$REGION]}

    TARGETBUCKET="$BUCKETPREFIX-$REGION"
    aws --region=$REGIONS ec2 describe-images --owners "self" |grep $AMINAME
    if [ $? -eq 0 ]; then
        echo "Image already exists"
        exit 0
    else
        /usr/bin/time ./ec2-ami-tools/bin/ec2-upload-bundle \
            --batch \
            -m /tmp/image.manifest.xml \
            -b $TARGETBUCKET/images/$AMINAME \
            -a $KEY \
            -s $SECRET \
            -t $TOKEN

        cat > register-ami.py <<EOF
import boto.ec2
c = boto.ec2.connect_to_region("$REGION")
i = c.register_image("$AMINAME", "$AMIDESC", "$TARGETBUCKET/images/$AMINAME/image.manifest.xml")
print i
EOF
      python register-ami.py
    fi
done
