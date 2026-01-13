#!/bin/bash

# anytls 安装/卸载管理脚本
# 功能：安装 anytls 或彻底卸载（含 systemd 服务清理）
# 支持架构：amd64 (x86_64)、arm64 (aarch64)、armv7 (armv7l)

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "必须使用 root 或 sudo 运行！"
    exit 1
fi

# 安装必要工具：wget, curl, unzip
function install_dependencies() {
    echo "[初始化] 正在安装必要依赖（wget, curl, unzip）..."
    apt update -y >/dev/null 2>&1

    for dep in wget curl unzip; do
        if ! command -v $dep &>/dev/null; then
            echo "正在安装 $dep..."
            apt install -y $dep || {
                echo "无法安装依赖: $dep，请手动运行 'sudo apt install $dep' 后再继续。"
                exit 1
            }
        fi
    done
}

# 调用依赖安装函数
install_dependencies

# 自动检测系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)  BINARY_ARCH="amd64" ;;
    aarch64) BINARY_ARCH="arm64" ;;
    armv7l)  BINARY_ARCH="armv7" ;;
    *)       echo "不支持的架构: $ARCH"; exit 1 ;;
esac

# 获取最新版本
get_latest_version() {
    # 尝试从 GitHub API 获取最新版本标签
    local latest_version
    latest_version=$(curl -s https://api.github.com/repos/anytls/anytls-go/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [ -z "$latest_version" ]; then
        echo "v0.0.12" # 获取失败时的默认版本
    else
        echo "$latest_version"
    fi
}

# 动态配置参数
VERSION_TAG=$(get_latest_version)
echo "正在准备安装 anytls 版本: ${VERSION_TAG}..."

# 处理版本号 (去除 v 前缀用于文件名)
VERSION_NUM=${VERSION_TAG#v}

DOWNLOAD_URL="https://github.com/anytls/anytls-go/releases/download/${VERSION_TAG}/anytls_${VERSION_NUM}_linux_${BINARY_ARCH}.zip"
ZIP_FILE="/tmp/anytls_${VERSION_NUM}_linux_${BINARY_ARCH}.zip"
BINARY_DIR="/usr/local/bin"
BINARY_NAME="anytls-server"
SERVICE_NAME="anytls"

# 改进的IP获取函数
get_ip() {
    local ip=""
    ip=$(ip -o -4 addr show scope global | awk '{print $4}' | cut -d'/' -f1 | head -n1)
    [ -z "$ip" ] && ip=$(ifconfig 2>/dev/null | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1' | head -n1)
    [ -z "$ip" ] && ip=$(curl -4 -s --connect-timeout 3 ifconfig.me 2>/dev/null || curl -4 -s --connect-timeout 3 icanhazip.com 2>/dev/null)
    
    if [ -z "$ip" ]; then
        echo "未能自动获取IP，请手动输入服务器IP地址"
        read -p "请输入服务器IP地址: " ip
    fi
    
    echo "$ip"
}

# 显示菜单
function show_menu() {
    clear
    echo "-------------------------------------"
    echo " anytls 服务管理脚本 (${BINARY_ARCH}架构) "
    echo "-------------------------------------"
    echo "1. 安装 anytls"
    echo "2. 卸载 anytls"
    echo "3. 查看配置"
    echo "4. 修改配置"
    echo "0. 退出"
    echo "-------------------------------------"
    read -p "请输入选项 [0-4]: " choice
    case $choice in
        1) install_anytls ;;
        2) uninstall_anytls ;;
        3) view_config ;;
        4) modify_config ;;
        0) exit 0 ;;
        *) echo "无效选项！" && sleep 1 && show_menu ;;
    esac
}

# 安装功能
# 生成随机端口 (10000-65535)
function get_random_port() {
    local port
    while true; do
        # 生成 10000-65535 之间的随机数
        port=$((RANDOM + 10000)) 
        [ $port -gt 65535 ] && port=$((port % 55535 + 10000))
        
        # 检查端口占用 (尝试使用 ss 或 netstat，如果都没有则跳过检查)
        if command -v ss &>/dev/null; then
            if ss -lnt | grep -q ":$port "; then continue; fi
        elif command -v netstat &>/dev/null; then
            if netstat -lnt | grep -q ":$port "; then continue; fi
        fi
        echo "$port"
        return
    done
}

