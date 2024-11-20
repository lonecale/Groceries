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
#ruby_edit "$CONFIG_FILE" "['dns']['cache-algorithm']" "'arc'"
ruby_edit "$CONFIG_FILE" "['disable-keep-alive']" "false"
ruby_edit "$CONFIG_FILE" "['keep-alive-interval']" "600"
ruby_edit "$CONFIG_FILE" "['keep-alive-idle']" "600"

# 定义要删除的规则，使用一个字符串变量
rules_to_remove="DOMAIN-SUFFIX,cloudfront.net,🎬 EmbyProxy"
# rules_to_remove="DOMAIN-SUFFIX,aaa.net,🎬 EmbyProxy;DOMAIN-SUFFIX,bbb.net,🎬 EmbyProxy;"


# 删除规则文件指定规则
check_and_remove_specified_rules() {
  local rule_dir=$1
  echo "[$LOGTIME] 正在检查目录 $rule_dir 中的规则文件" | tee -a "$LOG_FILE"

  # 遍历目录下所有的 yaml 和 txt 文件
  for file in "$rule_dir"/*.yaml "$rule_dir"/*.txt; do
    if [ -f "$file" ]; then
      local filename=$(basename "$file")
      local file_modified=false

      # 循环处理每个规则
      echo "$rules_to_remove" | tr ';' '\n' | while IFS= read -r rule; do
        if grep -qF "$rule" "$file"; then
          echo "[$LOGTIME] 在文件 $filename 发现并正在删除规则 '$rule'..." | tee -a "$LOG_FILE"
          sed -i "/$rule/d" "$file"
          file_modified=true
        fi
      done

      if [ "$file_modified" = true ]; then
        echo "[$LOGTIME] 文件 $filename 的规则已删除。" | tee -a "$LOG_FILE"
      fi
    fi
  done

  echo "[$LOGTIME] 检查并修改操作完成" | tee -a "$LOG_FILE"
}

# 调用函数删除规则文件指定规则
check_and_remove_specified_rules "/etc/openclash/rule_provider"

# 删除配置文件指定规则
remove_specified_rule() {
  local config_path=$1
  echo "[$LOGTIME] 正在检查并删除指定的规则" | tee -a "$LOG_FILE"

  ruby -ryaml -e '
    require "yaml"
    yaml = YAML.load_file(ARGV[0])
    rules_to_remove = ARGV[1].split(";")
    rules_found = false
    rules_to_remove.each do |rule|
      original_size = yaml["rules"].size
      yaml["rules"].delete_if { |r| r == rule }
      if yaml["rules"].size < original_size
        puts "成功删除规则: #{rule}"
        rules_found = true
      else
        puts "没有找到需要删除的规则: #{rule}"
      end
    end
    File.open(ARGV[0], "w") { |f| f.write(yaml.to_yaml) } if rules_found
  ' "$config_path" "$rules_to_remove" | while read -r line; do
    echo "[$LOGTIME] $line" | tee -a "$LOG_FILE"
  done

  # 使用 $? 来判断 Ruby 脚本执行是否成功
  if [ $? -ne 0 ]; then
    echo "[$LOGTIME] 在删除规则时发生错误，请检查日志。" | tee -a "$LOG_FILE"
  else
    echo "[$LOGTIME] 所有指定规则的删除操作已完成，没有错误。" | tee -a "$LOG_FILE"
  fi
}

# 调用函数删除配置文件指定规则
remove_specified_rule "$CONFIG_FILE"

# 检查规则文件 为IP-CIDR 规则追加no-resolve
check_and_append_no_resolve() {
    local rule_dir=$1
    echo "[$LOGTIME] 正在检查目录 $rule_dir 中的规则文件" | tee -a "$LOG_FILE"
    
    # 列出并处理所有 yaml 和 txt 文件
    for file in "$rule_dir"/*.yaml "$rule_dir"/*.txt; do
        if [ -f "$file" ]; then
            local filename=$(basename "$file")
            
            local changes=$(sed -n '/^[^#]*\(IP-CIDR\|IP-CIDR6\)/ { /no-resolve/!p }' "$file")
            if [ -n "$changes" ]; then
                echo "正在处理文件: $filename" | tee -a "$LOG_FILE"

                # 记录修改前的行
                sed -n '/^[^#]*\(IP-CIDR\|IP-CIDR6\)/ { /no-resolve/!p }' "$file" | awk -v filename="$filename" '{print filename ":" NR " 修改前: " $0}' | tee -a "$LOG_FILE"

                # 执行就地修改并标记
                sed -i -E '/^[^#]*(IP-CIDR|IP-CIDR6)/ {
                    /no-resolve([ ]*#|$)/! {
                        # 添加no-resolve，并在其后添加NEED_RESOLVE标记，同时处理注释前的空格
                        s/([ ]*)(#[^#]*)?$/,no-resolve\1\2 #NEED_RESOLVE/;
                        # 如果存在注释且注释前无空格，则确保添加一个空格
                        s/(no-resolve)(#)/\1 \2/;
                        # 如果存在注释且注释前有空格，则保持这些空格
                        s/(no-resolve)([ ]+)(#)/\1\2\3/;
                    }
                }' "$file"


                # 记录修改后的行，同时去除 #NEED_RESOLVE 标记
                sed -n '/#NEED_RESOLVE$/p' "$file" | awk -v filename="$filename" '{sub(/ #NEED_RESOLVE$/, ""); print filename ":" NR " 修改后: " $0}' | tee -a "$LOG_FILE"
                # 移除所有的 #NEED_RESOLVE 标记
                sed -i 's/ #NEED_RESOLVE//' "$file"
                
                echo "文件 $filename 已更新。" | tee -a "$LOG_FILE"
            fi
        fi
    done

    echo "[$LOGTIME] 检查并修改操作完成" | tee -a "$LOG_FILE"
}

# 调用函数为规则文件的IP-CIDR 规则追加 ',no-resolve'
check_and_append_no_resolve "/etc/openclash/rule_provider"


# 检查配置文件 为IP-CIDR 规则追加no-resolve
append_no_resolve() {
  local config_path=$1
  echo "[$LOGTIME] 正在检查并为需要的 IP-CIDR 规则追加 ',no-resolve'" | tee -a "$LOG_FILE"
  
  ruby -ryaml -e '
    require "yaml"
    yaml = YAML.load_file(ARGV[0])
    need_update = false
    yaml["rules"].each_with_index do |rule, index|
      if (rule.include?("IP-CIDR") || rule.include?("IP-CIDR6")) && !rule.include?("no-resolve")
        original_rule = rule.clone
        updated_rule = rule + ",no-resolve"
        yaml["rules"][index] = updated_rule
        puts "修改前: #{original_rule} 修改后: #{updated_rule}"
        need_update = true
      end
    end

    File.open(ARGV[0], "w") { |f| f.write(yaml.to_yaml) } if need_update
  ' "$config_path" | while read -r line; do
    echo "[$LOGTIME] $line" | tee -a "$LOG_FILE"
  done
  
  if [ $? -eq 0 ]; then
    echo "[$LOGTIME] IP-CIDR 规则的检查和更新已完成" | tee -a "$LOG_FILE"
  else
    echo "[$LOGTIME] 在更新 IP-CIDR 规则时发生错误" | tee -a "$LOG_FILE"
  fi
}

# 调用函数为配置文件的IP-CIDR 规则追加 ',no-resolve'
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
