#!/bin/bash
MODULES_PATH=$(ls -d ../modules/*)
for module in $MODULES_PATH
do
  git -C "$module" checkout sr-server-init
done