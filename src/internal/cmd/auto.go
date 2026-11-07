package cmd

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"RealityChecker/internal/adaptive"
	"RealityChecker/internal/app"
	"RealityChecker/internal/asn"
	"RealityChecker/internal/config"
	"RealityChecker/internal/core"
	"RealityChecker/internal/data"
	"RealityChecker/internal/logger"
	"RealityChecker/internal/scanner"
	"RealityChecker/internal/storage"
	"RealityChecker/internal/types"
	"RealityChecker/internal/version"

	"github.com/oschwald/geoip2-golang"
	"github.com/schollz/progressbar/v3"
)

// CalculateTotalIPs 计算一组 CIDR 或单 IP 的总数量（转发至 core.CalculateTotalIPs）
func CalculateTotalIPs(cidrs []string) int64 {
	return core.CalculateTotalIPs(cidrs)
}

// CalculateRemainingIPs 计算扣除已完成/部分完成断点网段后的剩余待扫描 IP 理论总数（转发至 core.CalculateRemainingIPs）
func CalculateRemainingIPs(cidrs []string, checkpoints map[string]*storage.CheckpointRecord) int64 {
	return core.CalculateRemainingIPs(cidrs, checkpoints)
}
// AutoScanCLIOptions 自动扫描命令行的参数配置
type AutoScanCLIOptions struct {
	CIDRs            []string
	MaxTargets       int
	CheckAll         bool
	ExportFile       string
	Filter           types.FilterConfig
	ASN              string
	Country          string
	Scope            string // 本次 pass 的来源标签（同 ASN / 同地区 xx），仅用于日志
	NoRegionFallback bool   // 禁用「同 ASN 无结果 → 同地区」回退
	RegionASNs       int    // 同地区回退最多尝试的 ASN 个数
	InitialResults   []*types.DetectionResult
	Verbose          bool
}
// executeAutoPass 执行单次扫描 pass：网络扫描 + 检测 + 入库，不含最终表格渲染与导出
func (r *RootCmd) executeAutoPass(opts AutoScanCLIOptions) (*core.AutoScanResult, error) {
	if len(opts.CIDRs) == 0 {
		return nil, core.ErrNoCIDRsProvided
	}
	if opts.Scope != "" {
		logger.PrintTimestampedMessage("—— 本阶段扫描范围：%s ——", opts.Scope)
	}

	if r.config != nil && r.config.Proxy.Scanner && r.config.Proxy.URL != "" {
		logger.PrintTimestampedMessage("⚠️ 提示: 网络扫描已启用代理通道 [%s] (测速与握手延迟将包含代理链路耗时)", r.config.Proxy.URL)
	}

	// 1. 初始化统一应用依赖容器
	container, err := app.NewContainer(app.ContainerOptions{
		Config: r.config,
	})
	if err != nil {
		logger.PrintError(fmt.Sprintf("初始化应用容器失败: %v", err))
		return nil, fmt.Errorf("初始化应用容器失败: %w", err)
	}
	defer container.Close()

	scannerEngine := container.GetScanner()
	targetStore, err := container.GetStore()
	if err != nil {
		logger.PrintTimestampedMessage("⚠️ 本地资产数据库初始化失败: %v (将使用内存模式)", err)
	}

	taskKey := ""
	if opts.ASN != "" && opts.Country != "" {
		taskKey = fmt.Sprintf("%s_%s", opts.ASN, opts.Country)
	}

	grandTotalIPCount := core.CalculateTotalIPs(opts.CIDRs)
	var checkpointsMap map[string]*storage.CheckpointRecord
	if opts.CheckAll && targetStore != nil && taskKey != "" && !opts.Filter.NoResume {
		checkpointsMap, _ = targetStore.GetCheckpoints(taskKey)
	}
	remainingIPCount := core.CalculateRemainingIPs(opts.CIDRs, checkpointsMap)
	alreadyScannedIPCount := grandTotalIPCount - remainingIPCount

	var bar *progressbar.ProgressBar
	if !opts.Verbose {
		bar = progressbar.NewOptions64(grandTotalIPCount,
			progressbar.OptionEnableColorCodes(true),
			progressbar.OptionShowCount(),
			progressbar.OptionSetWidth(25),
			progressbar.OptionSetDescription("[cyan][扫描中...][reset]"),
			progressbar.OptionUseANSICodes(true),
			progressbar.OptionSetTheme(progressbar.Theme{
				Saucer:        "[green]=[reset]",
				SaucerHead:    "[green]>[reset]",
				SaucerPadding: " ",
				BarStart:      "[",
				BarEnd:        "]",
			}),
		)
		if alreadyScannedIPCount > 0 {
			_ = bar.Set64(alreadyScannedIPCount)
		}
	}

	logger.PrintTimestampedMessage("开启内嵌自动化扫描与检测模式 (Native Engine)...")
	if opts.Verbose {
		logger.PrintTimestampedMessage("模式: 详细记录模式 (-v / --verbose)，将实时输出每一条 IP 探测与判定记录到标准输出")
	}
	if opts.CheckAll {
		logger.PrintTimestampedMessage("模式: 全量摸底扫描 (--check-all)，将收集并存档所有合规资产入库")
	}

	nonDefaults := formatNonDefaultFilters(opts.Filter)
	if len(nonDefaults) > 0 {
		logger.PrintTimestampedMessage("检测到自定义非默认过滤条件: [%s]", strings.Join(nonDefaults, ", "))
	} else {
		logger.PrintTimestampedMessage("应用 REALITY 选型策略: [全部使用推荐默认值]")
	}

	logger.PrintTimestampedMessage("待扫描网段总数: %d 个。排序如下:", len(opts.CIDRs))
	for i, c := range opts.CIDRs {
		if i < 5 {
			fmt.Printf("  [%d] %s\n", i+1, c)
		}
	}
	if len(opts.CIDRs) > 5 {
		fmt.Printf("  ...以及其余 %d 个网段\n", len(opts.CIDRs)-5)
	}

	var lastUpdate time.Time
	var updateMu sync.Mutex

	events := core.AutoScanEvents{
		OnIPScanned: func(delta int, currentCIDR string, currentIP string, currentIdx int, totalCIDRs int) {
			if bar != nil {
				_ = bar.Add(delta)
				updateMu.Lock()
				if time.Since(lastUpdate) > 150*time.Millisecond {
					lastUpdate = time.Now()
					bar.Describe(fmt.Sprintf("[cyan][网段 %d/%d: %s | 探测: %s][reset]", currentIdx, totalCIDRs, currentCIDR, currentIP))
				}
				updateMu.Unlock()
			}
		},
		OnScanRecord: func(probe *scanner.ProbeResult) {
			if !opts.Verbose || probe == nil {
				return
			}
			if !probe.Success {
				logger.PrintTimestampedMessage("[-] %-15s:%-4d | 探活失败: %s", probe.IP, probe.Port, probe.FailureReason)
			} else {
				logger.PrintTimestampedMessage("[+] %-15s:%-4d | 握手成功: 提取域名 %s (ALPN: %s, 套件: %s)",
					probe.IP, probe.Port, probe.Result.CertDomain, probe.Result.ALPN, probe.Result.Curve)
			}
		},
		OnCandidateRejected: func(ip string, domain string, reason string) {
			if !opts.Verbose {
				return
			}
			logger.PrintTimestampedMessage("[~] %-15s      | 域名未入选: %-25s | 原因: %s", ip, domain, reason)
		},
		OnCandidateDiscovered: func(ip string, domain string) {
			logger.Info("🔎 扫描发现候选域名: %s (IP: %s)", domain, ip)
		},
		OnAdaptiveAdjust: func(stats adaptive.LimiterStats) {
			if bar != nil {
				logger.AboveBar(bar, "⚡ [算力与网络自适应] %s", stats.LastActionReason)
			} else {
				logger.PrintTimestampedMessage("⚡ [算力与网络自适应] %s", stats.LastActionReason)
			}
		},
		OnTargetFound: func(res *types.DetectionResult, count int, ip string, handshakeMs int64, statusCode int) {
			if bar != nil {
				timestamp := time.Now().Format("15:04:05")
				logger.AboveBar(bar, "[%s]  [扫描到第%d个符合条件的目标] %-35s (IP: %s, 握手: %dms, 页面: %d)\n",
					timestamp, count, res.Domain, ip, handshakeMs, statusCode)
			} else {
				stars := core.CalculateTargetStars(res)
				starStr := strings.Repeat("★", stars) + strings.Repeat("☆", 5-stars)
				logger.PrintTimestampedMessage("🎯 [%-15s:%-4d] 命中优质目标 [%d]: %-25s | 握手: %3dms | 状态: %3d | 推荐: %s",
					ip, 443, count, res.Domain, handshakeMs, statusCode, starStr)
			}
		},
		OnLimitHit: func(maxTargets int) {
			logger.PrintTimestampedMessage("已达到设定的目标数量限制 (%d 个)，即刻刹车并停止扫描...", maxTargets)
		},
		OnCIDRScanStart: func(currentIdx int, totalCIDRs int, cidr string, resumeIP string) {
			if bar != nil {
				if resumeIP != "" {
					logger.AboveBar(bar, "[%d/%d] 正在并发扫描网段: %s (从断点 IP: %s 继续)...", currentIdx, totalCIDRs, cidr, resumeIP)
				} else {
					logger.AboveBar(bar, "[%d/%d] 正在并发扫描网段: %s ...", currentIdx, totalCIDRs, cidr)
				}
			} else {
				if resumeIP != "" {
					logger.PrintTimestampedMessage("[%d/%d] 正在并发扫描网段: %s (从断点 IP: %s 继续)...", currentIdx, totalCIDRs, cidr, resumeIP)
				} else {
					logger.PrintTimestampedMessage("[%d/%d] 正在并发扫描网段: %s ...", currentIdx, totalCIDRs, cidr)
				}
			}
		},
		OnLog: func(msg string) {
			logger.PrintTimestampedMessage("%s", msg)
		},
	}

	scannerCore := core.NewAutoScanner(
		r.engine,
		targetStore,
		scannerEngine,
		core.AutoScanConfig{
			CIDRs:          opts.CIDRs,
			MaxTargets:     opts.MaxTargets,
			CheckAll:       opts.CheckAll,
			Filter:         opts.Filter,
			ASN:            opts.ASN,
			Country:        opts.Country,
			InitialResults: opts.InitialResults,
			Verbose:        opts.Verbose,
		},
		events,
	)

	res, err := scannerCore.Run(r.ctx)
	fmt.Println()

	if err != nil {
		if errors.Is(err, core.ErrAllCompleted) {
			logger.PrintTimestampedMessage("✅ 全量摸排任务 (%s) 的所有网段此前已全部扫描完成！如需重新全量扫描请指定 --reset-scan", taskKey)
		}
		return nil, err
	}

	return res, nil
}

