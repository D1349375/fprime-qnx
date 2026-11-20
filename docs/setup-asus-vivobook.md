# ASUS VivoBook X409JP setup · 環境建置

This guide sets up the W1 development environment for an Intel Core i5-1035G1 laptop with 8 GB RAM and Windows 11 Home. Ubuntu 24.04 runs under WSL2. QEMU uses KVM to boot a headless x86-64 QNX 8.0 image. The project was validated with QNX SDP 8.0.6.

這台機器的 C 槽是 SSD，規劃開始時約有 18 GB 可用。D 槽是 HDD，規劃開始時約有 774 GB 可用。先把 Ubuntu 的虛擬磁碟放 D 槽，程式碼、SDK 和映像都放在 Ubuntu 的 Linux 檔案系統。實際剩餘空間以本機查詢為準。MX330 可用於後續主機端實驗，本指南的編譯及 QNX 測試使用 CPU。

**Status · 狀態**. These instructions have been checked against the linked vendor documentation. The ASUS KVM, QNX boot and cross-build results are pending a run on that laptop.

## E1. Install WSL2 and Ubuntu · 安裝到 D 槽

In Task Manager, check **Performance → CPU → Virtualization**. Enable Intel virtualization in UEFI if the setting is disabled. Windows 11 Home supports WSL2. Check the OS build and disk space before installing.

```powershell
(Get-CimInstance Win32_OperatingSystem).BuildNumber
Get-PSDrive -Name C,D
wsl --list --verbose
wsl --version
```

If WSL components are missing, run `wsl --install --no-distribution` in an administrator PowerShell and reboot when Windows requests it. After reboot, run `wsl --update` and `wsl --list --online`. Use a version of WSL whose `wsl --help` lists `--location` for installation. If the old client cannot see `Ubuntu-24.04`, update WSL before installing the named distribution.

If Ubuntu 24.04 is already registered, use it and verify that its version column is `2`. To install a new copy on D:

```powershell
New-Item -ItemType Directory -Path 'D:\WSL' -Force | Out-Null
wsl --install -d Ubuntu-24.04 --location 'D:\WSL\Ubuntu-24.04' --no-launch
wsl -d Ubuntu-24.04
```

Set the Linux username and password at its first launch. Exit Ubuntu after initialization and confirm `wsl --list --verbose` reports version `2`. Run `wsl --set-version Ubuntu-24.04 2` only if an existing installation shows version `1`.

For the 8 GB host, merge these values into the `[wsl2]` section in `%UserProfile%\.wslconfig`. Start with a 4 GB WSL cap and a 2 GiB disk-backed swap area. Save work in other WSL sessions before running `wsl --shutdown`, then reopen Ubuntu for the settings to take effect.

```ini
[wsl2]
memory=4GB
processors=4
swap=2GB
swapFile=D:\\WSL\\wsl-swap.vhdx
nestedVirtualization=true
```

Ubuntu installed on D keeps its own ext4 filesystem inside the VHDX. Keep Linux build trees under `~/src`, including when the VHDX is on D. Disk I/O on the HDD can still limit build speed.

