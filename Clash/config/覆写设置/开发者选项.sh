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
#ruby_edit "$CONFIG_FILE" "['dns']['proxy-server-nameserver']" "['8.134.187.254:5553']"
#ruby_edit "$CONFIG_FILE" "['dns']['prefer-h3']" "true"
#ruby_edit "$CONFIG_FILE" "['tun']['mtu']" "1500"
ruby_edit "$CONFIG_FILE" "['dns']['cache-algorithm']" "'arc'"


append_no_resolve() {
  local config_path=$1
  echo "[$LOGTIME] 正在检查并为需要的 IP-CIDR 规则追加 ',no-resolve'" | tee -a "$LOG_FILE"
  ruby -ryaml -e '
    require "yaml"
    yaml = YAML.load_file(ARGV[0])
    yaml["rules"].each_with_index do |rule, index|
      if rule.include?("IP-CIDR") && !rule.include?("no-resolve")
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