// reportAutoResults 导出候选资产池并渲染最终结果表
func (r *RootCmd) reportAutoResults(opts AutoScanCLIOptions, results []*types.DetectionResult, rawPool []*types.DetectionResult, interrupted bool) {
	if opts.ExportFile != "" && len(rawPool) > 0 {
		exportPool := &types.CandidatePool{
			CreatedAt: time.Now(),
			Source:    fmt.Sprintf("%s (%s)", opts.ASN, opts.Country),
			Targets:   rawPool,
		}
		if payload, err := json.MarshalIndent(exportPool, "", "  "); err == nil {
			_ = os.WriteFile(opts.ExportFile, payload, 0644)
			logger.PrintTimestampedMessage("已将本次摸排发现的 %d 个候选资产导出至: %s", len(rawPool), opts.ExportFile)
		}
	}

	if interrupted {
		if len(results) > 0 {
			r.batchManager.SortByRecommendationStars(results)
			fmt.Println("\n中断前已发现的适合域名:")
			fmt.Println(r.batchManager.FormatSuitableTable(results))
		}
		return
	}

	logger.PrintTimestampedMessage("扫描与检测完成！共找到 %d 个符合策略的优质 REALITY 目标域名（技术基线合格总数: %d）。",
		len(results), len(rawPool))

	if len(results) > 0 {
		r.batchManager.SortByRecommendationStars(results)
		fmt.Println("\n适合的域名:")
		fmt.Println(r.batchManager.FormatSuitableTable(results))
	}
}

