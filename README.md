# Ubuntu on MacBook Pro 15-inch Retina (Mid 2015)

Reproducible Intel graphics boot setup for the **MacBookPro11,5** (15-inch Retina, Mid 2015), tested on **Ubuntu 26.04**.

This project builds a custom EFI helper that selects the integrated **Intel Iris Pro 5200** through Apple's GMUX before chainloading a Linux **Unified Kernel Image (UKI)**. It provides separate **candidate**, **validated**, and historical recovery boot entries.

> **Hardware-specific and experimental.** This is not a generic Mac or Ubuntu installer. Incorrect EFI/GRUB changes can leave a machine unable to boot normally. Keep a working recovery path and a backup of your EFI System Partition (ESP). Do not change GMUX routing from a running Linux session.

## Tested configuration

- Model: Apple MacBookPro11,5, 15-inch Retina (Mid 2015)
- GPUs: Intel Iris Pro 5200 and AMD Radeon R9 M370X
- OS: Ubuntu 26.04, using dracut for the initramfs
- Tested kernel: `7.0.0-42-generic`
- Root filesystem: directly mounted ext4 partition
- Boot: GRUB → custom EFI helper → UKI → Linux

**Verified on the test machine:** Intel `i915` is active, AMD graphics drivers are not loaded, only the internal `eDP-1` display is connected without an external monitor, and suspend/resume works using ACPI S3 (`deep`). The validated slot has been installed and selected as GRUB's saved default; the original test results were obtained with the candidate slot. Results on other machines or kernel versions are not guaranteed.

## How it works

```text
GRUB
 ├─ Intel validated (saved default)
 │   └─ EFI/custom/intel-before-validated.efi
 │       └─ EFI/custom/ubuntu-intel-validated.efi
 ├─ Intel candidate (manual test)
 │   └─ EFI/custom/intel-before-candidate.efi
 │       └─ EFI/custom/ubuntu-intel-candidate.efi
 ├─ Historical Intel stable (recovery)
 └─ AMD fallback (recovery)
```

The helper performs the pre-boot Intel/GMUX setup. The UKI contains the selected kernel, matching initramfs, and kernel command line. **The helper embeds the UKI path**, so renaming or copying a helper alone does not retarget it to another UKI.

## Repository layout

| Path | Purpose |
| --- | --- |
| `upstream.commit` | Full pinned upstream Git commit |
| `patches/ubuntu-uki.patch` | Local changes applied to the upstream EFI source |
| `cmdline.txt` | Shared kernel boot parameters, **without** `root=UUID=...` |
| `install-build-deps.sh` | Install build dependencies |
| `setup.sh` | Fetch pinned upstream source, apply patch, prepare `build/source/` |
| `build.sh` | Build a candidate helper and UKI in `build/candidate/` |
| `install.sh` | Install candidate files and add a manual GRUB test entry |
| `promote.sh` | Promote the tested candidate to an independent validated slot and make it the default |
| `build/` | Generated sources, temporary files, and artifacts; not intended for version control |

