#!/bin/sh
. /usr/share/openclash/log.sh
. /lib/functions.sh

# This script is called by /etc/init.d/openclash
# Add your custom firewall rules here, they will be added after the end of the OpenClash iptables rules

LOG_OUT "Tip: Start Add Custom Firewall Rules..."

# ------------------------------------以下是自定义脚本 排除mosnds 指定白名单DNS解析的IP流入 ---------------------------------------------------

en_mode=$(uci -q get openclash.config.en_mode)
proxy_port=$(uci -q get openclash.config.proxy_port)
dns_port=$(uci -q get openclash.config.dns_port)
ipv6_enable=$(uci -q get openclash.config.ipv6_enable)
ipv6_mode=$(uci -q get openclash.config.ipv6_mode || echo 0)
ipv6_dns=$(uci -q get openclash.config.ipv6_dns || echo 0)
china_ip_route=$(uci -q get openclash.config.china_ip_route)
china_ip6_route=$(uci -q get openclash.config.china_ip6_route)
disable_udp_quic=$(uci -q get openclash.config.disable_udp_quic)
enable_redirect_dns=$(uci -q get openclash.config.enable_redirect_dns)

ipv6_status=$([ "$ipv6_enable" == "1" ] && echo "是" || echo "否")
ipv6_mode_status=$([ "$ipv6_mode" == "1" ] && echo "Redirect 模式" || ([ "$ipv6_mode" == "2" ] && echo "TUN 模式" || ([ "$ipv6_mode" == "3" ] && echo "Mix 混合模式【UDP-TUN，TCP-转发】" || echo "TProxy 模式")))
ipv6_dns_status=$([ "$ipv6_dns" == "1" ] && echo "是" || echo "否")
china_ip_route_status=$([ "$china_ip_route" == "1" ] && echo "绕过中国大陆" || ([ "$china_ip_route" == "2" ] && echo "海外用户回国模式" || echo "停用"))
china_ip6_route_status=$([ "$china_ip6_route" == "1" ] && echo "绕过中国大陆" || ([ "$china_ip6_route" == "2" ] && echo "海外用户回国模式" || echo "停用"))
disable_udp_quic_status=$([ "$disable_udp_quic" == "1" ] && echo "是" || echo "否")
enable_redirect_status=$([ "$enable_redirect_dns" == "1" ] && echo "使用 Dnsmasq 转发" || ([ "$china_ip_route" == "2" ] && echo "使用防火墙转发" || echo "禁用"))

LOG_OUT "当前运行模式: $en_mode; 代理端口: $proxy_port; DNS端口: $dns_port"
LOG_OUT "禁用 QUIC: $disable_udp_quic_status; 本地 DNS 劫持: $enable_redirect_status"
LOG_OUT "IPV4 绕过大陆IP: $china_ip_route_status; IPV6 绕过大陆IP: $china_ip6_route_status"
LOG_OUT "IPv6 流量代理: $ipv6_status; IPv6 代理模式: $ipv6_mode_status; 允许 IPv6 类型 DNS 解析: $ipv6_dns_status"


# 检查当前系统使用的是iptables还是nftables
if command -v nft > /dev/null 2>&1 && nft list ruleset > /dev/null 2>&1; then
    firewall_type="nftables"
    LOG_OUT "检测到使用的是 nftables"
else
    firewall_type="iptables"
    LOG_OUT "检测到使用的是 iptables"
fi

