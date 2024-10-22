#!/bin/sh
. /usr/share/openclash/ruby.sh
. /usr/share/openclash/log.sh
. /lib/functions.sh

# This script is called by /etc/init.d/openclash
# Add your custom overwrite scripts here, they will be take effict after the OpenClash own srcipts

LOG_OUT "Tip: Start Running Custom Overwrite Scripts..."
LOGTIME=$(echo $(date "+%Y-%m-%d %H:%M:%S"))
LOG_FILE="/tmp/openclash.log"
CONFIG_FILE="$1" #config path

# 使用 Ruby 编辑 YAML 文件的函数
ruby_edit() {
  local config_path=$1
  local key_name=$2
  local value=$3
  echo "[$LOGTIME] 正在编辑 $config_path:" | tee -a "$LOG_FILE"
  ruby -ryaml -e "
  yaml = YAML.load_file(ARGV[0])
  yaml${key_name} = ${value}
  File.open(ARGV[0], 'w') {|f| f.write(yaml.to_yaml)}
  " "$config_path"
  echo "[$LOGTIME] 将 $key_name 设置为 $value" | tee -a "$LOG_FILE"
}

# 创建 nameserver-policy 并赋值
#ruby_edit "$CONFIG_FILE" "['dns']['nameserver-policy']" "{'geosite:geolocation-!cn' => ['tls://8.8.4.4', 'https://1.0.0.1/dns-query'], 'geosite:cn,private' => ['https://dns.alidns.com/dns-query']}"
#ruby_edit "$CONFIG_FILE" "['dns']['nameserver-policy']" "{'geosite:cn,private' => ['https://dns.alidns.com/dns-query', 'https://doh.pub/dns-query']}"
# 添加 proxy-server-nameserver 并赋值
#ruby_edit "$CONFIG_FILE" "['dns']['proxy-server-nameserver']" "['https://doh.pub/dns-query']"
ruby_edit "$CONFIG_FILE" "['dns']['proxy-server-nameserver']" "['https://dns.alidns.com/dns-query', 'https://doh.pub/dns-query']"
#ruby_edit "$CONFIG_FILE" "['dns']['proxy-server-nameserver']" "['223.5.5.5']"
#ruby_edit "$CONFIG_FILE" "['dns']['prefer-h3']" "true"
#ruby_edit "$CONFIG_FILE" "['tun']['mtu']" "1500"
ruby_edit "$CONFIG_FILE" "['dns']['cache-algorithm']" "'arc'"

# 定义要删除的规则，使用一个字符串变量
rules_to_remove="DOMAIN-SUFFIX,cloudfront.net,🎬 EmbyProxy"
# rules_to_remove="DOMAIN-SUFFIX,aaa.net,🎬 EmbyProxy;DOMAIN-SUFFIX,bbb.net,🎬 EmbyProxy;"