The pinned upstream project is [bbatchelder/macbookpro11-5-intel-efi](https://github.com/bbatchelder/macbookpro11-5-intel-efi). The upstream commit currently used by this project is `068a36d1e632ba40838189253f77e797d7ccb61d`; `upstream.commit` is the authoritative pin.

## Prerequisites

You need an **already installed and bootable** Ubuntu system on the supported MacBook, a mounted ESP at `/boot/efi`, GRUB, and a known-good Intel boot configuration with these historical recovery files:

```text
/boot/efi/EFI/custom/intel-before-no-ghost.efi
/boot/efi/EFI/custom/ubuntu-intel-no-ghost.efi
```

**Important:** The current `install.sh` explicitly requires these files and refuses to install without them. Therefore, this repository currently documents and automates a **reproducible build and managed candidate/validated workflow for an existing working setup**, not a zero-to-one installation on a stock MacBook. A separate first-install/recovery procedure is still needed for new machines.

The current `build.sh` supports a directly mounted **ext4** root filesystem. LUKS, LVM, Btrfs subvolumes, and other root layouts are not implemented.

## Build a candidate

```bash
git clone https://github.com/ffjdm/ubuntu-mbp151.git
cd ubuntu-mbp151
sudo ./install-build-deps.sh
./setup.sh
sudo ./build.sh
```

`setup.sh` checks out the pinned upstream commit and applies the repository patch. Re-running it with unchanged inputs leaves the generated source untouched.

`build.sh` selects the newest installed kernel with matching `/boot/vmlinuz-*` and `/boot/initrd.img-*` files. You can select a specific installed kernel instead:

```bash
sudo ./build.sh 7.0.0-42-generic
```

It discovers the ext4 root filesystem UUID using `findmnt` and prepends `root=UUID=...` to the options in `cmdline.txt`. **Do not commit a machine-specific root UUID to `cmdline.txt`.**

The tested shared boot options are:

```text
ro intel_iommu=off modprobe.blacklist=amdgpu,radeon rd.driver.blacklist=amdgpu,radeon initcall_blacklist=simpledrm_platform_driver_init,efifb_driver_init
```

The build outputs are:

```text
build/candidate/intel-before-candidate.efi
build/candidate/ubuntu-intel-candidate.efi
build/candidate/.build-manifest
build/candidate/kernel-version
```

Building **does not** modify the ESP or GRUB. Re-running `build.sh` with the same inputs is idempotent. If an existing candidate differs, the script refuses to overwrite it.

## Install and test the candidate

```bash
sudo ./install.sh
```

This copies the verified candidate binaries to `/boot/efi/EFI/custom/`, creates `/etc/grub.d/41_mbp151_candidate`, and runs `update-grub`. The GRUB entry is:

```text
Ubuntu MBP 15,1 - Intel candidate (test)
```

Its identifier is `ubuntu-mbp151-intel-candidate`. **Installation does not change the default boot entry.** Select the candidate manually from GRUB for its first test. Retain access to the historical Intel and AMD recovery entries.

After a successful boot, check:

```bash
cat /proc/cmdline
lspci -k | grep -A 3 -E 'VGA|Display|3D'
ls /sys/class/drm/
cat /sys/power/mem_sleep

for status in /sys/class/drm/card0-*/status; do
    printf '%-25s %s\n' \
        "$(basename "$(dirname "$status")")" \
        "$(cat "$status")"
done
```

On the tested machine, `card0-eDP-1` was `connected`, all external connectors were `disconnected`, Intel used `i915`, and `/sys/power/mem_sleep` showed `s2idle [deep]`.

To test suspend/resume, **save your work first**, then run:

```bash
sudo systemctl suspend
```

After waking, confirm that the display and session work and inspect the kernel log:

```bash
journalctl -b -k --no-pager | grep -Ei 'PM: suspend|PM: resume|ACPI: PM'
```

The tested system reported `PM: suspend entry (deep)`, entry into S3, successful low-level resume, and `PM: suspend exit`.

## Promote a tested candidate

Only after verifying boot, display, and suspend/resume:

```bash
sudo ./promote.sh
```

Promotion:

1. Checks candidate build hashes against the installed candidate files.
2. Copies the UKI to `ubuntu-intel-validated.efi`.
3. **Rebuilds** the EFI helper so it chainloads the validated UKI rather than the candidate UKI.
4. Creates `/etc/grub.d/42_mbp151_validated`.
5. Sets `GRUB_DEFAULT=saved`, updates GRUB, and saves `ubuntu-mbp151-intel-validated` as the default.

The validated slot is deliberately protected: `promote.sh` **refuses to overwrite existing validated files if their content differs**. The historical stable Intel and AMD fallback entries remain untouched.

Verify the default:

```bash
grep '^GRUB_DEFAULT=' /etc/default/grub
sudo grub-editenv - list
```

Expected:

```text
GRUB_DEFAULT=saved
saved_entry=ubuntu-mbp151-intel-validated
```

Reboot and verify the validated entry itself before considering the promotion complete. Its helper is a separately compiled executable, so successful candidate boot alone does not prove validated boot.

## Kernel updates and rollback

A normal Ubuntu kernel package update **does not itself regenerate these custom UKIs**. The custom EFI artifacts remain at their existing paths until you explicitly rebuild and install them.

For a new kernel, the intended workflow is:

1. Keep the existing validated slot as the default.
2. Build a new candidate with `sudo ./build.sh [kernel-version]`.
3. Install it using `sudo ./install.sh`.
4. Boot the candidate manually and test Intel graphics, Retina, and S3.
5. Promote only after successful testing.

**Current limitation:** the scripts deliberately refuse to replace a different existing candidate or validated slot. This means the workflow above is **not yet a complete automated kernel-update rotation**. Before building a different kernel, explicitly archive the previous candidate artifacts and arrange a safe candidate replacement procedure. Do not delete the last working validated or historical stable files. Promoting a newer candidate over an existing validated slot likewise requires a future versioned-slot/rotation mechanism; the current `promote.sh` intentionally refuses that operation.

If a new candidate fails, select **Intel validated** or the historical Intel/AMD fallback from GRUB. Because the default points to the validated slot, a failed candidate test should not change the normal default. With a hidden GRUB menu and `GRUB_TIMEOUT=0`, accessing fallback entries may be difficult; plan a recovery method before changing boot configuration.

## Safety and troubleshooting

- **Never overwrite the historical stable EFI binaries during development.**
- Keep the ESP backed up and maintain an accessible recovery boot path.
- Do not assume `objcopy --dump-section` is read-only on its input: it can rewrite a PE/EFI file and invalidate its SHA-256 manifest. Inspect a **temporary copy**, not an installed or built candidate.
- A checksum mismatch is a reason to investigate, **not** to bypass the check.
- `setup.sh` and `build.sh` are designed to avoid ESP/GRUB writes. `install.sh` and `promote.sh` deliberately modify boot files; inspect their output before rebooting.
- `GRUB_DEFAULT=saved` uses the entry recorded by `grub-set-default`. Avoid `GRUB_SAVEDEFAULT=true` if you do not want manual selections to change the saved default.
- The UKI is built unsigned. Secure Boot compatibility is not established by this project.

## Project status

**Hardware-tested proof of concept with a reproducible build and validated first promotion.** Not yet a turnkey installation or automated kernel-update manager. Contributions and testing on other MacBookPro11,5 configurations are welcome, but please document the hardware model, Ubuntu release, kernel version, boot behavior, display state, and suspend/resume results.

## Credits

The EFI/GMUX implementation builds on [bbatchelder/macbookpro11-5-intel-efi](https://github.com/bbatchelder/macbookpro11-5-intel-efi). This repository pins an upstream revision and applies local changes for the Ubuntu UKI workflow. Consult the upstream project for its licensing and attribution requirements.