add_rules_for_chain() {
    local ipt_cmd=$1
    local table=$2
    local chain=$3
    local match_conditions=$4  # 完整的匹配条件
    local action=$5
    local action_modifiers=$6   # 用于动作的修饰，如 "REJECT --reject-with icmp-port-unreachable"

    local route_rule="china_ip_route"
    if [ "$ipt_cmd" = "ip6tables" ]; then
        route_rule="china_ip6_route"
    fi

    # 查找包含 "china_ip_route" 的规则的位置
    local position=$($ipt_cmd -t $table -L $chain --line-numbers | grep $route_rule | head -n 1 | awk '{print $1}')
    if [ -z "$position" ]; then
        LOG_OUT "警告：未在 $chain 链中找到 '$route_rule' 规则。请确认 $chain 链是否已正确配置，且包含必要的 '$route_rule' 规则。"
        return
    fi

    # 计算插入位置（目标规则之后）
    position=$((position + 1))

    # 检查链是否存在
    if ! $ipt_cmd -t $table -L $chain > /dev/null 2>&1; then
        LOG_OUT "警告：防火墙链 $chain 不存在 ($table 表), 无法添加规则"
        return
    fi
	
    # 构建并检查规则是否存在
    local cmd="$ipt_cmd -t $table -C $chain $match_conditions -j $action $action_modifiers"
    if ! eval $cmd > /dev/null 2>&1; then
        # 添加规则
        cmd="$ipt_cmd -t $table -I $chain $position $match_conditions -j $action $action_modifiers"
        if ! eval $cmd 2>&1 | grep -q "$ipt_cmd: "; then
            LOG_OUT "成功应用规则到 $chain 链 ($table 表) 位置 $position"
        else
            LOG_OUT "错误：添加规则失败，请检查防火墙配置和权限"
        fi
    else
        LOG_OUT "警告：规则已存在于 $chain 链 ($table 表)，未进行重复添加"
    fi
}

add_nft_rules_for_chain() {
    local table=$1
    local chain=$2
    local ip_version=$3
    local match_conditions=$4
    local action=$5
    local action_modifiers=$6

    local family="inet"
    local route_rule="china_ip_route"
    if [ "$ip_version" = "ip6" ]; then
        route_rule="china_ip6_route"
    fi

    # 打印接收到的参数，确认是否正确
    # LOG_OUT "接收到的参数：table=$table, chain=$chain, ip_version=$ip_version, match_conditions=$match_conditions, action=$action, action_modifiers=$action_modifiers"

    # 获取目标规则的句柄
    local handle=$(nft --json list chain $family $table $chain | jq -r --arg rule "$route_rule" '.nftables[] | select(.rule.expr[]? | select(.match.right == ("@" + $rule))) | .rule.handle')
    # 获取链中包含特定规则的索引位置
    local rule_index=$(nft --json list chain $family $table $chain | jq --arg rule "$route_rule" '.nftables | to_entries | map(select(.value.rule?.expr[]? | any(.match?; .right == ("@" + $rule)))) | .[0].key')
    LOG_OUT "目标规则的句柄是: $handle, 目标规则的索引位置: $rule_index"

    # 检查是否找到符合条件的规则
    if [[ $rule_index != "null" && $rule_index != "" ]]; then
        # 计算目标规则之后的句柄
        handle=$(nft --json list chain $family $table $chain | jq -r ".nftables[$((rule_index + 1))].rule.handle")
        # 检查是否成功获取下一个规则的句柄
        if [[ $handle != "null" && $handle != "" ]]; then
            LOG_OUT "目标规则之后的句柄是: $handle"
        else
            LOG_OUT "警告：未在链 $chain 中找到 '$route_rule' 规则之后的有效规则。"
            return
        fi
    else
        LOG_OUT "警告：未在 $chain 链中找到包含 '$route_rule' 的规则。请确认 $chain 链是否已正确配置，且包含必要的 '$route_rule' 规则。"
        return
    fi

    local rule_cmd="$match_conditions $action"
    if [ -n "$action_modifiers" ]; then
        rule_cmd="$rule_cmd $action_modifiers"
    fi

    # LOG_OUT "执行前最终规则命令：$rule_cmd"


    # 检查链是否存在
    if ! nft list chain $family $table $chain > /dev/null 2>&1; then
        LOG_OUT "警告：防火墙链 $chain 不存在 ($table 表), 无法添加规则"
        return
    fi
	
    # 直接执行构建的命令
    nft insert rule $family $table $chain handle $handle $rule_cmd

    if [ $? -eq 0 ]; then
        LOG_OUT "成功应用规则到 $chain 链 ($table 表) 位置 handle $handle"
    else
        LOG_OUT "错误：添加/插入规则失败，请检查防火墙配置和权限"
    fi
}

