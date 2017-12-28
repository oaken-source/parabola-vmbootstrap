#!/bin/bash

set -eu

# create an empty qemu image
rm -f $_outfile
qemu-img create -f raw $_outfile $SIZE
