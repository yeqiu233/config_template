# 仓库声明：
⚠️⚠️singbox与mihomo自用配置远程同步与调用仓库，仅供个人使用⚠️⚠️  
配置文件从1.12.X版本开始配置文件大幅度改动与1.11.X以及以下版本不通用

## Linux操作说明：

### nat脚本
- 创建一个/usr/local/bin/nat文件，将nat的内容粘贴进去，或者用SFTP工具直接拖进去
- 赋予可执行权限，之后在SSH终端输入nat命令即可调用
```
# 创建脚本文件
nano /usr/local/bin/nat

# 粘贴上面的脚本内容
# 按 Ctrl+X，然后按 Y 保存

# 赋予执行权限
chmod +x /usr/local/bin/nat

# 使用脚本
nat
```

### 定时脚本
- 创建一个/usr/local/bin/ds文件，将nds的内容粘贴进去，或者用SFTP工具直接拖进去
- 赋予可执行权限，之后在SSH终端输入ds命令即可调用
```
# 创建脚本文件
nano /usr/local/bin/ds

# 粘贴上面的脚本内容
# 按 Ctrl+X，然后按 Y 保存

# 赋予执行权限
chmod +x /usr/local/bin/ds

# 使用脚本
ds
```

## 适配配置文件：

### singbox稳定版(1.11.X)：  
tproxy通用模式：  
https://gh-proxy.com/https://github.com/yeqiu233/config_template/blob/main/singbox/1.11.X/config_tproxy.json

tun通用模式：  
https://gh-proxy.com/https://github.com/yeqiu233/config_template/blob/main/singbox/1.11.X/config_tun.json

tun电信模式，解决电信屏蔽联通IP的问题：  
https://gh-proxy.com/https://github.com/yeqiu233/config_template/blob/main/singbox/1.11.X/config_tun_dianxin.json  

tun-lmy朋友专属优化设置：  
https://gh-proxy.com/https://github.com/yeqiu233/config_template/blob/main/singbox/1.11.X/config_tun_lmy.json

tun测试版（非正式不要乱用）：  
https://gh-proxy.com/https://github.com/yeqiu233/config_template/blob/main/singbox/1.11.X/config_ceshi.json

### singbox测试版(1.12.X)：  
tun适应开发板紧随版本更新，尝鲜专用：  
https://gh-proxy.com/https://github.com/yeqiu233/config_template/blob/main/singbox/1.12.X/config_tun_1.12.json

### mihomo所有支持mihomo内核客户端版本通用：  

https://gh-proxy.com/https://github.com/yeqiu233/config_template/blob/main/mihomo/config.yaml