[Microsoft WSL commands](https://learn.microsoft.com/en-us/windows/wsl/basic-commands) · [WSL configuration](https://learn.microsoft.com/en-us/windows/wsl/wsl-config) · [WSL filesystem performance](https://learn.microsoft.com/en-us/windows/dev-environment/wsl-interop#performance-considerations)

## E2. Check KVM · 驗證巢狀虛擬化

Install the Ubuntu host tools and clone the project documentation into the Linux filesystem.

```bash
sudo apt update
sudo apt install build-essential cmake curl file git pkg-config \
  python3-pip python3-venv qemu-system-x86 qemu-utils
mkdir -p "$HOME/src"
git clone https://github.com/D1349375/fprime-qnx.git "$HOME/src/fprime-qnx"
```

Check the VMX flag, the kernel device, and your access to it. If `/dev/kvm` exists with group `kvm` and the current user lacks access, run `sudo usermod -aG kvm "$USER"`, then start a shell in that group with `newgrp kvm` and recheck.

```bash
uname -r
grep -m 1 -wo vmx /proc/cpuinfo
ls -l /dev/kvm
test -c /dev/kvm && test -r /dev/kvm && test -w /dev/kvm
```

Run QEMU in a paused state with KVM explicitly selected. At the QEMU monitor, type `info kvm`, expect `kvm support: enabled`, then type `quit`.

```bash
qemu-system-x86_64 -accel kvm -cpu host -smp 1 -m 128M \
  -nodefaults -display none -monitor stdio -S
```

若少了 `vmx` 或 `/dev/kvm`，先檢查 Windows 的虛擬化狀態、WSL 版本和 `nestedVirtualization=true`。若 KVM 初始化仍失敗，將錯誤和 Windows／WSL／Linux 版本記入 W1 紀錄。軟體模擬可以做功能開機測試，時序數據須記下實際加速模式。

[QNX WSL and QEMU codelab](https://qnx.github.io/codelabs/qsti-qemu-on-wsl/index.html) · [Microsoft WSL FAQ](https://learn.microsoft.com/en-us/windows/wsl/faq#is-wsl-2-available-on-windows-10-home-and-windows-11-home)

## E3. Install QNX SDP · 安裝 Linux 工具鏈

1. Obtain the non-commercial QNX SDP 8.0 license through myQNX and follow the official license activation steps.
2. Install the **Linux-host** QNX Software Center inside Ubuntu. Use it to install the **QNX SDP 8.0.6** toolchain with x86-64 target support. Record the installed build alongside your validation results.
3. Open Bash and source the SDK environment file. Adjust `$HOME/qnx800` if the SDK was installed in another directory. Repeat this in new Bash sessions before running QNX commands.

```bash
source "$HOME/qnx800/qnxsdp-env.sh"
command -v qcc mkqnximage
qcc -V
printenv QNX_HOST QNX_TARGET
```

Verify that `qcc -V` lists `gcc_ntox86_64`. The SDK and its license are installed locally through QNX Software Center.

[QNX Everywhere acquisition and licensing](https://www.qnx.com/getqnx) · [QNX SDK and QEMU prerequisites](https://qnx.com/developers/docs/qnxeverywhere/com.qnx.doc.target_images/topic/qsti_qemu/about.html)

## E4. Boot and test QNX · 啟動精簡映像並執行 C 測試

Run the next blocks in the same Ubuntu shell after sourcing the SDK. Build in a new scratch directory. The `data_files.smoke` snippet puts the cross-compiled executable on the guest's `/data` partition, so this test can run before setting up networking.

```bash
mkdir -p "$HOME/qnx-vms"
vm_dir=$(mktemp -d "$HOME/qnx-vms/fprime-smoke.XXXXXX")
cd "$vm_dir"
mkdir -p local/snippets
printf '%s\n' "$vm_dir"

cat > hello-qnx.c <<'EOF'
#include <stdio.h>

int main(void)
{
    puts("Hello from QNX");
    return 0;
}
EOF

qcc -Vgcc_ntox86_64 -o hello-qnx hello-qnx.c
file hello-qnx
printf '[perms=0755] hello-qnx=%s\n' "$PWD/hello-qnx" > local/snippets/data_files.smoke
mkqnximage --type=qemu --arch=x86_64 --graphics=no --build
ls -lh output/ifs.bin output/disk-qemu.vmdk
```

The `file` output should identify an x86-64 ELF with the QNX interpreter. If the SDK uses other image filenames, check the generated files and confirm the IFS and virtual disk paths before starting QEMU.

Use **2 vCPUs and 1.5 GiB** for the first boot. These options use the Intel physical-address limit from QNX's WSL codelab, with a serial console and networking disabled for this smoke test.

```bash
qemu-system-x86_64 \
  -accel kvm -cpu host,host-phys-bits-limit=39 \
  -smp 2 -m 1536M \
  -drive file=output/disk-qemu.vmdk,if=ide,id=drv0 \
  -kernel output/ifs.bin \
  -nic none -nographic -serial mon:stdio \
  -object rng-random,filename=/dev/urandom,id=rng0 \
  -device virtio-rng-pci,rng=rng0
```

At the QNX serial shell, run:

```sh
uname -a
/data/hello-qnx
```

Success is a QNX x86-64 boot and the output `Hello from QNX`. Use **Ctrl+A**, then **X** to exit QEMU. 這一步驗證 `qcc → 映像 → QNX 執行`。F Prime 本身的驗收在 E7。

[QNX mkqnximage and image snippets](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.utilities/topic/m/mkqnximage.html) · [QNX qcc targets](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.utilities/topic/q/qcc.html) · [QNX Intel QEMU options](https://qnx.github.io/codelabs/qsti-qemu-on-wsl/index.html)

## E5. Add a private network · 設定 GDS 用的私有網路

After the boot test, use the QNX codelab's libvirt bridge procedure. The WSL distribution needs systemd running for the `libvirtd` service. If `systemctl` reports it is unavailable, enable systemd in the Ubuntu WSL configuration and restart WSL before continuing.

```bash
sudo apt install libvirt-daemon-system libvirt-clients bridge-utils
sudo systemctl enable --now libvirtd
sudo virsh --connect qemu:///system net-list --all
ip addr show virbr0
```

If `default` is present but inactive, run `sudo virsh --connect qemu:///system net-start default` and recheck `virbr0`. Follow the codelab to authorize the QEMU bridge helper for `virbr0`. Preserve existing entries in `/etc/qemu/bridge.conf`.

For the networked launch, replace `-nic none` with the following QEMU options. Keep the test guest on the private virtual network.

```text
-netdev bridge,id=net0,br=virbr0 -device virtio-net-pci,netdev=net0
```

Check the guest address with `ifconfig`. Once a reference deployment and GDS exist, verify their TCP connection from the intended host and record the ports and guest IP used for the test.

[QNX bridge setup](https://qnx.github.io/codelabs/qsti-qemu-on-wsl/index.html) · [Microsoft WSL systemd setup](https://learn.microsoft.com/en-us/windows/wsl/systemd)

## E6. Prepare the QNX APK sysroot · 準備 ML 依賴

For the ML work, use a dedicated x86-64 **QNX** APK sysroot under the Ubuntu home directory. Follow QNX's cross-compile codelab to install the host APK tools, configure trusted keys and matching package repositories, and verify the sysroot with its C example. Choose package repositories compatible with the installed SDK and guest. Record the mlpack, Armadillo, ensmallen, cereal, and OpenBLAS versions before adding the ML dependency. Keep the SDK's normal `QNX_TARGET` for the SDK-only smoke test.

[QNX APK sysroot codelab](https://qnx.github.io/codelabs/apk-based-cross-compile/index.html) · [AI design notes](AI深化方向.md)

## E7. Prepare F Prime · 安裝工具並接續 Hello World

Stop QEMU before doing a full C++ build on the 8 GB host. Prepare a separate upstream checkout for reference and a Python virtual environment. Use the tag specified in the project plan. This guide prepares the official tooling from that checkout.

```bash
mkdir -p "$HOME/src" "$HOME/.venvs"
git clone --branch v4.4.2 --single-branch --recurse-submodules \
  https://github.com/nasa/fprime.git "$HOME/src/fprime-upstream"
python3 -m venv "$HOME/.venvs/fprime-qnx"
source "$HOME/.venvs/fprime-qnx/bin/activate"
python -m pip install -r "$HOME/src/fprime-upstream/requirements.txt"
fprime-util --help
```

The next implementation step is to add the F Prime QNX platform CMake file and x86-64 `qcc` toolchain file in this project, using the upstream porting guide. Once the files exist, cross-build a minimal F Prime Hello World deployment and run it in the guest. Capture the target and compiler shown by CMake, the deployment's startup or Hello World event, and the guest's `uname -a`. A native Ubuntu F Prime build can serve as a separate toolchain check.

[F Prime installation](https://fprime.jpl.nasa.gov/latest/docs/getting-started/installing-fprime/) · [F Prime porting guide](https://fprime.jpl.nasa.gov/latest/docs/how-to/integrate/porting-guide/) · [Project plan](專案規劃書.md)

## W1 handoff record · 驗收紀錄

| Check | Record on the ASUS |
| --- | --- |
| WSL2 | Windows build, `wsl --version`, Ubuntu 24.04 listed as version 2, and D-drive install location |
| KVM | `/dev/kvm` permissions and QEMU `info kvm` output |
| SDK | QNX SDP build, `qcc -V`, and x86-64 target |
| QNX smoke test | Guest `uname -a` and `Hello from QNX` under the explicitly selected accelerator |
| GDS and APK | Guest address and connectivity, sysroot and package versions when completed |
| F Prime on QNX | Cross-build result and target startup output after the platform files are available |

Append the test date and the confirmed results to the [W1 environment log](W1環境建置紀錄.md). Keep generated images, local SDK files, and license credentials on the development machine.
