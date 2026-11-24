/**
 * Sub-Store sing-box 通用配置模板处理脚本
 *
 * 使用方法：
 * sing-box-template.js#type=组合订阅&name=singbox
 *
 * 支持：
 * 1. 单订阅和组合订阅
 * 2. {all} 自动注入节点
 * 3. filter include / exclude 正则筛选
 * 4. 保留固定节点和代理分组
 * 5. 节点及分组成员自动去重
 * 6. 支持 outbounds 和 endpoints
 * 7. 空分组自动检查
 * 8. 保留其他 sing-box 配置
 */

const args = $arguments || {};

const name = args.name || "singbox";

const type = /^(1|collection|组合订阅|组合)$/i.test(
    args.type || ""
) ? "collection" : "subscription";

const parser = ProxyUtils.JSON5 || JSON;

function log(message) {
    console.log(`[sing-box 模板] ${message}`);
}

// 1. 读取原始配置模板

log("开始读取配置模板");

const config = parser.parse($content ?? $files[0]);

if (!Array.isArray(config.outbounds)) {
    config.outbounds = [];
}

// 2. 获取 Sub-Store 订阅节点

log(`读取订阅：${name}，类型：${type}`);

let data = await produceArtifact({
    name: name,
    type: type,
    platform: "sing-box",
    produceOpts: {
        "include-unsupported-proxy": false
    }
});

if (typeof data === "string") {
    data = JSON.parse(data);
}

const sourceOutbounds = data.outbounds || [];
const sourceEndpoints = data.endpoints || [];

log(`获取出站节点：${sourceOutbounds.length}`);
log(`获取端点节点：${sourceEndpoints.length}`);

// 3. 全局过滤无效的提示节点

const invalidRegex =
    /官网|网站|地址|剩余|流量|套餐|免费|订阅|到期|过期|时间|有效|Expire|Traffic/i;

function isValidProxy(proxy) {
    return proxy &&
        typeof proxy.tag === "string" &&
        proxy.tag.trim() !== "" &&
        !invalidRegex.test(proxy.tag) &&
        !["selector", "urltest", "direct", "block", "dns"]
            .includes(proxy.type);
}

// 4. 收集节点并去重
// 保留模板中原有的配置，避免名称冲突

const usedTags = new Set([
    ...config.outbounds,
    ...(config.endpoints || [])
].map(item => item.tag));

const proxies = [];
const endpoints = [];

function addProxy(source, target) {
    for (const proxy of source) {

        if (!isValidProxy(proxy)) {
            log(`过滤无效节点：${proxy?.tag || "未知"}`);
            continue;
        }

        if (usedTags.has(proxy.tag)) {
            log(`跳过重复或冲突节点：${proxy.tag}`);
            continue;
        }

        usedTags.add(proxy.tag);
        target.push(proxy);
    }
}

addProxy(sourceOutbounds, proxies);
addProxy(sourceEndpoints, endpoints);

const allProxies = [...proxies, ...endpoints];

if (allProxies.length === 0) {
    throw new Error("订阅中没有可用代理节点，停止生成配置");
}

log(`有效代理节点：${allProxies.length}`);

// 5. 根据模板内的 filter 进行节点筛选

function filterProxies(source, filters, groupTag) {

    let result = [...source];

    if (!filters) {
        return result;
    }

    if (!Array.isArray(filters)) {
        throw new Error(`分组 ${groupTag} 的 filter 格式错误`);
    }

    for (const filter of filters) {

        const action = filter.action;

        const keywords = filter.keywords || [];

        if (!["include", "exclude"].includes(action)) {
            throw new Error(
                `分组 ${groupTag} 存在未知筛选操作：${action}`
            );
        }

        if (!Array.isArray(keywords)) {
            throw new Error(
                `分组 ${groupTag} 的 keywords 格式错误`
            );
        }

        if (keywords.length === 0) {
            continue;
        }

        const regexList = keywords.map(keyword => {
            return new RegExp(keyword, "i");
        });

        function match(proxy) {
            return regexList.some(regex => regex.test(proxy.tag));
        }

        if (action === "include") {
            result = result.filter(match);
        }

        if (action === "exclude") {
            result = result.filter(proxy => !match(proxy));
        }
    }

    return result;
}

// 6. 处理 selector 和 urltest 分组

for (const group of config.outbounds) {

    if (!["selector", "urltest"].includes(group.type)) {
        continue;
    }

    const original = Array.isArray(group.outbounds)
        ? group.outbounds
        : [];

    const hasAll = original.includes("{all}");

    if (hasAll) {

        const selected = filterProxies(
            allProxies,
            group.filter,
            group.tag
        );

        const selectedTags = selected.map(proxy => proxy.tag);

        // 替换 {all}，保留其他固定分组和节点
        const members = original.flatMap(tag => {
            return tag === "{all}" ? selectedTags : [tag];
        });

        group.outbounds = [...new Set(members)];

    } else {

        group.outbounds = [...new Set(original)];

    }

    // 删除 sing-box 不支持的模板扩展字段
    delete group.filter;

    log(`${group.tag}：${group.outbounds.length} 个成员`);
}

// 7. 合并真实代理节点

config.outbounds.push(...proxies);

if (endpoints.length > 0) {

    if (!Array.isArray(config.endpoints)) {
        config.endpoints = [];
    }

    config.endpoints.push(...endpoints);
}

// 8. 检查空分组

const allTags = allProxies.map(proxy => proxy.tag);

for (const group of config.outbounds) {

    if (!["selector", "urltest"].includes(group.type)) {
        continue;
    }

    if (group.outbounds.length === 0) {

        // 使用全部有效代理节点兜底，避免意外直连
        group.outbounds = [...allTags];

        log(`警告：${group.tag} 无匹配节点，使用全部代理节点兜底`);
    }
}

// 9. 检查分组引用是否存在

const validTags = new Set([
    ...config.outbounds,
    ...(config.endpoints || [])
].map(item => item.tag));

for (const group of config.outbounds) {

    if (!["selector", "urltest"].includes(group.type)) {
        continue;
    }

    for (const tag of group.outbounds) {

        if (!validTags.has(tag)) {
            throw new Error(
                `分组 ${group.tag} 引用了不存在的节点：${tag}`
            );
        }

        if (tag === group.tag) {
            throw new Error(
                `分组 ${group.tag} 存在自身循环引用`
            );
        }
    }
}

// 10. 输出完整 sing-box 配置

$content = JSON.stringify(config, null, 2);

log("配置生成完成");
log(`代理节点：${proxies.length}`);
log(`端点节点：${endpoints.length}`);
log(`出站配置总数：${config.outbounds.length}`);
