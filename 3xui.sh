#!/bin/bash
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

xui_folder="/usr/local/x-ui"
xui_service="/etc/systemd/system"

# 只保留必须的两个本地文件
LOCAL_TAR="/root/x-ui-linux-amd64.tar.gz"
LOCAL_XUI_SH="/root/x-ui.sh"

# 禁用所有网络代理/外网请求
unset http_proxy https_proxy all_proxy no_proxy

# 必须root
[[ $EUID -ne 0 ]] && echo -e "${red}请使用 root 运行${plain}" && exit 1

# 系统版本
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
else
    echo -e "${red}无法识别系统${plain}" && exit 1
fi

# 架构检测
arch_check() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7*) echo "armv7" ;;
        *) echo -e "${red}不支持架构${plain}" && exit 1 ;;
    esac
}
ARCH=$(arch_check)

# 正则校验IP
is_ipv4() { [[ $1 =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; }
is_ipv6() { [[ $1 =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; }

# 本地自动抓取公网IPv4
get_local_ipv4() {
    ip -4 addr | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
    | grep -vE '^127\.|^10\.|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[0-1]\.|^192\.168\.' \
    | head -n1
}

# 本地自动抓取公网IPv6
get_local_ipv6() {
    ip -6 addr | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}' \
    | grep -vE '^fe80:|^::1' \
    | head -n1
}

# 自动获取IP，失败则手动兜底
auto_get_ip() {
    ipv4=$(get_local_ipv4)
    ipv6=$(get_local_ipv6)

    echo -e "${green}==== 本地自动抓取IP ====${plain}"
    if [[ -n "$ipv4" ]]; then
        echo -e "自动识别 IPv4: $ipv4"
    else
        echo -e "${yellow}未自动抓到公网IPv4${plain}"
    fi

    if [[ -n "$ipv6" ]]; then
        echo -e "自动识别 IPv6: $ipv6"
    else
        echo -e "${yellow}未自动抓到公网IPv6${plain}"
    fi

    # IPv4为空，手动输入
    if [[ -z "$ipv4" ]]; then
        while true; do
            read -rp "请手动输入公网IPv4: " tmp
            if is_ipv4 "$tmp"; then
                ipv4=$tmp
                break
            else
                echo -e "${red}IPv4格式错误，重新输入${plain}"
            fi
        done
    fi

    # IPv6为空，可留空跳过
    if [[ -z "$ipv6" ]]; then
        read -rp "请手动输入公网IPv6(留空跳过): " tmp
        if is_ipv6 "$tmp"; then
            ipv6=$tmp
        else
            ipv6=""
            echo -e "${yellow}无有效IPv6，仅使用IPv4${plain}"
        fi
    fi
}

# 安装基础依赖
install_base() {
    case $release in
        ubuntu|debian) apt-get update && apt-get install -y cron tar tzdata socat ca-certificates openssl ;;
        centos|rhel|rocky) yum install -y cronie tar tzdata socat ca-certificates openssl ;;
        arch) pacman -Syu --noconfirm cronie tar tzdata socat ca-certificates openssl ;;
        alpine) apk add dcron tar tzdata socat ca-certificates openssl ;;
        *) apt-get install -y cron tar tzdata socat ca-certificates openssl ;;
    esac
}

# 随机字符串
gen_rand() {
    openssl rand -base64 20 | tr -dc 'a-zA-Z0-9' | head -c $1
}

# SSL交互（仅本地证书，禁在线申请）
ssl_menu() {
    local port=$1
    local ip4=$2
    local ip6=$3
    SSL_SCHEME="http"
    SSL_HOST=$ip4

    echo -e "\n${green}1. 导入本地SSL证书  2. 跳过SSL使用HTTP${plain}"
    read -rp "选择: " opt
    if [[ $opt == 1 ]]; then
        read -rp "证书fullchain路径: " cert
        read -rp "证书privkey路径: " key
        $xui_folder/x-ui cert -webCert "$cert" -webCertKey "$key"
        SSL_SCHEME="https"
    fi

    read -rp "是否仅监听本地127.0.0.1?[y/N] " lcl
    if [[ $lcl =~ [yY] ]]; then
        $xui_folder/x-ui setting -listenIP 127.0.0.1
        SSL_HOST="127.0.0.1"
    fi
    systemctl restart x-ui 2>/dev/null
}

# 安装后配置
config_after_install() {
    auto_get_ip
    ip4=$ipv4
    ip6=$ipv6

    has_def=$($xui_folder/x-ui setting -show | grep hasDefaultCredential | awk '{print $2}')
    webpath=$($xui_folder/x-ui setting -show | grep webBasePath | awk '{print $2}')
    port=$($xui_folder/x-ui setting -show | grep port | awk '{print $2}')

    if [[ ${#webpath} -lt 4 || $has_def == true ]]; then
        user=$(gen_rand 10)
        pass=$(gen_rand 10)
        webpath=$(gen_rand 18)
        rport=$(shuf -i 1024-62000 -n1)
        read -rp "自定义端口？[y/N] " p_opt
        [[ $p_opt =~ [yY] ]] && read -rp "输入端口: " rport

        $xui_folder/x-ui setting -username $user -password $pass -port $rport -webBasePath $webpath
        port=$rport
    fi

    ssl_menu $port $ip4 $ip6

    token=$($xui_folder/x-ui setting -getApiToken | awk '{print $2}')
    echo -e "\n${green}==== 安装完成信息 ====${plain}"
    echo "地址: ${SSL_SCHEME}://${SSL_HOST}:${port}/${webpath}"
    echo "账号: $user"
    echo "密码: $pass"
    [[ -n $ip6 ]] && echo "IPv6: $ip6"
    echo "API Token: $token"

    $xui_folder/x-ui migrate
}

# 主安装流程
install_xui() {
    # 只检查必须的两个文件
    for f in $LOCAL_TAR $LOCAL_XUI_SH; do
        [[ ! -f $f ]] && echo -e "${red}缺失本地文件: $f${plain}" && exit 1
    done

    cd /usr/local
    # 清理旧版本残留
    systemctl stop x-ui 2>/dev/null
    rm -rf $xui_folder
    rm -f $xui_service/x-ui.service /usr/bin/x-ui

    # 解压本地包
    cp $LOCAL_TAR ./x-ui.tar.gz
    tar zxf x-ui.tar.gz
    rm -f x-ui.tar.gz
    mv x-ui-linux-$ARCH x-ui

    # 拷贝控制脚本
    cp $LOCAL_XUI_SH /usr/bin/x-ui
    chmod +x /usr/bin/x-ui $xui_folder/*

    # 内置生成 systemd 服务，不再需要三个外部service文件
    cat > $xui_service/x-ui.service << EOF
[Unit]
Description=X-UI Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/x-ui
ExecStart=/usr/local/x-ui/x-ui
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now x-ui

    mkdir -p /var/log/x-ui
    config_after_install
}

install_base
install_xui