# 生成随机密码 (16位字母数字)
function generate_password() {
    # 优先使用 openssl，次选 /dev/urandom
    if command -v openssl &>/dev/null; then
        openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16
    else
        tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16
    fi
}

# 获取节点名称 (Anytls-ISP-Country)
function get_node_name() {
    # 使用 ip-api.com 获取信息 (line格式: CountryCode\nISP)
    local api_url="http://ip-api.com/line/?fields=countryCode,isp"
    local info
    
    info=$(curl -s --connect-timeout 5 "$api_url")
    
    if [ $? -eq 0 ] && [ -n "$info" ]; then
        local country=$(echo "$info" | sed -n '1p')
        local isp=$(echo "$info" | sed -n '2p')
        
        # 清理 ISP 名称: 去除空格和连字符，只保留字母数字，使名称更紧凑
        # 例如 "Alice Networks" -> "AliceNetworks"
        isp=$(echo "$isp" | tr -d ' -' | tr -cd 'a-zA-Z0-9')
        
        # 截取 ISP 长度
        isp=${isp:0:15}
        
        # 拼接名称: Anytls-Country-ISP (使用连字符，ISP名称已清洗，无歧义)
        # 例如: Anytls-HK-AliceNetworks
        echo "Anytls-${country}-${isp}"
    else
        # 获取失败时的回退名称
        echo "Anytls-Node-$(date +%s)"
    fi
}

# 安装功能
function install_anytls() {
    # 下载
    echo "[1/5] 下载 anytls (${BINARY_ARCH}架构)..."
    wget "$DOWNLOAD_URL" -O "$ZIP_FILE" || {
        echo "下载失败！可能原因："
        echo "1. 网络连接问题"
        echo "2. 该架构的二进制文件不存在"
        exit 1
    }

    # 解压
    echo "[2/5] 解压文件..."
    unzip -o "$ZIP_FILE" -d "$BINARY_DIR" || {
        echo "解压失败！文件可能损坏"
        exit 1
    }
    chmod +x "$BINARY_DIR/$BINARY_NAME"

    # 生成配置
    echo "正在生成随机配置..."
    PASSWORD=$(generate_password)
    PORT=$(get_random_port)
    NODE_NAME=$(get_node_name)
    
    # 配置服务
    echo "[3/5] 配置 systemd 服务 (端口: $PORT)..."
    cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=anytls Service
After=network.target

[Service]
ExecStart=$BINARY_DIR/$BINARY_NAME -l 0.0.0.0:$PORT -p $PASSWORD
Restart=always
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务
    echo "[4/5] 启动服务..."
    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl start $SERVICE_NAME

    # 清理
    rm -f "$ZIP_FILE"

    # 获取服务器IP
    SERVER_IP=$(get_ip)

    # 验证
    echo -e "\n\033[32m√ 安装完成！\033[0m"
    echo -e "\033[32m√ 架构类型: ${BINARY_ARCH}\033[0m"
    echo -e "\033[32m√ 服务名称: $SERVICE_NAME\033[0m"
    echo -e "\033[32m√ 监听端口: 0.0.0.0:$PORT (随机生成)\033[0m"
    echo -e "\033[32m√ 密码: $PASSWORD (随机生成)\033[0m"
    echo -e "\033[32m√ 节点名称: $NODE_NAME (自动识别)\033[0m"
    echo -e "\n\033[33m管理命令:\033[0m"
    echo -e "  启动: systemctl start $SERVICE_NAME"
    echo -e "  停止: systemctl stop $SERVICE_NAME"
    echo -e "  重启: systemctl restart $SERVICE_NAME"
    echo -e "  状态: systemctl status $SERVICE_NAME"
    
    # 高亮显示连接信息
    echo -e "\n\033[36m\033[1m〓 NekoBox连接信息 〓\033[0m"
    echo -e "\033[30;43m\033[1m anytls://$PASSWORD@$SERVER_IP:$PORT/?insecure=1#$NODE_NAME \033[0m"
    echo -e "\033[33m\033[1m请妥善保管此连接信息！\033[0m"
}

