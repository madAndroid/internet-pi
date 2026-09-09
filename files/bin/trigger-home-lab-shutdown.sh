#!/usr/bin/env bash

### Detach stdio from the SSH session - otherwise sshd keeps the channel
### open until the backgrounded script's inherited pipes close, blocking for
### the whole shutdown run instead of returning immediately.
/home/andrew/bin/home-lab-shutdown.sh "$@" < /dev/null > /dev/null 2>&1 &

disown -a

echo "Disowned"

exit 0