// executeAuto 编排一次完整的自动扫描：先扫入口 ASN，未达标时回退同地区（同国家）的其它 ASN
func (r *RootCmd) executeAuto(opts AutoScanCLIOptions) {
	res, err := r.executeAutoPass(opts)
	if err != nil {
		switch {
		case errors.Is(err, core.ErrNoCIDRsProvided):
			logger.PrintError("错误：未提供有效的 CIDR 扫描网段")
		case errors.Is(err, core.ErrAllCompleted):
			return
		default:
			logger.PrintError(fmt.Sprintf("扫描失败: %v", err))
		}
		return
	}
	if res == nil {
		return
	}

	if res.IsInterrupted {
		logger.PrintTimestampedMessage("扫描已响应用户中断 (Ctrl+C) 并安全退出。")
		if opts.CheckAll {
			logger.PrintTimestampedMessage("💡 已自动保存当前网段与当前 IP 扫描断点进度，再次运行时将无缝续传。")
		}
		r.reportAutoResults(opts, res.SuitableResults, res.RawCandidatePool, true)
		return
	}

	results := res.SuitableResults
	rawPool := res.RawCandidatePool

	if r.shouldRunRegionFallback(opts, len(results)) {
		extraResults, extraRaw := r.runRegionFallback(opts, results)
		results = append(results, extraResults...)
		rawPool = append(rawPool, extraRaw...)
	}

	r.reportAutoResults(opts, results, rawPool, false)
}

// shouldRunRegionFallback 判断是否需要进入同地区回退
func (r *RootCmd) shouldRunRegionFallback(opts AutoScanCLIOptions, found int) bool {
	if opts.NoRegionFallback || opts.CheckAll || opts.MaxTargets <= 0 {
		return false
	}
	if strings.TrimSpace(opts.Country) == "" {
		return false
	}
	return found < opts.MaxTargets
}

// runRegionFallback 同 ASN 扫不到足够目标时回退到「同地区 = 同国家」：
// 先复核本地资产库里同国家的历史资产，再扩展到 ASN 注册表里同国家的其它 ASN。
func (r *RootCmd) runRegionFallback(opts AutoScanCLIOptions, existing []*types.DetectionResult) ([]*types.DetectionResult, []*types.DetectionResult) {
	country := strings.ToUpper(strings.TrimSpace(opts.Country))
	logger.PrintTimestampedMessage("🛰 同 ASN 仅命中 %d/%d 个目标，回退同地区（%s）继续寻找...", len(existing), opts.MaxTargets, country)

	var results []*types.DetectionResult
	var rawPool []*types.DetectionResult

	var store storage.Store
	if s, err := initStore("", r.config); err != nil {
		logger.PrintTimestampedMessage("⚠️ 本地资产库不可用（%v），同地区回退将仅依赖 ASN 前缀在线查询", err)
	} else {
		store = s
		defer store.Close()
	}

	// 第一层：本地资产库中同国家的历史资产
	if store != nil {
		maxAge := time.Duration(opts.Filter.CacheMaxDays) * 24 * time.Hour
		if records, err := store.GetTargetsByCountry(country, maxAge); err != nil {
			logger.PrintTimestampedMessage("⚠️ 读取同国家历史资产失败: %v", err)
		} else if len(records) > 0 {
			logger.PrintTimestampedMessage("♻️ 同国家历史资产 %d 条，按当前策略复核...", len(records))
			for _, rec := range records {
				if len(existing)+len(results) >= opts.MaxTargets {
					break
				}
				if rec == nil || !ipFamilyAllowed(rec.IP, opts.Filter) {
					continue
				}
				res := storage.RecordToDetectionResult(rec)
				if res == nil || domainAlreadyCollected(existing, results, res.Domain) {
					continue
				}
				if passed, _ := core.FilterTarget(res, opts.Filter); passed {
					results = append(results, res)
				}
			}
		}
	}

	// 第二层：ASN 注册表中同国家的其它 ASN
	if len(existing)+len(results) >= opts.MaxTargets {
		return results, rawPool
	}
	regionASNs := r.listRegionASNs(store, country, opts.ASN, opts.RegionASNs)
	if len(regionASNs) == 0 {
		logger.PrintTimestampedMessage("ℹ️ ASN 注册表里没有 %s 的其它可用 ASN（可先同步 ASN 注册表或换 --country），同地区回退结束", country)
		return results, rawPool
	}

	for _, rec := range regionASNs {
		remaining := opts.MaxTargets - len(existing) - len(results)
		if remaining <= 0 {
			break
		}
		asnStr := fmt.Sprintf("AS%d", rec.ASN)
		cidrs := r.regionCIDRs(asnStr, country, opts.Filter)
		if len(cidrs) == 0 {
			continue
		}
		passOpts := opts
		passOpts.ASN = asnStr
		passOpts.CIDRs = cidrs
		passOpts.MaxTargets = remaining
		passOpts.CheckAll = false
		passOpts.ExportFile = ""
		passOpts.Scope = fmt.Sprintf("同地区 %s / %s", country, asnStr)
		passOpts.InitialResults = append(append([]*types.DetectionResult{}, existing...), results...)

		passRes, err := r.executeAutoPass(passOpts)
		if err != nil {
			if errors.Is(err, core.ErrAllCompleted) {
				continue
			}
			logger.PrintTimestampedMessage("⚠️ %s 同地区扫描失败: %v", asnStr, err)
			continue
		}
		if passRes == nil {
			continue
		}
		results = append(results, passRes.SuitableResults...)
		rawPool = append(rawPool, passRes.RawCandidatePool...)
		if passRes.IsInterrupted {
			return results, rawPool
		}
	}

	return results, rawPool
}