if [ "$china_ip_route" == "1" ]; then
   LOG_OUT "正在配置 mosdns 白名单，IPV4 地址绕过 OpenClash 内核"
   if [ "$firewall_type" = "nftables" ]; then
       if nft list set inet fw4 mosdns_ip_route >/dev/null 2>&1; then
           echo "mosdns 白名单 IPV4 集合已存在，正在清空..."
           nft flush set inet fw4 mosdns_ip_route
       else
           nft add set inet fw4 mosdns_ip_route { type ipv4_addr\; flags interval\; auto-merge\; }

       fi

       # 检查 IPv4 集合操作是否成功
       if nft list set inet fw4 mosdns_ip_route >/dev/null 2>&1; then
           LOG_OUT "成功创建 mosdns 白名单 IPV4 集合。"
       else
           LOG_OUT "错误：无法创建 mosdns 白名单 IPV4 集合"
       fi

       # 添加规则到 openclash 和 openclash_output 链
       add_nft_rules_for_chain "fw4" "openclash" "ip" "ip daddr @mosdns_ip_route" "counter return" ""
       add_nft_rules_for_chain "fw4" "openclash_mangle" "ip" "ip daddr @mosdns_ip_route" "counter return" ""
       add_nft_rules_for_chain "fw4" "openclash_mangle_output" "ip" "ip daddr @mosdns_ip_route" "counter return" ""
       # add_nft_rules_for_chain "fw4" "openclash_output" "ip" "skuid != 65534 ip daddr @mosdns_ip_route" "counter return" ""
       add_nft_rules_for_chain "fw4" "openclash_output" "ip" "ip daddr @mosdns_ip_route" "counter return" ""
    
       if [ "$disable_udp_quic" == "1" ]; then
           add_nft_rules_for_chain "fw4" "forward" "ip" "oifname utun udp dport 443 ip daddr != @china_ip_route ip daddr != @mosdns_ip_route" "counter reject" 'comment "OpenClash QUIC REJECT"'
           del_route_rule="china_ip_route"
           # del_handle=$(nft --json list chain inet fw4 forward | jq -r --arg rule "$del_route_rule" '.nftables[] | select(.rule.expr[]? | select(.match.right == ("@" + $rule))) | .rule.handle')
           del_handle=$(nft --json list chain inet fw4 forward | jq -r --arg rule "$del_route_rule" '[.nftables[] | select(.rule.expr[]? | select(.match.right == ("@" + $rule))) | .rule.handle] | min')

           if [ -z "$del_handle" ]; then
             LOG_OUT "警告：未在 forward 链中找到包含 '$del_route_rule' 的规则。请确认 forward 链是否已正确配置，且包含必要的 '$del_route_rule' 规则。"
             return
           fi
           nft delete rule inet fw4 forward handle $del_handle
           # nft insert rule inet fw4 forward position 0 oifname utun udp dport 443 ip daddr != @china_ip_route ip daddr != @mosdns_ip_route counter reject comment \"OpenClash QUIC REJECT\"
 
           LOG_OUT "成功更新 FORWARD 规则以禁用非白名单 QUIC 流量，适用于 utun 接口。"
       else
           LOG_OUT "禁用 QUIC 规则未启用，跳过规则处理。"
       fi
    
       LOG_OUT "要查看被设置为绕过 OpenClash 的 IPV4 地址列表，请运行 'nft list set inet fw4 mosdns_ip_route'"

   else

       # 使用 -! 选项创建集合，忽略已存在的错误
       ipset create mosdns_ip_route hash:net -!

       # 清空集合内容
       ipset flush mosdns_ip_route
       LOG_OUT "mosdns 白名单 IPV4 集合已处理（创建或清空）"

       # 检查 IPv4 集合操作是否成功
       if ipset list mosdns_ip_route > /dev/null 2>&1; then
           LOG_OUT "成功创建 mosdns 白名单 IPV4 集合"
       else
           LOG_OUT "错误：无法创建 mosdns 白名单 IPV4 集合"
       fi
	   
       # 添加规则到 openclash 和 openclash_output 链
       add_rules_for_chain "iptables" "nat" "openclash" "-m set --match-set mosdns_ip_route dst" "RETURN" ""
       # add_rules_for_chain "iptables" "nat" "openclash_output" "-m owner ! --uid-owner 65534 -m set --match-set mosdns_ip_route dst" "RETURN" ""
       add_rules_for_chain "iptables" "nat" "openclash_output" "-m set --match-set mosdns_ip_route dst" "RETURN" ""
       add_rules_for_chain "iptables" "mangle" "openclash" "-m set --match-set mosdns_ip_route dst" "RETURN" ""
       add_rules_for_chain "iptables" "mangle" "openclash_output" "-m set --match-set mosdns_ip_route dst" "RETURN" ""

       # add_rules_for_chain "iptables" "mangle" "openclash_output" "-m owner ! --uid-owner 65534 -m set --match-set mosdns_ip_route dst" "RETURN" ""
       # add_rules_for_chain "iptables" "mangle" "openclash" "-m set ! --match-set mosdns_ip_route dst" "RETURN" ""


       if [ "$disable_udp_quic" == "1" ]; then
           # 首先尝试删除可能存在的针对QUIC的拒绝规则。
           # 然后，如果禁用 QUIC 规则被启用，添加一个新的 FORWARD 规则，该规则除了排除 china_ip_route 中的地址，
           # 还要排除 mosdns_ip_route 中的地址，从而拒绝不在这两个集合中的所有 UDP/443 流量。
           add_rules_for_chain "iptables" "filter" "FORWARD" "-p udp --dport 443 -o utun -m comment --comment 'OpenClash QUIC REJECT' -m set ! --match-set china_ip_route dst -m set ! --match-set mosdns_ip_route dst" "REJECT" ""

           iptables -D FORWARD -p udp --dport 443 -o utun -m comment --comment "OpenClash QUIC REJECT" -m set ! --match-set china_ip_route dst -j REJECT
           # iptables -I FORWARD -p udp --dport 443 -o utun -m comment --comment "OpenClash QUIC REJECT" -m set ! --match-set china_ip_route dst -m set ! --match-set mosdns_ip_route dst -j REJECT
           LOG_OUT "成功更新 FORWARD 规则以禁用非白名单 QUIC 流量，适用于 utun 接口。"
       else
           LOG_OUT "禁用 QUIC 规则未启用，跳过规则处理。"
       fi

       LOG_OUT "要查看被设置为绕过 OpenClash 的 IPV4 地址列表，请运行 'ipset list mosdns_ip_route'"
   fi    
