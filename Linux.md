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
### 脚本列表
- alist：alist脚本管理，支持降级
- backup：服务器数据自动备份
- Debian：服务器源相关修改
- ds：定时管理脚本
- nat：设置服务器nat管理脚本