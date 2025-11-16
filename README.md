# PVE-template-maker

基于 Proxmox VE 的一组辅助脚本，用于快速创建云模板、普通虚拟机，并同步 VM/LXC 的局域网 IP 到 tags。

目前推荐使用的主脚本是：

- `pve-unified.sh`：一体化脚本，集成了镜像下载缓存、模板创建、虚拟机创建（自动写 IP 标签）和缓存清理功能。

下文主要说明 `pve-unified.sh` 的用法和逻辑。

---

## 1. `pve-unified.sh` 功能概览

- 从预置镜像源下载 KVM 云镜像（支持 Debian / Ubuntu / CentOS 等）。
- 使用本地缓存目录避免重复下载，支持断点续传。
- 交互式选择发行版、VMID、网桥和存储。
- 支持两种创建模式：
  - 创建云模板（不启动、不写 IP）。
  - 创建普通虚拟机（启动后通过 QEMU Guest Agent 获取 IP 写入 tags）。
- 支持批量扫描现有 QEMU VM 和 LXC 容器，把局域网 IP 写入各自 tags。
- 提供一键清理本地缓存镜像的菜单项。

> 说明：脚本假定在 Proxmox VE 节点上以 root 运行，并且已安装 `qm`、`pct`、`wget`、`ip` 等命令。

---

## 2. 镜像源与发行版配置

脚本顶部定义了镜像基础 URL 和缓存目录：

- 基础镜像源：

  ```bash
  MIRROR_BASE="https://cdn.spiritlhl.net/github.com/oneclickvirt/pve_kvm_images/releases/download/"
  CACHE_DIR="/var/cache/pve-unified-images"
  ```

- 预置发行版表 `DISTROS`（菜单中的选项）：

  ```bash
  # key: 序号; value: "名称|子路径|文件名"
  DISTROS[1]="Debian-11|debian|debian11.qcow2"
  DISTROS[2]="Debian-12|debian|debian12.qcow2"
  DISTROS[3]="Debian-13|debian|debian13.qcow2"
  DISTROS[4]="Ubuntu-18.04|ubuntu|ubuntu1804.qcow2"
  DISTROS[5]="Ubuntu-20.04|ubuntu|ubuntu2004.qcow2"
  DISTROS[6]="Ubuntu-22.04|ubuntu|ubuntu2204.qcow2"
  DISTROS[7]="Ubuntu-24.04|ubuntu|ubuntu2404.qcow2"
  DISTROS[8]="CentOS-8|centos|centos8.qcow2"
  DISTROS[9]="CentOS-9|centos|centos9.qcow2"
  ```

完整下载 URL 由 `MIRROR_BASE + 子路径/文件名` 组成，例如：

- Debian 13：`https://cdn.spiritlhl.net/.../debian/debian13.qcow2`
- Ubuntu 22.04：`https://cdn.spiritlhl.net/.../ubuntu/ubuntu2204.qcow2`

如需增加或修改镜像，只需要在 `DISTROS[...]` 中按相同格式添加/调整条目即可。

---

## 3. 下载与缓存逻辑

核心函数：`download_image(rel_path)`

流程：

1. 根据 `rel_path`（例如 `debian/debian13.qcow2`）提取文件名 `debian13.qcow2`。
2. 检查缓存目录：
   - 如果 `/var/cache/pve-unified-images/debian13.qcow2` 存在且非空：
     - 日志输出“命中缓存”，直接复制到临时目录 `TEMP_DIR` 使用。
   - 否则：
     - 拼接远程 URL：`$MIRROR_BASE$rel_path`。
     - 使用 `wget -c -O TEMP_DIR/file` 下载（支持断点续传）。
     - 下载成功后复制一份到缓存目录，供下次复用。

这样同一节点上重复创建相同发行版的模板/虚拟机时不会二次下载完整镜像。

---

## 4. 创建云模板（菜单 1）

入口函数：`create_template_single`

使用步骤：

```bash
chmod +x pve-unified.sh
./pve-unified.sh
```

在菜单中选择：`1) 创建单个云模板`

交互流程：

1. 展示发行版菜单（来自 `DISTROS`），选择 1–9 对应的系统镜像。
2. 输入 VMID（例如 8000）。
3. 输入网络桥接（默认 `vmbr0`）。
4. 输入存储名称（默认 `local`）。
5. 如该 VMID 已存在，会提示是否销毁原有 VM。

模板创建逻辑：

1. 调用 `download_image` 下载或命中缓存镜像。
2. 使用统一配置创建 VM：
   - `cpu=host`，`--cores 2`，`--memory 2048`。
   - `--scsihw virtio-scsi-pci`。
   - 开启 QEMU Guest Agent：`--agent 1`。
   - 网络：`--net0 virtio,bridge=<你的桥接>`。
3. 导入磁盘并调整：
   - `qm importdisk VMID 镜像 存储 --format qcow2`。
   - 将导入的磁盘挂载到 `scsi0`，并 `qm resize scsi0 20G`。
