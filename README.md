# XPhoenix

## Differences between X11 protocol and XPhoenix implementation
* Strings are in ISO Latin-1 encoding in the X11 protocol unless specified otherwise, however in XPhoenix all strings
are UTF-8 unless the protocol states that it's not an ISO Latin-1 string.

## Non-goals
* Supporting multiple _screens_. Multiple outputs (monitors) are going to be supported but not X11 screens.