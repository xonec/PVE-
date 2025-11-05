一、精准模式（公钥登录优先，推荐）
 
直接复制命令到Proxmox节点终端，替换括号内参数即可：
 
bash
  

# 示例1：Ubuntu2404 + local存储 + VMID8006
wget -qO- https://raw.githubusercontent.com/xonec/PVE-/refs/heads/main/create-cloud-templates.sh | bash -s -- local vmbr0 8006 Ubuntu2404 ~/.ssh/id_rsa.pub


 
二、批量模式（一键创建所有11种系统）
 
bash
  

# 示例1：默认配置（2核2G30G，root用户）
wget -qO- https://raw.githubusercontent.com/xonec/PVE-/refs/heads/main/create-cloud-templates.sh | bash -s -- local vmbr0 8000 2 2048 30G root StrongPwd@2024
 
 
三、交互模式（自动下载后进入手动配置）
 
bash
  

wget -qO- https://raw.githubusercontent.com/xonec/PVE-/refs/heads/main/create-cloud-templates.sh | bash
 
 
关键说明
 
1. 命令通过 wget -qO- 直接下载脚本并管道给 bash 执行，无需额外保存文件
2.  --  用于分隔 bash 参数和脚本参数，避免冲突
3. 运行前确保Proxmox节点已安装依赖： apt install -y wget libguestfs-tools （仅需执行一次）
