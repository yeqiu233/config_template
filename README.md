## Linux相关脚本：
-  [个人所能用到的，包括定时，NAT，alist降级等脚本](https://gh-proxy.com/https://github.com/yeqiu233/config_template/blob/main/Linux.md) 

## 适配配置文件：

### singbox稳定版(1.14.X)：  

tun-dx：  
https://gh-proxy.com/https://github.com/yeqiu233/config_template/blob/main/singbox/1.14.x/config_tun_dx.json

tun-lt：  
https://gh-proxy.com/https://github.com/yeqiu233/config_template/blob/main/singbox/1.14.x/config_tun_lt.json

tun-lmy：  
https://gh-proxy.com/https://github.com/yeqiu233/config_template/blob/main/singbox/1.14.x/config_tun_lmy.json

### mihomo所有支持mihomo内核客户端版本通用：  

https://gh-proxy.com/https://github.com/yeqiu233/config_template/blob/main/mihomo/config.yaml

## 一键安装singbox内核管理工具


### 输入一下命令安装
```
curl -4 -fsSL --connect-timeout 5 --max-time 60 https://gh-proxy.com/https://raw.githubusercontent.com/yeqiu233/config_template/main/sb.sh -o /root/sb.sh && bash -n /root/sb.sh && bash /root/sb.sh --install && source /etc/profile.d/sb.sh
```