4. 配置 cloud-init 和网络：
   - 挂载 cloud-init 盘：`--ide2 <存储>:cloudinit`。
   - 设置 `ipconfig0`：`ip=dhcp,ip6=dhcp`（双栈 DHCP）。
5. 设置启动顺序和终端：
   - `--boot c --bootdisk scsi0`，`--serial0 socket --vga serial0`。
6. 写入镜像说明到描述：
   - `qm set VMID --description "$NOTES_TEXT"`。
7. 将 VM 转换为模板：`qm template VMID`。

特性：

- 不启动虚拟机，不获取 IP，不写入 tags。
- 模板自身的“描述(Description)”字段内包含一段 Markdown 说明，记录默认账号密码与安全提示。

---

## 5. 创建虚拟机并写入 IP 标签（菜单 2）

入口函数：`create_vm_single`

在主菜单选择：`2) 创建单个虚拟机`

交互流程与模板创建一致：

- 选择发行版 → 输入 VMID → 输入网桥和存储 → 如有同 VMID 的 VM 可选择销毁重建。

虚拟机创建逻辑与模板几乎相同，只在最后行为不同：

1. 创建 VM（同模板配置：`cpu=host`、2 核、2048MB、20G 磁盘、cloud-init 双栈 DHCP）。
2. 写入描述字段 `--description "$NOTES_TEXT"`。
3. 启动虚拟机：`qm start VMID`。
4. 调用 `wait_and_set_ip_tag` 等待 IP：
   - 每 5 秒使用 `qm guest cmd VMID network-get-interfaces` 读取网卡信息。
   - 使用正则匹配 `10.x.x.x` 网段的 IPv4 地址。
   - 一旦获取到 IP：执行 `qm set VMID --tags "$IP"`，将 IP 写入 VM 的 tags。
   - 最多等待 180 秒，超时会给出警告但不会停止 VM。

前提条件：

- 虚拟机内需已安装并运行 `qemu-guest-agent`，且网络通过 DHCP 获取 IP。

---

## 6. 批量更新 VM/LXC 的 IP 标签（菜单 3）

入口函数：`update_ip_tags`

在主菜单选择：`3) 扫描并将局域网 IP 写入 VM/LXC tags`

行为：

1. 遍历所有 QEMU 虚拟机：
   - `qm list` 获取所有 VMID。
   - 对每个 VMID 调用 `qm guest cmd VMID network-get-interfaces`。
   - 匹配 `10.x.x.x` 的 IPv4 地址。
   - 若获取到 IP，则 `qm set VMID --tags "$IP"`。
2. 遍历所有 LXC 容器：
   - `pct list` 获取 CTID。
   - 对每个 CT 调用 `pct exec CTID -- ip -4 addr show`，匹配 `10.x.x.x`。
   - 获取到 IP 后：`pct set CTID --tags "$IP"`。

适用场景：

- 已存在大量 VM/LXC，希望快速在 Proxmox WebUI 中通过 tags 显示其局域网 IP。

---

## 7. 清理镜像缓存（菜单 4）

入口函数：`clear_cache`

在主菜单选择：`4) 清除已缓存的镜像文件`

行为：

- 检查缓存目录 `CACHE_DIR`（默认 `/var/cache/pve-unified-images`）。
- 若存在，则删除目录下所有镜像文件（不删除目录本身）。
- 若不存在，输出“缓存目录不存在，无需清理”。

使用场景：

- 镜像更新后希望重新下载最新版本。
- 磁盘空间紧张，需要释放缓存占用。

---

## 8. 备注（Description）内容说明

脚本中定义的 `NOTES_TEXT` 会写入模板和虚拟机的 `description` 字段，内容为 Markdown：

- 已预安装组件：`wget`、`curl`、`openssh-server`、`sshpass`、`sudo`、`cron(cronie)`、`qemu-guest-agent`。
- 已安装并启用 `cloud-init`，开启 SSH 登录，监听 IPv4/IPv6 的 22 端口，并允许密码登录。
- 默认允许 root 账户 SSH 登录。
- 默认账号：`root / oneclickvirt`。
- 强调在生产或公网环境使用时，务必首次登录后立即修改 root 密码以降低安全风险。

你可以直接修改 `pve-unified.sh` 顶部的 `NOTES_TEXT` 内容，以自定义描述信息。

---

## 9. 快速开始

在 Proxmox 节点上：

```
bash <(curl -fsSL https://raw.githubusercontent.com/xonec/PVE-template-maker/refs/heads/main/pve-unified.sh)

bash <(wget -qO- https://raw.githubusercontent.com/xonec/PVE-template-maker/refs/heads/main/pve-unified.sh)
```

然后根据菜单提示：

- 选择 1：创建云模板，后续可通过模板克隆出多个 VM。
- 选择 2：直接创建并启动虚拟机，自动写入 IP 到 tags。
- 选择 3：为已有 VM/LXC 补全 IP tags。
- 选择 4：清理缓存镜像。
