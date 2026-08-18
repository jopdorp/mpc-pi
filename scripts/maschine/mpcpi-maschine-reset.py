#!/usr/bin/env python3
"""Replug the Maschine in software.

After a hard kill the hub's usbfs claim can outlive the process just long
enough that the next start fails with "cannot select altsetting 1: Resource
busy". USBDEVFS_RESET is what the device's own error message means by "unplug
and replug the controller", without anyone having to reach behind the rig.
"""
import fcntl, os, re, subprocess, sys
USBDEVFS_RESET = ord('U') << 8 | 20
out = subprocess.run(["lsusb"], capture_output=True, text=True).stdout
m = re.search(r"Bus (\d+) Device (\d+): ID 17cc:", out)
if not m:
    sys.exit("Maschine not found on the bus")
path = "/dev/bus/usb/%s/%s" % (m.group(1), m.group(2))
fd = os.open(path, os.O_WRONLY)
try:
    fcntl.ioctl(fd, USBDEVFS_RESET, 0)
    print("reset", path)
finally:
    os.close(fd)
