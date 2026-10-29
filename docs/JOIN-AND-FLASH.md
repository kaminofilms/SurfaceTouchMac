# Join the parts and write the USB

You need a USB drive of **32 GB or more**. Writing the image **erases the USB drive**
(not your Surface; nothing touches the Surface until you boot from the USB and choose to install).

Download every `*.img.xz.part-???` file plus `SHA256SUMS-parts.txt`, `SHA256SUMS-xz.txt`,
`SHA256SUMS-img.txt` and the join script for your system into **one folder**.

## Windows (Rufus)

1. Double-click `join-windows.cmd`. It joins the parts into `SurfaceTouchMac-macOS….img.xz`
   and prints **OK** if the SHA-256 matches.
   (Manual alternative in Command Prompt: `copy /b name.img.xz.part-* name.img.xz`.)
2. Open **Rufus** (3.x or 4.x).
3. **Device**: pick the USB drive. Double-check the size so you don't pick another disk.
4. **Boot selection**: *Disk or ISO image* → **SELECT** → choose the `.img.xz` file.
   Rufus decompresses `.xz` on the fly. You do not need to unpack it.
5. Leave Partition scheme / Target system as Rufus sets them (they are greyed out for disk images).
6. **START**. If Rufus asks *ISO or DD mode*, choose **DD Image mode**. Confirm the erase warning.

## macOS

```sh
sh join.sh                 # joins + verifies -> .img.xz
xz -dk SurfaceTouchMac-*.img.xz
diskutil list              # find the USB, e.g. /dev/disk4 (check the size!)
diskutil unmountDisk /dev/diskN
sudo dd if=SurfaceTouchMac-*.img of=/dev/rdiskN bs=4m status=progress
```

## Android phone (Termux)

```sh
pkg install xz-utils coreutils
termux-setup-storage
cd ~/storage/downloads      # the folder with the parts
sh join.sh --unpack         # joins, verifies, decompresses and verifies the raw .img
```

The raw image is about the size of the macOS installer plus ~3 GB, so make sure the phone has room.
To write it from the phone, plug the USB drive in with a USB-C OTG adapter and use
**EtchDroid** (open source, F-Droid/Play Store): *Write raw image* → pick the `.img` → pick the USB drive.

## What's on the USB

| Partition | Content |
|---|---|
| EFI | OpenCore for the Surface Pro 7 with BigSurface (kernel multitouch) and a unique SMBIOS |
| SURFACESETUP | `SurfaceTouchMac-Setup.pkg` and `READ ME FIRST.txt` |
| Install macOS Tahoe | Apple's full offline installer (made with Apple's `createinstallmedia`) |

Then follow **READ ME FIRST.txt** on the SURFACESETUP partition (also in `docs/AFTER-INSTALL.txt`).
