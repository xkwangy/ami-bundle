#!/usr/bin/env bash

LAYER=$1
ENVIRONMENT=$2
REPOSITORY=$3
GITSHA=$4
BUNDLE=$5

REGION=$(wget -q -O - http://169.254.169.254/latest/meta-data/placement/availability-zone | sed '$s/.$//')

# Set up facter facts
mkdir -p /etc/facter/facts.d
echo "mapbox_layer=$LAYER" > /etc/facter/facts.d/mapbox_layer.txt
echo "mapbox_environment=$ENVIRONMENT" > /etc/facter/facts.d/mapbox_environment.txt
echo "mapbox_repository=$REPOSITORY" > /etc/facter/facts.d/mapbox_repository.txt
echo "mapbox_gitsha=$GITSHA" > /etc/facter/facts.d/mapbox_gitsha.txt
echo "mapbox_bundle=$BUNDLE" > /etc/facter/facts.d/mapbox_bundle.txt

# If there are less than two AMI ancestors then either the base layer is being
# bundled, or another layer is being built using the base layer.  Wait for fresh
# tags in either case.  If there are two AMI ancestors then the instance came
# online using a previously built layer, such as during autoscaling, so just use
# the existing text facts.
ANCESTORS=$(wget -q -O - http://169.254.169.254/latest/meta-data/ancestor-ami-ids | wc -l)
BUILD=
if [ "$ANCESTORS" -lt "1" ]; then
    BUILD="true"
fi

# Do the following if instance is not yet bundled
if [ -n "$BUILD" ]; then

    # TODO Could this be handled from w/in puppet on the layers that need it?
    mkdir -p /etc/mapbox

    # Fetch layer-specific machine key
    fetch_file s3://mapbox-hiera/$LAYER/machine-key -o /root/.ssh/id_rsa
    chmod 600 /root/.ssh/id_rsa

    # Fetch application repository
    mkdir -p /usr/local/src
    cd /usr/local/src
    git clone $REPOSITORY application
    cd /usr/local/src/application
    git checkout $GITSHA

    # Source the application-specific bootstrap.bash
    source /usr/local/src/application/cloudformation/bootstrap.bash
    # Set up puppet directories
    mkdir -p /etc/puppet/modules
    mkdir -p /etc/puppet/manifests

    # Install puppet modules
    if [ -n "$PUPPET_MODULES" ]; then
        OLDIFS="$IFS"
        IFS=$'\n'
        cd /etc/puppet/modules
        for entry in $PUPPET_MODULES
        do
            module=${entry%:*}
            version=${entry#*:}
            if [ "$module" = "$version" ]; then
                puppet module install $module
            else
                git clone git@github.com:mapbox/puppet-$module $module
                cd $module
                git checkout $version
                cd ..
            fi
        done
        IFS="$OLDIFS"
    fi

    # Link application-specific puppet manifests
    if [ -d /usr/local/src/application/puppet ]; then
        cp /usr/local/src/application/puppet/manifests/site.pp /etc/puppet/manifests/site.pp
        cp -r /usr/local/src/application/puppet/modules/standard/ /etc/puppet/modules/standard
    fi
fi

# Run puppet if a manifest is provided
if [ -f /etc/puppet/manifests/site.pp ]; then
    puppet apply --logdest=syslog /etc/puppet/manifests/site.pp
fi

if [ -f /usr/local/src/application/cloudformation/bootstrap.bash ]; then
    source /usr/local/src/application/cloudformation/bootstrap.bash
fi

build() {
    MESSAGE=
    # Write out AMI signing key/crt to file
    hiera ::amikey > /tmp/amikey
    hiera ::amicrt > /tmp/amicrt
    # Do not bundle if valid image already exists
    # Another check is made in create-ami.bash before uploading
    aws --region=$REGION ec2 describe-images --owners "self" |grep $LAYER-$GITSHA
    if [ $? -eq 0 ]; then
        signal SUCCESS "Requested AMI already exists in S3 bucket"
    else
        MESSAGE=$(verify)
        test $? -eq 0 || (signal FAILURE "$MESSAGE" && exit)
        # If timeout of 1200 is reached, returns exit status 1
        timeout 1200 /usr/local/bin/ami-bundle.bash \
            -r $REGION \
            -b $BUCKETPREFIX \
            -l $LAYER \
            -g $GITSHA \
            -u $USER \
            -k /tmp/amikey \
            -c /tmp/amicrt \
            -e "$EXCLUDE" \
            -i "$INCLUDE"
        if [ $? -eq 0 ]; then
            signal SUCCESS "ami-bundle.bash succeeded"
        else
            signal FAILURE "ami-bundle.bash timed out"
        fi
    fi
}

# Signal stack completion or failure to CloudFormation
function signal() {
    ENDPOINT=$(cat /tmp/buildwaithandle)
    REASON=$2
    # -k because this started to throw random certificate verification
    # errors after working fine several times beforehand.
    curl -k -X PUT -H 'Content-Type:' --data-binary \
        '{"Status":"'$1'","UniqueId":"1","Data":"","Reason":"'"$REASON"'"}' \
        $ENDPOINT
}

# Optionally bundle AMI
if [[ -n "$BUILD" && "$BUNDLE" = "true"  ]]; then
    build
else
    signal "SUCCESS"
fi
