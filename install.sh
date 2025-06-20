#!/bin/bash

# 检测系统类型和包管理器
check_package_manager() {
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
}

# 安装基本依赖
install_dependencies() {
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
}

# 3proxy一键安装管理脚本
# 使用方法: chmod +x 3proxy_all_in_one.sh && sudo ./3proxy_all_in_one.sh

CONFIG_FILE="/etc/3proxy/3proxy.cfg"
LOG_FILE="/var/log/3proxy/3proxy.log"
SERVICE_NAME="3proxy"

# 检查是否已安装
check_installation() {
    if [ -f "/usr/local/bin/3proxy" ] && [ -f "$CONFIG_FILE" ]; then
        return 0  # 已安装
    else
        return 1  # 未安装
    fi
}

# 配置防火墙
configure_firewall() {
    echo "配置防火墙规则..."
    local port=$1
    
    # UFW (Ubuntu/Debian)
    if command -v ufw >/dev/null 2>&1; then
        ufw allow $port/tcp >/dev/null 2>&1
    # FirewallD (CentOS/RHEL)
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=$port/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    # Iptables (通用)
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport $port -j ACCEPT
        # 保存iptables规则
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
}

# 安装3proxy
install_3proxy() {
    echo "开始安装3proxy SOCKS5代理..."
    
    # 获取用户输入
    while true; do
        read -p "请输入代理端口 (1-65535): " PROXY_PORT
        if [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_PORT" -ge 1 ] && [ "$PROXY_PORT" -le 65535 ]; then
            break
        else
            echo "错误：请输入有效的端口号（1-65535）"
        fi
    done

    read -p "是否启用认证？(y/N): " AUTH_ENABLE
    if [[ "$AUTH_ENABLE" =~ ^[Yy]$ ]]; then
        while true; do
            read -p "请输入用户名: " PROXY_USER
            if [[ -n "$PROXY_USER" ]]; then
                break
            else
                echo "错误：用户名不能为空"
            fi
        done
        
        while true; do
            read -s -p "请输入密码: " PROXY_PASS
            echo
            if [[ -n "$PROXY_PASS" ]]; then
                break
            else
                echo "错误：密码不能为空"
            fi
        done
    fi
    
    # 安装依赖
    install_dependencies
    
    # 下载编译3proxy
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
    
    # 创建用户和组（如果不存在）
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
    cat > "$CONFIG_FILE" << EOF
# 3proxy configuration file
log /var/log/3proxy/3proxy.log D
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"
rotate 30
internal 0.0.0.0
external 0.0.0.0
EOF

    # 根据用户选择添加认证配置
    if [[ "$AUTH_ENABLE" =~ ^[Yy]$ ]]; then
        echo "auth strong" >> "$CONFIG_FILE"
        echo "users $PROXY_USER:CL:$PROXY_PASS" >> "$CONFIG_FILE"
    else
        echo "auth none" >> "$CONFIG_FILE"
    fi

    # 添加代理配置
    cat >> "$CONFIG_FILE" << EOF
socks -p$PROXY_PORT
allow * * * 80-88,8080-8088
allow * * * 443,8443
allow * * * $PROXY_PORT
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
    
    # 启动服务
    systemctl daemon-reload
    systemctl enable 3proxy
    systemctl start 3proxy
    
    # 配置防火墙
    configure_firewall $PROXY_PORT
    
    # 清理安装文件
    cd / && rm -rf /tmp/3proxy-0.9.4*
    
    echo "✓ 3proxy安装完成！"
    echo "=================================="
    echo "安装信息："
    echo "端口: $PROXY_PORT"
    if [[ "$AUTH_ENABLE" =~ ^[Yy]$ ]]; then
        echo "认证模式: 启用"
        echo "用户名: $PROXY_USER"
        echo "密码: $PROXY_PASS"
    else
        echo "认证模式: 关闭"
    fi
    echo "=================================="
}

# 显示状态
show_status() {
    echo "=================================="
    echo "3proxy SOCKS5代理 状态信息"
    echo "=================================="
    
    # 服务状态
    if systemctl is-active --quiet 3proxy; then
        echo "服务状态: ✓ 运行中"
    else
        echo "服务状态: ✗ 已停止"
    fi
    
    # 端口信息
    PORT=$(grep "socks -p" "$CONFIG_FILE" 2>/dev/null | sed 's/.*-p\([0-9]*\).*/\1/')
    echo "监听端口: ${PORT:-1080}"
    
    # 认证模式
    if grep -q "^auth none" "$CONFIG_FILE" 2>/dev/null; then
        echo "认证模式: 无认证"
    elif grep -q "^auth strong" "$CONFIG_FILE" 2>/dev/null; then
        echo "认证模式: 需要认证"
        echo "用户列表:"
        grep "^users " "$CONFIG_FILE" 2>/dev/null | sed 's/users \([^:]*\):.*/  - \1/'
    fi
    
    # 服务器IP
    SERVER_IP=$(curl -s ipinfo.io/ip 2>/dev/null || hostname -I | awk '{print $1}')
    echo "服务器IP: $SERVER_IP"
    
    echo ""
    echo "客户端配置:"
    echo "服务器: $SERVER_IP"
    echo "端口: ${PORT:-1080}"
    echo "协议: SOCKS5"
    
    echo ""
    echo "测试命令:"
    echo "curl --socks5-hostname $SERVER_IP:${PORT:-1080} https://httpbin.org/ip"
}

# 切换认证模式
toggle_auth() {
    if grep -q "^auth none" "$CONFIG_FILE"; then
        # 切换到认证模式
        read -p "输入用户名: " username
        read -s -p "输入密码: " password
        echo
        
        sed -i 's/^auth none/auth strong/' "$CONFIG_FILE"
        echo "users $username:CL:$password" >> "$CONFIG_FILE"
        echo "✓ 已启用认证模式，用户: $username"
    else
        # 切换到无认证模式
        sed -i 's/^auth strong/auth none/' "$CONFIG_FILE"
        sed -i '/^users /d' "$CONFIG_FILE"
        echo "✓ 已切换到无认证模式"
    fi
    
    systemctl restart 3proxy
    echo "服务已重启"
}

# 更改端口
change_port() {
    current_port=$(grep "socks -p" "$CONFIG_FILE" | sed 's/.*-p\([0-9]*\).*/\1/')
    read -p "输入新端口 (当前: $current_port): " new_port
    
    if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo "✗ 无效端口号"
        return 1
    fi
    
    sed -i "s/socks -p[0-9]*/socks -p$new_port/" "$CONFIG_FILE"
    
    # 更新防火墙
    configure_firewall $new_port
    
    systemctl restart 3proxy
    echo "✓ 端口已更改为: $new_port"
}

# 查看日志
show_logs() {
    if [ -f "$LOG_FILE" ]; then
        echo "最新日志 (最后20行):"
        echo "========================"
        tail -n 20 "$LOG_FILE"
    else
        echo "日志文件不存在"
    fi
}

# 测试连接
test_proxy() {
    PORT=$(grep "socks -p" "$CONFIG_FILE" | sed 's/.*-p\([0-9]*\).*/\1/')
    echo "测试代理连接..."
    
    result=$(curl --socks5-hostname 127.0.0.1:${PORT:-1080} --connect-timeout 10 -s https://httpbin.org/ip 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo "✓ 代理连接正常"
        echo "代理IP: $(echo $result | grep -o '"origin":"[^"]*' | cut -d'"' -f4)"
    else
        echo "✗ 代理连接失败"
    fi
}

# 卸载
uninstall_3proxy() {
    read -p "确定要卸载3proxy吗? (y/N): " confirm
    if [[ $confirm == [yY] ]]; then
        systemctl stop 3proxy 2>/dev/null
        systemctl disable 3proxy 2>/dev/null
        rm -f /etc/systemd/system/3proxy.service
        rm -rf /etc/3proxy
        rm -f /usr/local/bin/3proxy
        systemctl daemon-reload
        echo "✓ 3proxy已完全卸载"
    fi
}

# 主菜单
show_menu() {
    clear
    echo "=================================="
    echo "    3proxy SOCKS5 一键管理"
    echo "=================================="
    
    if check_installation; then
        echo "1. 查看状态"
        echo "2. 切换认证模式"
        echo "3. 更改端口"
        echo "4. 查看日志"
        echo "5. 测试连接"
        echo "6. 重启服务"
        echo "7. 停止服务"
        echo "8. 启动服务"
        echo "9. 卸载"
        echo "0. 退出"
    else
        echo "检测到未安装3proxy"
        echo "1. 立即安装"
        echo "0. 退出"
    fi
    echo "=================================="
}

# 主程序
main() {
    if [ "$EUID" -ne 0 ]; then
        echo "请使用root权限运行: sudo $0"
        exit 1
    fi
    
    # 检测系统类型和包管理器
    check_package_manager
    
    while true; do
        show_menu
        read -p "请选择操作: " choice
        echo
        
        if ! check_installation; then
            case $choice in
                1) install_3proxy && echo "按Enter继续..." && read ;;
                0) echo "退出"; exit 0 ;;
                *) echo "无效选择" && sleep 1 ;;
            esac
        else
            case $choice in
                1) show_status && echo "按Enter继续..." && read ;;
                2) toggle_auth && echo "按Enter继续..." && read ;;
                3) change_port && echo "按Enter继续..." && read ;;
                4) show_logs && echo "按Enter继续..." && read ;;
                5) test_proxy && echo "按Enter继续..." && read ;;
                6) systemctl restart 3proxy && echo "✓ 服务已重启" && sleep 1 ;;
                7) systemctl stop 3proxy && echo "✓ 服务已停止" && sleep 1 ;;
                8) systemctl start 3proxy && echo "✓ 服务已启动" && sleep 1 ;;
                9) uninstall_3proxy && echo "按Enter继续..." && read ;;
                0) echo "退出"; exit 0 ;;
                *) echo "无效选择" && sleep 1 ;;
            esac
        fi
    done
}

# 如果有参数则直接执行
case "$1" in
    "install") install_3proxy ;;
    "status") check_installation && show_status || echo "未安装3proxy" ;;
    "test") check_installation && test_proxy || echo "未安装3proxy" ;;
    *) main ;;
esac 