// listRegionASNs 从 ASN 注册表取同国家的其它 ASN（排除入口 ASN 与纯 CDN），按优先级降序取前 limit 个
func (r *RootCmd) listRegionASNs(store storage.Store, country, entryASN string, limit int) []*types.ASNRecord {
	if limit <= 0 {
		limit = 5
	}
	if store == nil {
		return nil
	}
	if _, err := asn.NewRegistryManager(store, 15*time.Second).EnsureRegistrySeeded(); err != nil {
		logger.PrintTimestampedMessage("⚠️ ASN 注册表初始化失败: %v", err)
	}
	records, err := store.ListASNs("", 0, 500, 0)
	if err != nil {
		logger.PrintTimestampedMessage("⚠️ 读取 ASN 注册表失败: %v", err)
		return nil
	}

	entry := strings.ToUpper(strings.TrimSpace(entryASN))
	entryNum := strings.TrimPrefix(entry, "AS")

	var picked []*types.ASNRecord
	for _, rec := range records {
		if rec == nil {
			continue
		}
		if !strings.EqualFold(strings.TrimSpace(rec.Country), country) {
			continue
		}
		if entry != "" && (strconv.Itoa(rec.ASN) == entryNum) {
			continue
		}
		if rec.Priority <= 0 {
			continue // 纯 CDN 或已判定无价值的种子
		}
		if isCDN, _ := asn.IsPureCDNASN(rec.ASN, rec.Name); isCDN {
			continue
		}
		picked = append(picked, rec)
	}

	sort.SliceStable(picked, func(i, j int) bool { return picked[i].Priority > picked[j].Priority })
	if len(picked) > limit {
		picked = picked[:limit]
	}
	return picked
}

// regionCIDRs 查询某个 ASN 的宣布前缀，筛出同国家且符合协议族限制的网段
func (r *RootCmd) regionCIDRs(asnStr, country string, filter types.FilterConfig) []string {
	prefixes, err := asn.NewClient(15*time.Second).FetchPrefixes(r.ctx, asnStr)
	if err != nil {
		logger.PrintTimestampedMessage("⚠️ %s 前缀查询失败: %v", asnStr, err)
		return nil
	}

	reader, err := data.OpenGeoIPReader("data/Country.mmdb", "Country.mmdb")
	if err != nil {
		reader = nil
	} else {
		defer reader.Close()
	}

	cidrs, _ := filterPrefixesByCountry(prefixes, reader, country, filter)
	if len(cidrs) == 0 {
		// 同国家判定失败时放宽国家限制，只保留协议族（IPv6 段归属常与入口国不同）
		cidrs = filterPrefixesByFamily(prefixes, filter)
	}
	return cidrs
}

// domainAlreadyCollected 判断域名是否已在既有结果中，避免同地区回退重复输出
func domainAlreadyCollected(existing, current []*types.DetectionResult, domain string) bool {
	if domain == "" {
		return true
	}
	for _, list := range [][]*types.DetectionResult{existing, current} {
		for _, res := range list {
			if res != nil && strings.EqualFold(res.Domain, domain) {
				return true
			}
		}
	}
	return false
}

// ipFamilyAllowed 判断资产 IP 是否符合 --ipv4-only / --ipv6-only 限制
func ipFamilyAllowed(ipStr string, filter types.FilterConfig) bool {
	if !filter.IPv4Only && !filter.IPv6Only {
		return true
	}
	addr, err := netip.ParseAddr(strings.TrimSpace(ipStr))
	if err != nil {
		return true
	}
	if filter.IPv4Only {
		return addr.Is4()
	}
	return addr.Is6()
}

// filterRecordsByFamily 缓存快速通道同样必须遵守 --ipv4-only / --ipv6-only
func filterRecordsByFamily(records []*types.TargetRecord, filter types.FilterConfig) []*types.TargetRecord {
	if !filter.IPv4Only && !filter.IPv6Only {
		return records
	}
	out := make([]*types.TargetRecord, 0, len(records))
	for _, rec := range records {
		if rec != nil && ipFamilyAllowed(rec.IP, filter) {
			out = append(out, rec)
		}
	}
	return out
}

func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}
	return false
}

// warnEgressMismatch 在"扫描目标属于中国大陆网段、但本机出口不在 CN"时提示视角失真。
// 非 CN 出口本身并不构成阻断：只有目标在 CN 段时，握手延迟才需要国内客户端视角才有参考价值。
func (r *RootCmd) warnEgressMismatch(targetInput, inFile, countryStr string) {
	if r.egress == nil || !r.egress.Known || r.egress.IsCN {
		return
	}

	targetCN := strings.EqualFold(strings.TrimSpace(countryStr), "CN")
	if !targetCN {
		// countryStr 为空（文件批量 / CIDR 直扫）时，用 GeoIP 反查入口 IP 的归属
		if targetInput != "" && inFile == "" && !strings.Contains(targetInput, "/") {
			if ip := net.ParseIP(targetInput); ip != nil {
				if reader, err := data.OpenGeoIPReader("data/Country.mmdb", "Country.mmdb"); err == nil {
					if rec, err := reader.Country(ip); err == nil && rec != nil {
						targetCN = strings.EqualFold(rec.Country.IsoCode, "CN")
					}
					reader.Close()
				}
			}
		}
	}
	if !targetCN {
		return
	}

	logger.PrintTimestampedMessage("⚠️ 视角提示：当前出口为 %s (%s)，而扫描目标位于中国大陆网段。", r.egress.CountryCode, r.egress.IP)
	logger.PrintTimestampedMessage("   握手延迟反映的是海外出口的观测值，不代表国内客户端的真实体验；证书与可用性检测不受影响。")
}

// resolveInputToCIDRs 原生构建 CIDR 扫描队列（无需依赖易失效的第三方 HTTP API）
func resolveInputToCIDRs(targetInput string, inFile string, filter types.FilterConfig) []string {
	var cidrs []string

	// 从文件批量读取 CIDRs
	if inFile != "" {
		f, err := os.Open(inFile)
		if err == nil {
			defer f.Close()
			scanner := bufio.NewScanner(f)
			for scanner.Scan() {
				line := strings.TrimSpace(scanner.Text())
				if line == "" || strings.HasPrefix(line, "#") {
					continue
				}
				cidrs = appendCIDR(cidrs, line, filter)
			}
		}
	}

	// 处理单个命令行目标输入 (支持 CIDR 或 IP)
	if targetInput != "" {
		cidrs = appendCIDR(cidrs, targetInput, filter)
	}

	return cidrs
}

