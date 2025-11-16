#!/bin/bash

# ---------------------------
# 脚本说明：
# 遍历本地 PVE 节点所有虚拟机和容器
# QEMU虚拟机 -> 局域网 IP 写入 tags
# LXC容器 -> 局域网 IP 写入 tsgs
# 前提：QEMU虚拟机需安装并运行 qemu-guest-agent
# ---------------------------


echo "开始处理本地节点所有虚拟机和容器..."

# 获取所有 QEMU 虚拟机 ID
QMIDS=$(qm list | awk 'NR>1 {print $1}')

for VMID in $QMIDS; do
    echo "处理 QEMU 虚拟机 $VMID ..."

    # 获取虚拟机局域网IPv4地址 (10.x.x.x)
    IP=$(qm guest cmd $VMID network-get-interfaces 2>/dev/null | \
         grep -oP '"ip-address" : "\K10\.[0-9]+\.[0-9]+\.[0-9]+')

    if [ -z "$IP" ]; then
        echo "  未获取到IP (可能未安装 qemu-guest-agent 或虚拟机未运行)"
        continue
    fi

    echo "  获取到IP: $IP"

    # 写入虚拟机tags
    qm set $VMID --tags "$IP"

    echo "  已将IP写入虚拟机tags"
done

# 获取所有 LXC 容器 ID
CTIDS=$(pct list | awk 'NR>1 {print $1}')

for CTID in $CTIDS; do
    echo "处理 LXC 容器 $CTID ..."

    # 获取容器局域网IPv4地址 (10.x.x.x)
    IP=$(pct exec $CTID -- ip -4 addr show | grep -oP '(?<=inet\s)10\.[0-9]+\.[0-9]+\.[0-9]+')
    

    if [ -z "$IP" ]; then
        echo "  未获取到IP (容器未运行或网络未配置)"
        continue
    fi

    echo "  获取到IP: $IP"

    # 写入容器 tags
    pct set $CTID --tags "$IP"

    echo "  已将IP写入容器 tags标签"
done

echo "全部处理完成！"

# 定时任务命令
cron_job="0 2 * * * /bin/bash /root/test.sh >> /var/log/test.log 2>&1"

# 检查任务是否已存在
( crontab -l 2>/dev/null | grep -F "$cron_job" ) >/dev/null

if [ $? -ne 0 ]; then
    # 没有就添加
    ( crontab -l 2>/dev/null; echo "$cron_job" ) | crontab -
    echo "定时任务已添加"
else
    echo "定时任务已存在"
fi
