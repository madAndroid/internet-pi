#!/usr/bin/env bash

### Fork run into background:
/home/andrew/bin/home-lab-shutdown.sh "$@" &

disown -a

echo "Disowned"

exit 0