// resolveAutoInput discovers announced prefixes for a target IP and keeps only
// prefixes whose representative address is in the target IP's country and matches IPv4/IPv6 filter.
func resolveAutoInput(ctx context.Context, targetInput string, inFile string, country string, filter types.FilterConfig, proxyURL string) ([]string, string, string, error) {
	if inFile != "" || targetInput == "" || strings.Contains(targetInput, "/") {
		return resolveInputToCIDRs(targetInput, inFile, filter), "", "", nil
	}
	ip := net.ParseIP(targetInput)
	if ip == nil {
		return resolveInputToCIDRs(targetInput, inFile, filter), "", "", nil
	}

	reader, err := data.OpenGeoIPReader("data/Country.mmdb", "Country.mmdb")
	if err != nil {
		logger.PrintTimestampedMessage("⚠️ GeoIP 数据库不可用 (%v)，跳过 ASN/国家过滤，直接扫描入口 IP 所在网段", err)
		return resolveInputToCIDRs(targetInput, inFile, filter), "", "", nil
	}
	defer reader.Close()

	targetCountry := resolveTargetCountry(ctx, reader, ip, targetInput, proxyURL)
	if targetCountry == "" {
		// 缺失归属不阻断扫描：ASN 前缀本身有效，只是放弃「同国家」这一层过滤
		logger.PrintTimestampedMessage("⚠️ 无法确定入口 IP %s 的国家（本地 GeoIP 无记录且在线查询失败），跳过国家过滤，直接扫描该 ASN 的全部网段（也可用 --country 显式指定 ISO 代码）", targetInput)
	}
	overridden := strings.ToUpper(strings.TrimSpace(country))
	if overridden != "" {
		if len(overridden) != 2 {
			return nil, "", "", fmt.Errorf("国家代码必须是两位 ISO 代码（例如 DE、US）")
		}
		targetCountry = overridden
	}

	asnNumber, prefixes, err := asn.NewClient(15*time.Second).PrefixesForIP(ctx, ip.String())
	if err != nil {
		return nil, "", "", err
	}
	asnStr := fmt.Sprintf("AS%d", asnNumber)

	filtered, unknown := filterPrefixesByCountry(prefixes, reader, targetCountry, filter)
	if len(filtered) == 0 {
		// 协议族 / 国家双重过滤后为空：先放宽国家限制再判断是否真的没网段。
		// IPv6 段的 GeoIP 归属常与入口 IP 不同，按国家严格过滤会把整个 ASN 判死。
		if relaxed := filterPrefixesByFamily(prefixes, filter); len(relaxed) > 0 {
			logger.PrintTimestampedMessage("⚠️ %s 在 %s 内没有符合条件的网段，已放宽国家限制（IPv6 段归属常与入口国不同），保留 %d 个网段",
				asnStr, targetCountry, len(relaxed))
			return relaxed, asnStr, targetCountry, nil
		}
		return nil, asnStr, targetCountry, fmt.Errorf("AS%d 没有符合 IP 协议族限制的宣布网段", asnNumber)
	}
	if unknown > 0 {
		logger.PrintTimestampedMessage("入口 IP %s 属于 %s，国家 %s；已过滤为 %d 个网段（其中 %d 个本地库无归属记录，按 ASN 归属保留）",
			targetInput, asnStr, targetCountry, len(filtered), unknown)
		return filtered, asnStr, targetCountry, nil
	}
	logger.PrintTimestampedMessage("入口 IP %s 属于 %s，国家 %s；已过滤为 %d 个同国家网段",
		targetInput, asnStr, targetCountry, len(filtered))
	return filtered, asnStr, targetCountry, nil
}

// filterPrefixesByFamily 只按协议族过滤宣布前缀
func filterPrefixesByFamily(prefixes []string, filter types.FilterConfig) []string {
	out := make([]string, 0, len(prefixes))
	for _, raw := range prefixes {
		prefix, err := netip.ParsePrefix(raw)
		if err != nil {
			continue
		}
		if filter.IPv4Only && !prefix.Addr().Is4() {
			continue
		}
		if filter.IPv6Only && !prefix.Addr().Is6() {
			continue
		}
		out = append(out, prefix.String())
	}
	return out
}

// filterPrefixesByCountry 先按协议族、再按国家过滤前缀。
// country 为空时只做协议族过滤；本地库缺失归属的前缀保留（IPv6 段覆盖不全很常见，
// 仅凭本地库缺失不足以否认该网段属于这个 ASN）。
func filterPrefixesByCountry(prefixes []string, reader *geoip2.Reader, country string, filter types.FilterConfig) ([]string, int) {
	country = strings.ToUpper(strings.TrimSpace(country))
	filtered := make([]string, 0, len(prefixes))
	unknown := 0

	for _, raw := range prefixes {
		prefix, err := netip.ParsePrefix(raw)
		if err != nil {
			continue
		}
		if filter.IPv4Only && !prefix.Addr().Is4() {
			continue
		}
		if filter.IPv6Only && !prefix.Addr().Is6() {
			continue
		}
		if country == "" {
			filtered = append(filtered, prefix.String())
			continue
		}
		switch prefixCountry(reader, prefix.Addr()) {
		case country:
			filtered = append(filtered, prefix.String())
		case "":
			unknown++
			filtered = append(filtered, prefix.String())
		}
	}

	return filtered, unknown
}

// resolveTargetCountry 先查本地 GeoIP 库，缺失时（IPv6 覆盖不全很常见）回退到在线查询。
// country 参数非空时直接采用调用方指定的国家代码。
func resolveTargetCountry(ctx context.Context, reader *geoip2.Reader, ip net.IP, targetInput, proxyURL string) string {
	if reader != nil {
		if rec, err := reader.Country(ip); err == nil && rec != nil {
			if code := strings.ToUpper(strings.TrimSpace(rec.Country.IsoCode)); len(code) == 2 {
				return code
			}
		}
	}

	logger.PrintTimestampedMessage("本地 GeoIP 库无 %s 的记录（常见于 IPv6 段覆盖不全），改用在线归属地查询...", targetInput)

	// 归属地查询只是元数据查询，与 ASN 查询同一性质。若配置了扫描代理但代理不可用
	// （例如默认配置里的 socks5://127.0.0.1:666 并未运行），不应因此判定失败，
	// 这里先按配置走一次，失败且确实配置了代理时再回退直连重试。
	code, err := asn.NewCountryLookup(proxyURL).LookupCountry(ctx, targetInput)
	if err != nil && proxyURL != "" {
		logger.PrintTimestampedMessage("⚠️ 经代理 (%s) 查询归属地失败，回退直连重试...", proxyURL)
		code, err = asn.NewCountryLookup("").LookupCountry(ctx, targetInput)
	}
	if err != nil {
		logger.PrintTimestampedMessage("⚠️ 在线归属地查询失败：%v", err)
		return ""
	}
	logger.PrintTimestampedMessage("在线查询结果：%s 归属 %s", targetInput, code)
	return code
}

