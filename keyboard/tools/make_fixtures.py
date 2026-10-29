# Generates diskutil-shaped fixtures (keys as produced by `diskutil info -plist`
# / `diskutil list -plist` on macOS 13-26) for the disk planner tests.
import copy, plistlib, os
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Tests", "SurfaceSetupCoreTests", "Fixtures")

def whole(id, internal, removable, bus, media, size, ssd=True, physical=True, content="GUID_partition_scheme"):
    return {"DeviceIdentifier": id, "DeviceNode": f"/dev/{id}", "WholeDisk": True, "ParentWholeDisk": id,
            "Internal": internal, "RemovableMediaOrExternalDevice": removable, "Removable": removable,
            "Ejectable": removable, "BusProtocol": bus, "MediaName": media, "TotalSize": size,
            "SolidState": ssd, "VirtualOrPhysical": "Physical" if physical else "Virtual", "Content": content}

def part(id, parent, content):
    return {"DeviceIdentifier": id, "ParentWholeDisk": parent, "WholeDisk": False, "Content": content}

def layout(id, parts):
    return {"AllDisksAndPartitions": [{"DeviceIdentifier": id, "Partitions": [{"DeviceIdentifier": p, "Content": c} for p, c in parts]}]}

def root_on(store):
    return {"DeviceIdentifier": "disk3s1s1", "MountPoint": "/", "FilesystemType": "apfs",
            "APFSContainerReference": "disk3", "APFSPhysicalStores": [{"APFSPhysicalStore": store}]}

SSD = whole("disk0", True, False, "PCI-Express", "KBG40ZPZ256G TOSHIBA MEMORY", 256060514304)
USB = whole("disk2", False, True, "USB", "SanDisk Ultra", 32010928128)
SD  = whole("disk4", True, True, "Secure Digital", "SD Card Reader", 63864569856)

def scenario(name, root, infos, lists, wholes):
    d = {"info": {"/": root, **infos}, "list": lists, "wholeDisks": wholes}
    with open(os.path.join(OUT, name + ".plist"), "wb") as f:
        plistlib.dump(d, f)

ssd_parts = [("disk0s1", "EFI"), ("disk0s2", "Apple_APFS")]
usb_parts = [("disk2s1", "EFI"), ("disk2s2", "Apple_HFS"), ("disk2s3", "Microsoft Basic Data")]

# 1. normal: booted from internal SSD, installer USB and SD card attached
scenario("normal", root_on("disk0s2"),
         {"disk0": SSD, "disk0s2": part("disk0s2", "disk0", "Apple_APFS"), "disk2": USB, "disk4": SD},
         {"disk0": layout("disk0", ssd_parts), "disk2": layout("disk2", usb_parts)},
         ["disk0", "disk2", "disk4"])

# 2. booted macOS from the USB stick: must refuse
scenario("booted_external", root_on("disk2s2"),
         {"disk0": SSD, "disk2": USB, "disk2s2": part("disk2s2", "disk2", "Apple_APFS")},
         {"disk0": layout("disk0", ssd_parts), "disk2": layout("disk2", usb_parts)},
         ["disk0", "disk2"])

# 3. a second internal physical disk: ambiguous
SSD2 = whole("disk1", True, False, "PCI-Express", "Other NVMe", 512110190592)
scenario("two_internal", root_on("disk0s2"),
         {"disk0": SSD, "disk0s2": part("disk0s2", "disk0", "Apple_APFS"), "disk1": SSD2},
         {"disk0": layout("disk0", ssd_parts)},
         ["disk0", "disk1"])

# 4. internal disk without EFI partition
scenario("no_efi", root_on("disk0s2"),
         {"disk0": SSD, "disk0s2": part("disk0s2", "disk0", "Apple_APFS")},
         {"disk0": layout("disk0", [("disk0s1", "Apple_APFS"), ("disk0s2", "Apple_APFS")])},
         ["disk0"])

# 5. APFS container spanning two physical stores (Fusion-like)
r = root_on("disk0s2"); r["APFSPhysicalStores"].append({"APFSPhysicalStore": "disk1s2"})
scenario("multi_store", r, {"disk0": SSD}, {}, ["disk0"])

# 6. dual boot with Windows: EFI shared, extra partitions; still fine
scenario("dual_boot", root_on("disk0s5"),
         {"disk0": SSD, "disk0s5": part("disk0s5", "disk0", "Apple_APFS")},
         {"disk0": layout("disk0", [("disk0s1", "EFI"), ("disk0s2", "Microsoft Reserved"),
                                    ("disk0s3", "Microsoft Basic Data"), ("disk0s4", "Windows Recovery"),
                                    ("disk0s5", "Apple_APFS")])},
         ["disk0"])

# 7. internal disk reported as virtual (e.g. running inside a VM): refuse
V = copy.deepcopy(SSD); V["VirtualOrPhysical"] = "Virtual"
scenario("virtual_disk", root_on("disk0s2"),
         {"disk0": V, "disk0s2": part("disk0s2", "disk0", "Apple_APFS")},
         {"disk0": layout("disk0", ssd_parts)}, ["disk0"])

# 8. EFI partition not first
scenario("efi_not_first", root_on("disk0s1"),
         {"disk0": SSD, "disk0s1": part("disk0s1", "disk0", "Apple_APFS")},
         {"disk0": layout("disk0", [("disk0s1", "Apple_APFS"), ("disk0s2", "EFI")])},
         ["disk0"])

# 9. renumbered disks: internal SSD is disk3, USB is disk0 (never assume disk0)
SSD3 = copy.deepcopy(SSD); SSD3["DeviceIdentifier"] = "disk3"
USB0 = copy.deepcopy(USB); USB0["DeviceIdentifier"] = "disk0"
scenario("renumbered", root_on("disk3s2"),
         {"disk3": SSD3, "disk3s2": part("disk3s2", "disk3", "Apple_APFS"), "disk0": USB0},
         {"disk3": layout("disk3", [("disk3s1", "EFI"), ("disk3s2", "Apple_APFS")]),
          "disk0": layout("disk0", [("disk0s1", "EFI"), ("disk0s2", "Apple_HFS")])},
         ["disk0", "disk3"])
print("fixtures written:", sorted(os.listdir(OUT)))
