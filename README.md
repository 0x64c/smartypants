# smartypants
Hard disk bulk SMART tester and eraser

Setup:
* Two PC's with 6 SATA ports on the same LAN
* Install required packages: (arch linux example) ```pacman -Sy smartmontools bc expect jq screen openssh core coreutils```
* Allow root logins for ssh
* Enable/start sshd
* Have at least 1920x1080 screen resolution in console on main machine (GRUB should be smart enough for that)
* Plug in a lot of drives
* Run script: ```su -c "screen -c ./screenrc-12way"```

Notes:
* There are many few edge cases due to a lack of standards of units and representation.
* Hotswapping isn't supported, but it may work for preliminary testing/pruning
* Read help.txt
* It shouldn't nuke your root drive; but if you're really concerned, edit line 24 of the bash script to exclude all mounted drives or drives listed in the fstab?