# 卸载功能
function uninstall_anytls() {
    echo "正在卸载 anytls..."
    
    # 停止服务
    if systemctl is-active --quiet $SERVICE_NAME; then
        systemctl stop $SERVICE_NAME
        echo "[1/4] 已停止服务"
    fi

    # 禁用服务
    if systemctl is-enabled --quiet $SERVICE_NAME; then
        systemctl disable $SERVICE_NAME
        echo "[2/4] 已禁用开机启动"
    fi

    # 删除文件
    if [ -f "$BINARY_DIR/$BINARY_NAME" ]; then
        rm -f "$BINARY_DIR/$BINARY_NAME"
        echo "[3/4] 已删除二进制文件"
    fi

    # 清理配置
    if [ -f "/etc/systemd/system/$SERVICE_NAME.service" ]; then
        rm -f "/etc/systemd/system/$SERVICE_NAME.service"
        systemctl daemon-reload
        echo "[4/4] 已移除服务配置"
    fi

    echo -e "\n\033[32m[结果]\033[0m anytls 已完全卸载！"
}

# 查看配置
function view_config() {
    if [ ! -f "/etc/systemd/system/$SERVICE_NAME.service" ]; then
        echo "错误：anytls 未安装或服务文件不存在！"
        return
    fi

    # 从服务文件中提取端口和密码
    local service_content=$(cat "/etc/systemd/system/$SERVICE_NAME.service")
    # 提取端口: 匹配 -l 0.0.0.0:(数字)
    local current_port=$(echo "$service_content" | grep -oP '\-l 0.0.0.0:\K\d+')
    # 提取密码: 匹配 -p (非空格字符)
    local current_password=$(echo "$service_content" | grep -oP '\-p \K\S+')
    
    if [ -z "$current_port" ] || [ -z "$current_password" ]; then
        echo "错误：无法从配置文件中读取配置信息！"
        return
    fi
    
    local ip=$(get_ip)
    local node_name=$(get_node_name)
    
    echo -e "\n\033[36m\033[1m〓 当前配置信息 〓\033[0m"
    echo -e "端口: \033[32m$current_port\033[0m"
    echo -e "密码: \033[32m$current_password\033[0m"
    echo -e "节点: \033[32m$node_name\033[0m"
    
    echo -e "\n\033[36m\033[1m〓 NekoBox连接信息 〓\033[0m"
    echo -e "\033[30;43m\033[1m anytls://$current_password@$ip:$current_port/?insecure=1#$node_name \033[0m"
}

# 修改配置
function modify_config() {
    if [ ! -f "/etc/systemd/system/$SERVICE_NAME.service" ]; then
        echo "错误：anytls 未安装！"
        return
    fi

    echo "-------------------------------------"
    echo " 修改配置"
    echo "-------------------------------------"
    echo "1. 修改端口"
    echo "2. 修改密码"
    echo "0. 返回主菜单"
    echo "-------------------------------------"
    read -p "请输入选项 [0-2]: " sub_choice

    case $sub_choice in
        1)
            echo "当前操作：修改端口"
            read -p "请输入新端口 (留空则随机生成): " new_port
            if [ -z "$new_port" ]; then
                new_port=$(get_random_port)
                echo "已生成随机端口: $new_port"
            fi
            
            # 简单的端口合法性检查
            if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                echo "错误：无效的端口号！"
                return
            fi
            
            # 使用 sed 替换端口
            sed -i "s/-l 0.0.0.0:[0-9]*/-l 0.0.0.0:$new_port/" "/etc/systemd/system/$SERVICE_NAME.service"
            
            echo "正在重启服务..."
            systemctl daemon-reload
            systemctl restart $SERVICE_NAME
            echo "✅ 端口已修改为: $new_port"
            view_config
            ;;
        2)
            echo "当前操作：修改密码"
            read -p "请输入新密码 (留空则随机生成): " new_password
            if [ -z "$new_password" ]; then
                new_password=$(generate_password)
                echo "已生成随机密码: $new_password"
            fi
            
            # 使用 sed 替换密码 (注意密码中可能含有特殊字符，这里假设密码为普通字母数字，如果是复杂字符需谨慎处理分隔符)
            # 由于 generate_password 只生成字母数字，这里直接替换相对安全
            sed -i "s/-p \S*/-p $new_password/" "/etc/systemd/system/$SERVICE_NAME.service"
            
            echo "正在重启服务..."
            systemctl daemon-reload
            systemctl restart $SERVICE_NAME
            echo "✅ 密码已修改为: $new_password"
            view_config
            ;;
        0) return ;;
        *) echo "无效选项！" ;;
    esac
}

# 启动菜单
show_menu
