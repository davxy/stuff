#!/bin/bash

file=$1
echo "Stripping date from $file"
sed -i 's/^\[[^ ]* \([A-Z]* .*]\)/[\1/g' $file
