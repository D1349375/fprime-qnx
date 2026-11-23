
# Host setup

Use Ubuntu 24.04 on a local x86-64 machine. The documented target runs used Ubuntu 24.04.5 under WSL2, QEMU with KVM, QNX SDP 8.0.6, and a QNX 8.0.0 x86-64 guest. Run the commands in Ubuntu and put the checkout on its Linux filesystem. On Windows, check that hardware virtualization is enabled and that `wsl --list --verbose` shows version `2` for Ubuntu. [Microsoft WSL install guide](https://learn.microsoft.com/en-us/windows/wsl/install) · [QNX QEMU-on-WSL codelab](https://qnx.github.io/codelabs/qsti-qemu-on-wsl/index.html)

## Linux tools and guest network

```bash
sudo apt update
sudo apt install build-essential cmake ninja-build git patch curl file pkg-config \
    python3-venv openssh-client qemu-system-x86 qemu-utils \
    libvirt-daemon-system libvirt-clients
test -r /dev/kvm && test -w /dev/kvm
```

Enable systemd in WSL if needed and follow the QNX codelab to start the libvirt `default` network and authorize the QEMU bridge helper for `virbr0`. The runners start QEMU as your user. Verify that this account can use KVM, query system libvirt and invoke the QEMU bridge helper for `virbr0`. Verify that `default` is active and that the bridge has an IPv4 address. The scripts identify each guest by its MAC address and use SSH/SCP to deploy the test programs. [WSL systemd](https://learn.microsoft.com/en-us/windows/wsl/systemd) · [QNX guest network setup](https://qnx.github.io/codelabs/qsti-qemu-on-wsl/index.html)

```bash
virsh -c qemu:///system net-list --all
ip -brief address show virbr0
```

## QNX SDK and F Prime tools

Install QNX SDP 8.0.6 with the x86-64 target libraries through QNX Software Center. The install must provide `qcc`, `q++` and `mkqnximage`. The following example uses `$HOME/qnx800` for that installation. Run the F Prime commands from the repository root after initializing the submodules. [QNX Software Center and SDP](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.quickstart/topic/about.html)

```bash
source "$HOME/qnx800/qnxsdp-env.sh"
qcc -V
git submodule update --init --recursive
python3 -m venv "$HOME/.venvs/fprime-qnx"
source "$HOME/.venvs/fprime-qnx/bin/activate"
python -m pip install -r lib/fprime/requirements.txt
command -v qcc mkqnximage fprime-util fprime-gds fprime-cli
```

Use `qcc -V` to confirm that `gcc_ntox86_64` is available. Keep the SDK, generated images, SSH keys and raw run evidence on the local test host. The [GitHub workflow](../../.github/workflows/host-checks.yml) uses an SDK-free Ubuntu runner. Follow the [reproduction guide](reproduce.md) for target runs and the additional FFN dependencies.