// prefixCountry 返回网段代表地址的国家代码；本地库缺失时返回空串（不发起在线查询，
// 避免对每个前缀都打一次外部接口）。
func prefixCountry(reader *geoip2.Reader, addr netip.Addr) string {
	if reader == nil || !addr.IsValid() {
		return ""
	}
	rec, err := reader.Country(net.ParseIP(addr.String()))
	if err != nil || rec == nil {
		return ""
	}
	return strings.ToUpper(strings.TrimSpace(rec.Country.IsoCode))
}

// appendCIDR 解析并追加 CIDR 或单 IP 扩展网段，自动去重并规范化
func appendCIDR(list []string, input string, filter types.FilterConfig) []string {
	input = strings.TrimSpace(input)
	if input == "" {
		return list
	}

	// 1. 输入本身已经是 CIDR 格式（如 "198.51.100.0/24"）
	if strings.Contains(input, "/") {
		_, ipNet, err := net.ParseCIDR(input)
		if err == nil {
			isIPv4 := ipNet.IP.To4() != nil
			if filter.IPv4Only && !isIPv4 {
				return list
			}
			if filter.IPv6Only && isIPv4 {
				return list
			}
			cidrStr := ipNet.String()
			if !contains(list, cidrStr) {
				list = append(list, cidrStr)
			}
		}
		return list
	}

	// 2. 输入是单个 IP，按就近原则扩展为子网
	ip := net.ParseIP(input)
	if ip == nil {
		return list
	}

	// IPv4: 扩展为包含该 IP 的标准 /24 网段
	if v4 := ip.To4(); v4 != nil {
		if filter.IPv6Only {
			return list
		}
		c24 := fmt.Sprintf("%d.%d.%d.0/24", v4[0], v4[1], v4[2])
		if !contains(list, c24) {
			list = append(list, c24)
		}
		return list
	}

	// IPv6: 扩展为包含该 IP 的标准 /64 前缀网段
	if filter.IPv4Only {
		return list
	}
	mask := net.CIDRMask(64, 128)
	ipNet := &net.IPNet{
		IP:   ip.Mask(mask),
		Mask: mask,
	}
	c64 := ipNet.String()
	if !contains(list, c64) {
		list = append(list, c64)
	}

	return list
}

