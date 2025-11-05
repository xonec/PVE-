PVE Cloud-Init 模板一键创建脚本使用说明
 
🌟 脚本简介
 
一款高效的 Proxmox VE（PVE）云模板创建工具，支持 系统名快速创建、自定义镜像URL导入 两种核心模式，默认开启SSH公钥登录（安全优先），适配11种主流Linux发行版，支持批量/交互/精准三种使用场景，新手也能一键搞定模板部署。
 
🚀 核心特性
 
- 支持两种创建方式：内置系统名（如 Ubuntu2204 ）或自定义镜像URL
- 自动识别镜像文件名生成模板名，无需手动命名
- 公钥登录优先，默认禁用密码登录（可手动调整）
- 自动校验存储池/VMID/SSH公钥有效性，重复VMID可一键覆盖
- 镜像支持复用，避免重复下载，创建后自动转为PVE模板
 
📋 支持的内置系统
 
 Debian11 / Debian12 / CentOS8Stream / CentOS9Stream / Ubuntu2204 / Ubuntu2404 / AlmaLinux8 / AlmaLinux9 / RockyLinux8 / RockyLinux9 / Fedora39 
 
🔧 前置准备
 
1. 确保在 PVE节点本机 运行（需 qm 命令权限）
2. 切换至 root 用户（脚本需root权限操作PVE）：
bash
  

sudo -i
 
3. 安装依赖（部分PVE节点默认缺失）：
bash
  

apt update && apt install -y wget libguestfs-tools
 
4. 准备SSH公钥（默认路径 ~/.ssh/id_rsa.pub ，无则生成）：
bash
  

ssh-keygen -t rsa -b 2048 -N "" -f ~/.ssh/id_rsa
 
 
🚀 一键安装运行（推荐）
 
无需下载脚本，直接通过 wget 拉取并执行，支持三种核心用法：
 
用法1：精准模式（内置系统名，最快最常用）
 
直接指定系统名创建模板，示例：创建 Ubuntu2204 模板（VMID=8004）
 
bash
  

bash <(wget -qO- https://raw.githubusercontent.com/xonec/PVE-/refs/heads/main/create-cloud-templates.sh) local vmbr0 8004 Ubuntu2204 ~/.ssh/id_rsa.pub
 
 
用法2：精准模式（自定义镜像URL）
 
导入任意公开云镜像URL，自动生成模板名，示例：
 
bash
  

bash <(wget -qO- https://raw.githubusercontent.com/xonec/PVE-/refs/heads/main/create-cloud-templates.sh) local vmbr0 8005 https://xxx.com/custom-linux.qcow2 ~/.ssh/id_rsa.pub
 
 
用法3：交互模式（自定义参数，适合新手）
 
一键启动交互向导，按提示选择系统、配置CPU/内存/存储：
 
bash
  

bash <(wget -qO- https://raw.githubusercontent.com/xonec/PVE-/refs/heads/main/create-cloud-templates.sh)
 
 
启动后选择 2 进入交互模式，按提示完成配置即可。
 
用法4：批量模式（一键创建所有内置系统模板）
 
自动创建11种系统模板（VMID从8000开始递增）：
 
bash
  

bash <(wget -qO- https://raw.githubusercontent.com/xonec/PVE-/refs/heads/main/create-cloud-templates.sh) local vmbr0 8000 2 2048 30G root changeme
 
 
📝 参数说明（精准模式）
 
精准模式命令格式：
 
bash
  

bash <(wget -qO- 脚本链接) 存储池 网桥 VMID 系统名/镜像URL SSH公钥路径
 
 
- 存储池：默认 local （PVE默认存储池，可通过 pvesm status 查看）
- 网桥：默认 vmbr0 （PVE默认网络网桥，可在PVE控制台→网络查看）
- VMID：自定义模板ID（如8004，需未被占用，重复会提示覆盖）
- 系统名/镜像URL：内置系统名（如 Ubuntu2204 ）或公开镜像URL（需以 http(s):// 开头）
- SSH公钥路径：默认 ~/.ssh/id_rsa.pub （前置准备中生成的公钥路径）
 
✅ 模板使用方法
 
1. 脚本执行完成后，在PVE控制台→虚拟机，找到创建好的模板（名称以 Template- 开头）
2. 右键模板→克隆，选择“完整克隆”或“链接克隆”（链接克隆更省空间）
3. 克隆后启动虚拟机，通过 ssh 用户名@虚拟机IP -i 私钥路径 登录（默认用户 root ）
 
⚠️ 注意事项
 
1. 镜像URL需为公开可访问的 qcow2 / img 格式云镜像（支持Cloud-Init）
2. 若提示“存储池不存在”，请通过 pvesm status 确认实际存储池名称并替换
3. 公钥登录失败时，可修改脚本中 SSH_PWAUTH="true" 启用密码登录（默认密码 changeme ）
4. 批量模式创建的模板VMID从指定起始值递增，避免与现有VMID冲突
