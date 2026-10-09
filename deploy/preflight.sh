#!/usr/bin/env bash
# 在 VPS 上运行，输出部署所需的环境信息。
# 只读操作，不会修改服务器上任何东西。
#
# 用法：把本文件传到服务器后 `bash preflight.sh`，把完整输出贴回来。

set -uo pipefail

echo "===== RemoteScreen 部署前环境检查 ====="
echo

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "操作系统      ${PRETTY_NAME:-未知}"
else
  echo "操作系统      未知"
fi

echo "内核架构      $(uname -m)   $(uname -r)"
echo "CPU 核数      $(nproc 2>/dev/null || echo 未知)"

if command -v free >/dev/null 2>&1; then
  echo "内存总量      $(free -h | awk '/^Mem:/{print $2}')"
fi

echo "根分区        $(df -h / | awk 'NR==2{print $2" 总 / "$4" 可用"}')"
echo

echo "Docker        $(docker --version 2>/dev/null || echo '未安装')"
echo "Compose 插件  $(docker compose version 2>/dev/null || echo '未安装')"
echo "Docker 守护   $(systemctl is-active docker 2>/dev/null || echo '未知')"
echo

echo "公网 IP       $(curl -s --max-time 8 https://ifconfig.me 2>/dev/null || echo 取不到)"
echo

echo "关键端口占用情况（列出即为已被占用）："
if command -v ss >/dev/null 2>&1; then
  occupied=$(ss -lntu 2>/dev/null | awk 'NR>1 {print $5}' | grep -oE ':(22|80|443|7880|7881|7882)$' | sort -u)
  if [ -n "$occupied" ]; then
    echo "$occupied"
  else
    echo "  以上端口均空闲"
  fi
else
  echo "  ss 命令不可用，跳过"
fi
echo

echo "主机防火墙规则（云厂商安全组需另在控制台确认）："
if command -v ufw >/dev/null 2>&1; then
  ufw status 2>/dev/null | head -20
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --list-all 2>/dev/null | head -20
else
  echo "  未检测到 ufw / firewalld"
fi
echo

echo "===== 检查结束 ====="