fi

if [ "$china_ip6_route" == "1" ]; then
   LOG_OUT "正在配置 mosdns 白名单，IPV6 地址绕过 OpenClash 内核"
   if [ "$firewall_type" = "nftables" ]; then
       if nft list set inet fw4 mosdns_ip6_route >/dev/null 2>&1; then
           LOG_OUT "mosdns 白名单 IPV6 集合已存在，正在清空..."
           nft flush set inet fw4 mosdns_ip6_route
       else
           nft add set inet fw4 mosdns_ip6_route { type ipv6_addr\; flags interval\; auto-merge\; }

       fi

       # 检查 IPv6 集合操作是否成功
       if nft list set inet fw4 mosdns_ip6_route >/dev/null 2>&1; then
           LOG_OUT "成功创建 mosdns 白名单 IPV6 集合。"
       else
           LOG_OUT "错误：无法创建 mosdns 白名单 IPV6 集合"
       fi

       # 添加规则到 openclash 和 openclash_output 链
       add_nft_rules_for_chain "fw4" "openclash_v6" "ip6" "ip6 daddr @mosdns_ip6_route" "counter return" ""
       add_nft_rules_for_chain "fw4" "openclash_mangle_v6" "ip6" "ip6 daddr @mosdns_ip6_route" "counter return" ""
       # add_nft_rules_for_chain "fw4" "openclash_mangle_output_v6" "ip6" "skuid != 65534 ip6 daddr @mosdns_ip6_route" "counter return" ""
       add_nft_rules_for_chain "fw4" "openclash_mangle_output_v6" "ip6" "ip6 daddr @mosdns_ip6_route" "counter return" ""
       add_nft_rules_for_chain "fw4" "openclash_output_v6" "ip6" "ip6 daddr @mosdns_ip6_route" "counter return" ""

       if [ "$disable_udp_quic" == "1" ]; then
           add_nft_rules_for_chain "fw4" "forward" "ip6" "oifname utun udp dport 443 ip6 daddr != @china_ip6_route ip6 daddr != @mosdns_ip6_route" "counter reject" 'comment "OpenClash QUIC REJECT"'
           del_route_rule="china_ip6_route"
           # del_handle=$(nft --json list chain inet fw4 forward | jq -r --arg rule "$del_route_rule" '.nftables[] | select(.rule.expr[]? | select(.match.right == ("@" + $rule))) | .rule.handle')
           del_handle=$(nft --json list chain inet fw4 forward | jq -r --arg rule "$del_route_rule" '[.nftables[] | select(.rule.expr[]? | select(.match.right == ("@" + $rule))) | .rule.handle] | min')
           if [ -z "$del_handle" ]; then
             LOG_OUT "警告：未在 forward 链中找到包含 '$del_route_rule' 的规则。请确认 forward 链是否已正确配置，且包含必要的 '$del_route_rule' 规则。"
             return
           fi
           nft delete rule inet fw4 forward handle $del_handle
           # nft insert rule inet fw4 forward position 0 oifname utun udp dport 443 ip6 daddr != @china_ip6_route ip6 daddr != @mosdns_ip6_route counter reject comment \"OpenClash QUIC REJECT\"
           
           LOG_OUT "成功更新 FORWARD 规则以禁用非白名单 QUIC 流量，适用于 utun 接口。"
       else
           LOG_OUT "禁用 QUIC 规则未启用，跳过规则处理。"
       fi

       LOG_OUT "要查看被设置为绕过 OpenClash 的 IPV6 地址列表，请运行 'nft list set inet fw4 mosdns_ip6_route'"

   else
       # 使用 -! 选项创建集合，忽略已存在的错误
       ipset create mosdns_ip6_route hash:net family inet6 -!

       # 清空集合内容
       ipset flush mosdns_ip6_route
       LOG_OUT "mosdns 白名单 IPV6 集合已处理（创建或清空）"

       # 检查 IPv6 集合操作是否成功
       if ipset list mosdns_ip6_route > /dev/null 2>&1; then
           LOG_OUT "成功创建 mosdns 白名单 IPV6 集合"
       else
           LOG_OUT "错误：无法创建 mosdns 白名单 IPV6 集合"
       fi

       # 添加规则到 openclash 和 openclash_output 链
       add_rules_for_chain "ip6tables" "nat" "openclash" "-m set --match-set mosdns_ip6_route dst" "RETURN" ""
       # add_rules_for_chain "ip6tables" "nat" "openclash_output" "-m owner ! --uid-owner 65534 -m set --match-set mosdns_ip6_route dst" "RETURN" ""
       add_rules_for_chain "ip6tables" "nat" "openclash_output" "-m set --match-set mosdns_ip6_route dst" "RETURN" ""
       add_rules_for_chain "ip6tables" "mangle" "openclash" "-m set --match-set mosdns_ip6_route dst" "RETURN" ""
       # add_rules_for_chain "ip6tables" "mangle" "openclash_output" "-m owner ! --uid-owner 65534 -m set --match-set mosdns_ip6_route dst" "RETURN" ""
       add_rules_for_chain "ip6tables" "mangle" "openclash_output" "-m set --match-set mosdns_ip6_route dst" "RETURN" ""


       if [ "$disable_udp_quic" == "1" ]; then
           # 首先尝试删除可能存在的针对QUIC的拒绝规则。
           # 然后，如果禁用 QUIC 规则被启用，添加一个新的 FORWARD 规则，该规则除了排除 china_ip_route 中的地址，
           # 还要排除 mosdns_ip_route 中的地址，从而拒绝不在这两个集合中的所有 UDP/443 流量。
           add_rules_for_chain "ip6tables" "filter" "FORWARD" "-p udp --dport 443 -o utun -m comment --comment 'OpenClash QUIC REJECT' -m set ! --match-set china_ip6_route dst -m set ! --match-set mosdns_ip6_route dst" "REJECT" ""
           ip6tables -D FORWARD -p udp --dport 443 -o utun -m comment --comment "OpenClash QUIC REJECT" -m set ! --match-set china_ip6_route dst -j REJECT
           # ip6tables -I FORWARD -p udp --dport 443 -o utun -m comment --comment "OpenClash QUIC REJECT" -m set ! --match-set china_ip6_route dst -m set ! --match-set mosdns_ip6_route dst -j REJECT
           LOG_OUT "成功更新 FORWARD 规则以禁用非白名单 QUIC 流量，适用于 utun 接口。"
       else
           LOG_OUT "禁用 QUIC 规则未启用，跳过规则处理。"
       fi


       LOG_OUT "要查看被设置为绕过 OpenClash 的 IPV6 地址列表，请运行 'ipset list mosdns_ip6_route'"
   
   fi

fi

LOG_OUT "restart mosdns"
/etc/init.d/mosdns restart
#LOG_OUT "restart smartdns"
#/etc/init.d/smartdns restart
#LOG_OUT "restart AdGuardHome"
#/etc/init.d/AdGuardHome restart

exit 0