remove_specified_rule() {
  local config_path=$1
  echo "[$LOGTIME] 正在检查并删除指定的规则" | tee -a "$LOG_FILE"

  rules_found=false
  rules_deleted=""
  delete_errors=""

  echo "$rules_to_remove" | tr ';' '\n' | while read -r rule; do
    echo "[$LOGTIME] 正在检查规则: $rule" | tee -a "$LOG_FILE"
    found=$(ruby -ryaml -e '
      require "yaml"
      yaml = YAML.load_file(ARGV[0])
      found = false
      yaml["rules"].delete_if do |r|
        if r == ARGV[1]
          found = true
          true  # 返回 true 表示删除这个元素
        else
          false
        end
      end
      File.open(ARGV[0], "w") { |f| f.write(yaml.to_yaml) }
      puts found
    ' "$config_path" "$rule")

    if [ "$found" = "true" ]; then
      echo "[$LOGTIME] 成功删除规则: $rule" | tee -a "$LOG_FILE"
      rules_found=true
      rules_deleted="$rules_deleted$rule;"
    else
      echo "[$LOGTIME] 删除规则时未找到: $rule" | tee -a "$LOG_FILE"
      delete_errors=true
    fi
  done

  if [ "$rules_found" = "true" ]; then
    echo "[$LOGTIME] 删除了以下规则: $rules_deleted" | tee -a "$LOG_FILE"
  fi

  if [ "$delete_errors" = "true" ]; then
    echo "[$LOGTIME] 一些规则未能删除，请检查日志以获取详细信息。" | tee -a "$LOG_FILE"
  fi

  echo "[$LOGTIME] 所有指定规则的删除操作已完成" | tee -a "$LOG_FILE"
}

# 调用函数删除指定规则
remove_specified_rule "$CONFIG_FILE"

append_no_resolve() {
  local config_path=$1
  echo "[$LOGTIME] 正在检查并为需要的 IP-CIDR 规则追加 ',no-resolve'" | tee -a "$LOG_FILE"
  ruby -ryaml -e '
    require "yaml"
    yaml = YAML.load_file(ARGV[0])
    yaml["rules"].each_with_index do |rule, index|
      if (rule.include?("IP-CIDR") || rule.include?("IP-CIDR6")) && !rule.include?("no-resolve")
        original_rule = rule.clone
        updated_rule = rule + ",no-resolve"
        yaml["rules"][index] = updated_rule
        puts "修改前: #{original_rule} 修改后: #{updated_rule}"
      end
    end
    File.open(ARGV[0], "w") { |f| f.write(yaml.to_yaml) }
  ' "$config_path" | while read -r line; do
    echo "[$LOGTIME] $line" | tee -a "$LOG_FILE"
  done
  if [ $? -eq 0 ]; then
    echo "[$LOGTIME] IP-CIDR 规则的检查和更新已完成" | tee -a "$LOG_FILE"
  else
    echo "[$LOGTIME] 在更新 IP-CIDR 规则时发生错误" | tee -a "$LOG_FILE"
  fi
}

# 调用函数为IP-CIDR 规则追加 ',no-resolve'
append_no_resolve "$CONFIG_FILE"

# 为指定 type 的 proxy-groups 项添加自定义参数
append_proxy_groups_custom_params() {
  local config_path=$1
  local type=$2
  shift 2 # 移除前两个参数
  echo "[$LOGTIME] 正在为 type '$type' 的代理组添加自定义参数" | tee -a "$LOG_FILE"

  local found=false
  local error_occurred=0

  if [ $(($# % 2)) -ne 0 ]; then
    echo "[$LOGTIME] 错误：参数应该成对出现。" | tee -a "$LOG_FILE"
    return 1 # 提前返回并指示错误
  fi

  # 使用 Ruby 更新配置文件
  ruby -ryaml -e '
    require "yaml"
    yaml = YAML.load_file(ARGV[0])
    found = false
    output_lines = {}
    yaml["proxy-groups"].each do |group|
      if group["type"] == ARGV[1]
        found = true
        ARGV[2..-1].each_slice(2) do |key, value|
          original_value = group[key]
          group[key] = value =~ /^[0-9]+$/ ? value.to_i : (value =~ /^[0-9]+\.[0-9]+$/ ? value.to_f : (value == "true" || value == "false" ? eval(value) : value))
          if original_value != group[key]
            output_lines[group["name"]] ||= []
            if original_value.nil?
              output_lines[group["name"]] << "已添加 #{key}: #{group[key]}"
            else
              output_lines[group["name"]] << "已更新 #{key}: 从 #{original_value} 修改为 #{group[key]}"
            end
          end
        end
        
        # 重新排序，确保特定的键在 'proxies' 前
        if group.key?("proxies")
          proxies_value = group.delete("proxies")  # 删除并缓存 'proxies'
          group["proxies"] = proxies_value  # 重新插入，确保其在末尾
        end
      end
    end
    puts "没有找到匹配类型的组: #{ARGV[1]}" unless found
    File.open(ARGV[0], "w") { |f| f.write(yaml.to_yaml) }
    
    output_lines.each do |name, lines|
      puts "#{name} (类型: #{ARGV[1]}) " + lines.join(", ")
    end
  ' "$config_path" "$type" "$@" | while read -r line; do
    echo "[$LOGTIME] $line" | tee -a "$LOG_FILE"
  done

  if [ $? -ne 0 ]; then
    echo "[$LOGTIME] 在添加自定义参数时发生错误" | tee -a "$LOG_FILE"
    error_occurred=1
  fi

  if [ $error_occurred -eq 0 ]; then
    echo "[$LOGTIME] 自定义参数的添加已完成" | tee -a "$LOG_FILE"
  else
    echo "[$LOGTIME] 在添加自定义参数时至少发生一次错误" | tee -a "$LOG_FILE"
  fi
}

# 调用函数为指定 type 的 proxy-groups 项添加自定义参数
append_proxy_groups_custom_params "$CONFIG_FILE" "url-test" "lazy" "true" "timeout" "2000" "max-failed-times" "3"
append_proxy_groups_custom_params "$CONFIG_FILE" "load-balance" "lazy" "true" "timeout" "2000" "max-failed-times" "3"
append_proxy_groups_custom_params "$CONFIG_FILE" "fallback" "lazy" "true" "timeout" "2000" "max-failed-times" "3"

#Simple Demo:
    #General Demo
    #1--config path
    #2--key name
    #3--value
    #ruby_edit "$CONFIG_FILE" "['redir-port']" "7892"
    #ruby_edit "$CONFIG_FILE" "['secret']" "123456"
    #ruby_edit "$CONFIG_FILE" "['dns']['enable']" "true"

    #Hash Demo
    #1--config path
    #2--key name
    #3--hash type value
    #ruby_edit "$CONFIG_FILE" "['experimental']" "{'sniff-tls-sni'=>true}"
    ruby_edit "$CONFIG_FILE" "['experimental']" "{'sniff-tls-sni'=>false}"
    #ruby_edit "$CONFIG_FILE" "['sniffer']" "{'sniffing'=>['tls','http']}"

    #Array Demo:
    #1--config path
    #2--key name
    #3--position(start from 0, end with -1)
    #4--value
    #ruby_arr_insert "$CONFIG_FILE" "['dns']['nameserver']" "0" "114.114.114.114"

    #Array Add From Yaml File Demo:
    #1--config path
    #2--key name
    #3--position(start from 0, end with -1)
    #4--value file path
    #5--value key name in #4 file
    #ruby_arr_add_file "$CONFIG_FILE" "['dns']['fallback-filter']['ipcidr']" "0" "/etc/openclash/custom/openclash_custom_fallback_filter.yaml" "['fallback-filter']['ipcidr']"

#Ruby Script Demo:
    #ruby -ryaml -rYAML -I "/usr/share/openclash" -E UTF-8 -e "
    #   begin
    #      Value = YAML.load_file('$CONFIG_FILE');
    #   rescue Exception => e
    #      puts '${LOGTIME} Error: Load File Failed,【' + e.message + '】';
    #   end;

        #General
    #   begin
    #   Thread.new{
    #      Value['redir-port']=7892;
    #      Value['tproxy-port']=7895;
    #      Value['port']=7890;
    #      Value['socks-port']=7891;
    #      Value['mixed-port']=7893;
    #   }.join;

    #   rescue Exception => e
    #      puts '${LOGTIME} Error: Set General Failed,【' + e.message + '】';
    #   ensure
    #      File.open('$CONFIG_FILE','w') {|f| YAML.dump(Value, f)};
    #   end" 2>/dev/null >> $LOG_FILE

exit 0