// parseAndExecuteAuto 解析命令行参数并应用 YAML 策略与 CLI 参数覆盖
func (r *RootCmd) parseAndExecuteAuto(args []string) {
	if len(args) == 0 {
		appName := version.GetAppName()
		logger.PrintErrorWithDetails(
			"错误：缺少目标 IP / CIDR 参数或 --in 文件参数",
			"用法:",
			fmt.Sprintf("  %s auto <ip_or_cidr> [选项]", appName),
			fmt.Sprintf("  %s auto --in <cidr_file> [选项]", appName),
			"选项:",
			"  --in FILE            从文件中批量读取 CIDR/IP 列表 (每行一个)",
			"  --country CODE       按两位 ISO 国家代码过滤（默认使用入口 IP 国家）",
			"  --no-check           跳过data资源检测",
			"  --limit N / -m       指定获取合适目标的数量上限 (默认 10)",
			"  --check-all / -a     开启全量摸底扫描模式 (不提前终止，全量入库，支持断点续传)",
			"  --reset-scan         重置断点记录，从第 1 个网段重新扫描",
			"  --threads N / -t     设置网络扫描并发协程数 (默认 200，高性能机器可设 500-1000)",
			"  --timeout SEC        单 IP 握手超时秒数 (默认 3 秒，死 IP 快速熔断建议 1-2 秒)",
			"  --no-cache           跳过本地资产库缓存，强制重新网络扫描",
			"  --recheck            对本地资产库命中目标发起在线网络复核",
			"  --ipv4-only / -4     仅拉取与扫描 IPv4 网段",
			"  --ipv6-only / -6     仅拉取与扫描 IPv6 网段",
			"  --ipv6-budget N      IPv6 单个网段探针预算 (默认 4096；IPv6 主机位按伪随机 IID 稀疏采样)",
			"  --no-region-fallback 同 ASN 目标不足时不回退同地区（同国家）",
			"  --region-asns N      同地区回退最多尝试的其它 ASN 个数 (默认 5 个)",
			"  --export FILE        将扫描发现的所有合格资产导出为 JSON 文件",
			"  --no-cdn             强制筛选无 CDN 节点 (默认开启)",
			"  --allow-cdn          允许 CDN 节点",
			"  --max-handshake MS   设置最大握手延迟 (毫秒, 默认 800)",
			"  --no-hot             排除热门大站 (默认开启)",
			"  --allow-hot          允许热门大站",
			"  --min-cert-days DAYS 证书最低剩余天数 (默认 7 天)",
			"  --min-stars STARS    最低推荐星级 1-5 (默认 3)",
			"  -v / --verbose       详细模式，输出每一条被探测 IP 的扫描与判定记录到 stdout (关闭进度条)",
			"示例:",
			fmt.Sprintf("  %s auto 203.0.113.10 --limit 5", appName),
			fmt.Sprintf("  %s auto 203.0.113.10 --check-all --export all.json", appName),
			fmt.Sprintf("  %s auto 203.0.113.69 --check-all --threads 500 --timeout 2", appName),
			fmt.Sprintf("  %s auto 198.51.100.0/24 --limit 2", appName),
			fmt.Sprintf("  %s auto --in cidrs.txt --limit 5", appName),
		)
		os.Exit(1)
	}

	var targetInput string
	var inFile string
	var country string
	var exportFile string
	checkAll := false
	noCache := false
	verbose := false
	maxTargets := 10
	regionASNs := 5
	noRegionFallback := false
	filter := r.batchManager.GetConfig().Filter

	for i := 0; i < len(args); i++ {
		arg := args[i]
		if !strings.HasPrefix(arg, "-") && targetInput == "" {
			targetInput = arg
			continue
		}

		switch arg {
		case "--in":
			if i+1 < len(args) {
				inFile = args[i+1]
				i++
			}
		case "--country":
			if i+1 < len(args) {
				country = args[i+1]
				i++
			}
		case "--limit", "-m":
			if i+1 < len(args) {
				if n, err := strconv.Atoi(args[i+1]); err == nil {
					maxTargets = n
				}
				i++
			}
		case "--threads", "-t":
			if i+1 < len(args) {
				if t, err := strconv.Atoi(args[i+1]); err == nil && t > 0 {
					filter.ScanThreads = t
				}
				i++
			}
		case "--timeout":
			if i+1 < len(args) {
				if to, err := strconv.Atoi(args[i+1]); err == nil && to > 0 {
					filter.ScanTimeout = to
				}
				i++
			}
		case "--check-all", "-a":
			checkAll = true
		case "--reset-scan", "--no-resume":
			filter.NoResume = true
		case "--no-cache":
			noCache = true
		case "--recheck", "--verify-cache":
			filter.VerifyCache = true
		case "--no-recheck":
			filter.VerifyCache = false
		case "--export":
			if i+1 < len(args) {
				exportFile = args[i+1]
				i++
			}
		case "--no-check":
			filter.RequireNoCDN = true
		case "--no-cdn":
			filter.RequireNoCDN = true
		case "--allow-cdn":
			filter.RequireNoCDN = false
		case "--no-hot":
			filter.RequireNoHot = true
		case "--allow-hot":
			filter.RequireNoHot = false
		case "--max-handshake":
			if i+1 < len(args) {
				if ms, err := strconv.ParseInt(args[i+1], 10, 64); err == nil {
					filter.MaxHandshakeMS = ms
				}
				i++
			}
		case "--min-cert-days":
			if i+1 < len(args) {
				if days, err := strconv.Atoi(args[i+1]); err == nil {
					filter.MinCertDays = days
				}
				i++
			}
		case "--min-stars":
			if i+1 < len(args) {
				if s, err := strconv.Atoi(args[i+1]); err == nil {
					filter.MinStars = s
				}
				i++
			}
		case "--ipv4-only", "-4":
			filter.IPv4Only = true
			filter.IPv6Only = false
		case "--ipv6-only", "-6":
			filter.IPv6Only = true
			filter.IPv4Only = false
		case "--ipv6-budget":
			if i+1 < len(args) {
				if b, err := strconv.Atoi(args[i+1]); err == nil && b > 0 {
					filter.IPv6Budget = b
				}
				i++
			}
		case "--no-region-fallback":
			noRegionFallback = true
		case "--region-asns":
			if i+1 < len(args) {
				if n, err := strconv.Atoi(args[i+1]); err == nil && n > 0 {
					regionASNs = n
				}
				i++
			}
		case "-v", "--verbose":
			verbose = true
			filter.Verbose = true
		case "--debug":
			logger.Init("debug", "")
		case "--log-level":
			if i+1 < len(args) {
				logger.Init(args[i+1], "")
				i++
			}
		}
	}

	proxyURL := ""
	if r.config != nil && r.config.Proxy.Scanner && r.config.Proxy.URL != "" {
		proxyURL = r.config.Proxy.URL
	}
	cidrs, asnStr, countryStr, err := resolveAutoInput(r.ctx, targetInput, inFile, country, filter, proxyURL)
	if err != nil {
		logger.PrintError(fmt.Sprintf("自动查询 ASN 网段失败: %v", err))
		return
	}

	// 视角校验：仅当扫描目标位于 CN 网段、而本机出口不在 CN 时，握手延迟不代表国内客户端的真实体验
	r.warnEgressMismatch(targetInput, inFile, countryStr)

	// Cache-First 快速通道：若本地库存在同 ASN 且未过期的资产，优先进行秒级直出（默认 0 网络请求，可加 --recheck 在线复核）
	var cachedVerified []*types.DetectionResult
	if filter.UseCache && !noCache && !checkAll && asnStr != "" {
		store, err := initStore("", r.config)
		if err == nil && store != nil {
			defer store.Close()
			maxAge := time.Duration(filter.CacheMaxDays) * 24 * time.Hour
			cachedRecords, _ := store.GetTargetsByASN(asnStr, countryStr, maxAge)
			// 缓存快速通道也必须遵守 --ipv4-only / --ipv6-only，否则会直接把上一次
			// 另一协议族的资产吐出来（IPv6 资产在 IPv4 扫描里被当成本次结果）。
			cachedRecords = filterRecordsByFamily(cachedRecords, filter)

			if len(cachedRecords) > 0 {
				if !filter.VerifyCache {
					// 默认模式：直接使用本地历史参数，0 网络请求极速秒出
					for _, rec := range cachedRecords {
						res := storage.RecordToDetectionResult(rec)
						if res != nil {
							passed, _ := core.FilterTarget(res, filter)
							if passed {
								cachedVerified = append(cachedVerified, res)
							}
						}
					}

					if len(cachedVerified) >= maxTargets {
						logger.PrintTimestampedMessage("✅ 从本地资产库秒级命中 %d 个历史资产（0 网络延迟，极速直出）！如需在线连通性复核可添加 --recheck", len(cachedVerified))
						cachedVerified = core.FilterPool(cachedVerified, filter)
						if len(cachedVerified) > maxTargets {
							cachedVerified = cachedVerified[:maxTargets]
						}
						r.batchManager.SortByRecommendationStars(cachedVerified)
						fmt.Println("\n适合的域名:")
						fmt.Println(r.batchManager.FormatSuitableTable(cachedVerified))
						return
					} else if len(cachedVerified) > 0 {
						logger.PrintTimestampedMessage("本地资产库命中 %d 个目标，不足指定数量 (%d)，已预置并启动网络扫描补充...",
							len(cachedVerified), maxTargets)
					}
				} else {
					// 传入了 --recheck / --verify-cache：在线并发复核连通性
					logger.PrintTimestampedMessage("发现同 ASN/国家 (%s, %s) 的历史资产 %d 条，正在在线并发复核连通性...",
						asnStr, countryStr, len(cachedRecords))

					var vMu sync.Mutex
					var vWg sync.WaitGroup
					sem := make(chan struct{}, 15) // 控制并发数为 15，防止瞬间并发大量 HTTP 请求导致 Windows Socket 耗尽

					checkCtx, cancelCheck := context.WithTimeout(r.ctx, 6*time.Second)
					defer cancelCheck()

					for _, rec := range cachedRecords {
						select {
						case <-checkCtx.Done():
							break
						default:
						}

						vWg.Add(1)
						go func(record *types.TargetRecord) {
							defer vWg.Done()

							select {
							case sem <- struct{}{}:
								defer func() { <-sem }()
							case <-checkCtx.Done():
								return
							}

							res, err := r.engine.CheckDomain(checkCtx, record.Domain)
							if err == nil && res != nil && res.Suitable {
								passed, _ := core.FilterTarget(res, filter)
								if passed {
									vMu.Lock()
									cachedVerified = append(cachedVerified, res)
									vMu.Unlock()
								}
							}
						}(rec)
					}
					vWg.Wait()

					if r.ctx.Err() != nil {
						logger.PrintTimestampedMessage("任务已被用户中断 (Ctrl+C)。")
						return
					}

					if len(cachedVerified) >= maxTargets {
						logger.PrintTimestampedMessage("✅ 成功从本地资产库复核通过 %d 个优质 REALITY 目标！", len(cachedVerified))
						cachedVerified = core.FilterPool(cachedVerified, filter)
						if len(cachedVerified) > maxTargets {
							cachedVerified = cachedVerified[:maxTargets]
						}
						r.batchManager.SortByRecommendationStars(cachedVerified)
						fmt.Println("\n适合的域名:")
						fmt.Println(r.batchManager.FormatSuitableTable(cachedVerified))
						return
					} else if len(cachedVerified) > 0 {
						logger.PrintTimestampedMessage("本地缓存复核通过 %d 个目标，不足指定数量 (%d)，已预置并继续启动网络扫描补充...",
							len(cachedVerified), maxTargets)
					}
				}
			}
		}
	}

	r.executeAuto(AutoScanCLIOptions{
		CIDRs:            cidrs,
		MaxTargets:       maxTargets,
		CheckAll:         checkAll,
		ExportFile:       exportFile,
		Filter:           filter,
		ASN:              asnStr,
		Country:          countryStr,
		Scope:            "同 ASN",
		NoRegionFallback: noRegionFallback,
		RegionASNs:       regionASNs,
		InitialResults:   cachedVerified,
		Verbose:          verbose,
	})
}

