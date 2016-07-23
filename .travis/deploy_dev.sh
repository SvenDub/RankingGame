#!/bin/bash
cd `dirname $0`/..

echo "Prepending (dev) to name"
sed -i '/^name:/ s/$/ (dev)/' manifest

echo "Deploying to servers"
./deploy $DEPLOYKEY_DEV