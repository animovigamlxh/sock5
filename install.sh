#!/bin/bash

# 检查root权限
if [ "$EUID" -ne 0 ]; then
    echo "请使用root权限运行此脚本"
    echo "使用方法: sudo bash $0"
    exit 1
fi

# 检测系统类型和包管理器
if [ -f /etc/debian_version ]; then
    PM="apt"
    PM_INSTALL="apt install -y"
    PM_UPDATE="apt update"
elif [ -f /etc/alpine-release ]; then
    PM="apk"
    PM_INSTALL="apk add --no-cache"
    PM_UPDATE="apk update"
elif [ -f /etc/redhat-release ]; then
    PM="yum"
    PM_INSTALL="yum install -y"
    PM_UPDATE="yum update -y"
else
    echo "不支持的系统类型"
    exit 1
fi

echo "开始安装3proxy SOCKS5代理..."

# 安装基本依赖
echo "正在安装必要的依赖..."
$PM_UPDATE
case $PM in
    apt)
        $PM_INSTALL wget tar gcc make curl
        ;;
    apk)
        $PM_INSTALL wget tar gcc make curl musl-dev
        ;;
    yum)
        $PM_INSTALL wget tar gcc make curl
        ;;
esac

# 下载并编译3proxy
cd /tmp
wget https://github.com/z3APA3A/3proxy/archive/0.9.4.tar.gz
tar -xzf 0.9.4.tar.gz
cd 3proxy-0.9.4

# 根据系统选择正确的Makefile
case $PM in
    apt|yum)
        make -f Makefile.Linux
        ;;
    apk)
        make -f Makefile.Linux-gcc
        ;;
esac

# 创建目录并安装
mkdir -p /etc/3proxy /var/log/3proxy
cp bin/3proxy /usr/local/bin/
chmod +x /usr/local/bin/3proxy

# 创建用户和组
if ! grep -q "^nobody:" /etc/passwd; then
    case $PM in
        apt|yum)
            useradd -r -s /bin/false nobody
            ;;
        apk)
            adduser -S -D -H -h /dev/null -s /sbin/nologin nobody
            ;;
    esac
fi

if ! grep -q "^nogroup:" /etc/group; then
    case $PM in
        apt)
            groupadd nogroup
            ;;
        apk)
            addgroup -S nogroup
            ;;
        yum)
            groupadd nogroup
            ;;
    esac
fi

# 创建配置文件
cat > /etc/3proxy/3proxy.cfg << 'EOF'
# 3proxy configuration file
log /var/log/3proxy/3proxy.log D
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"
rotate 30
internal 0.0.0.0
external 0.0.0.0
auth none
socks -p1080
allow * * * 80-88,8080-8088
allow * * * 443,8443
allow * * * 1080
deny *
EOF

# 创建服务文件
cat > /etc/systemd/system/3proxy.service << 'EOF'
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
ExecReload=/bin/kill -HUP $MAINPID
KillMode=mixed
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 设置权限
chown -R nobody:nogroup /etc/3proxy /var/log/3proxy

# 配置防火墙
echo "配置防火墙规则..."
if command -v ufw >/dev/null 2>&1; then
    ufw allow 1080/tcp >/dev/null 2>&1
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=1080/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport 1080 -j ACCEPT
    case $PM in
        apt)
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
            iptables-save > /etc/iptables.rules
            ;;
        apk)
            iptables-save > /etc/iptables/rules.v4
            ;;
        yum)
            service iptables save
            ;;
    esac
fi

# 启动服务
systemctl daemon-reload
systemctl enable 3proxy
systemctl start 3proxy

# 清理安装文件
cd / && rm -rf /tmp/3proxy-0.9.4*

# 显示安装结果
echo "✓ 3proxy安装完成！"
echo "--------------------------------"
echo "代理服务器信息："
SERVER_IP=$(curl -s ipinfo.io/ip || hostname -I | awk '{print $1}')
echo "服务器IP: $SERVER_IP"
echo "端口: 1080"
echo "协议: SOCKS5"
echo "--------------------------------"
echo "测试命令："
echo "curl --socks5-hostname $SERVER_IP:1080 https://httpbin.org/ip"
echo "--------------------------------"
echo "管理命令："
echo "启动: systemctl start 3proxy"
echo "停止: systemctl stop 3proxy"
echo "重启: systemctl restart 3proxy"
echo "状态: systemctl status 3proxy"
echo "--------------------------------" 