// formatNonDefaultFilters 格式化输出用户自定义/非默认的 REALITY 选型策略
func formatNonDefaultFilters(filter types.FilterConfig) []string {
	def := config.GetDefaultConfig().Filter
	var diffs []string

	if filter.RequireNoCN != def.RequireNoCN {
		if filter.RequireNoCN {
			diffs = append(diffs, "排除国内站点 (require_no_cn=true)")
		} else {
			diffs = append(diffs, "允许国内站点 (require_no_cn=false)")
		}
	}
	if filter.CheckGFW != def.CheckGFW {
		diffs = append(diffs, fmt.Sprintf("GFW黑名单=%v", filter.CheckGFW))
	}
	if filter.IPv4Only != def.IPv4Only && filter.IPv4Only {
		diffs = append(diffs, "仅IPv4 (ipv4_only=true)")
	}
	if filter.IPv6Only != def.IPv6Only && filter.IPv6Only {
		diffs = append(diffs, "仅IPv6 (ipv6_only=true)")
	}
	if filter.RequireNoCDN != def.RequireNoCDN {
		diffs = append(diffs, fmt.Sprintf("非CDN限制=%v", filter.RequireNoCDN))
	}
	if filter.ScanThreads != def.ScanThreads && filter.ScanThreads > 0 {
		diffs = append(diffs, fmt.Sprintf("并发协程=%d (默认%d)", filter.ScanThreads, def.ScanThreads))
	}
	if filter.ScanTimeout != def.ScanTimeout && filter.ScanTimeout > 0 {
		diffs = append(diffs, fmt.Sprintf("单IP超时=%d秒 (默认%d秒)", filter.ScanTimeout, def.ScanTimeout))
	}
	if filter.IPv6Budget != def.IPv6Budget && filter.IPv6Budget > 0 {
		diffs = append(diffs, fmt.Sprintf("IPv6网段探针预算=%d (默认%d)", filter.IPv6Budget, def.IPv6Budget))
	}
	if filter.MaxHandshakeMS != def.MaxHandshakeMS && filter.MaxHandshakeMS > 0 {
		diffs = append(diffs, fmt.Sprintf("最大握手延迟=%dms", filter.MaxHandshakeMS))
	}
	if filter.RequireNoHot != def.RequireNoHot {
		diffs = append(diffs, fmt.Sprintf("排除热门大站=%v", filter.RequireNoHot))
	}
	if filter.MinCertDays != def.MinCertDays && filter.MinCertDays > 0 {
		diffs = append(diffs, fmt.Sprintf("最小证书天数=%d天", filter.MinCertDays))
	}
	if filter.MinStars != def.MinStars && filter.MinStars > 0 {
		diffs = append(diffs, fmt.Sprintf("最低推荐星级=%d星", filter.MinStars))
	}
	if filter.RequireNoDefaultPage != def.RequireNoDefaultPage {
		diffs = append(diffs, fmt.Sprintf("排除默认欢迎页=%v", filter.RequireNoDefaultPage))
	}
	if len(filter.IncludeSuffixes) > 0 {
		diffs = append(diffs, fmt.Sprintf("白名单后缀=%v", filter.IncludeSuffixes))
	}
	if len(filter.ExcludeSuffixes) > 0 {
		defaultSet := make(map[string]bool)
		for _, s := range def.ExcludeSuffixes {
			defaultSet[s] = true
		}
		var customEx []string
		for _, s := range filter.ExcludeSuffixes {
			if !defaultSet[s] {
				customEx = append(customEx, s)
			}
		}
		if len(customEx) > 0 {
			diffs = append(diffs, fmt.Sprintf("附加排除后缀=%v", customEx))
		}
	}
	if len(filter.ExcludeStatus) > 0 {
		defaultStatus := make(map[int]bool)
		for _, st := range def.ExcludeStatus {
			defaultStatus[st] = true
		}
		var customStatus []int
		for _, st := range filter.ExcludeStatus {
			if !defaultStatus[st] {
				customStatus = append(customStatus, st)
			}
		}
		if len(customStatus) > 0 {
			diffs = append(diffs, fmt.Sprintf("附加排除状态码=%v", customStatus))
		}
	}

	return diffs
}
