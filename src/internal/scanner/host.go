package scanner

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"regexp"
)

// DefaultIPv6Budget 单个 IPv6 网段的默认探针预算。
//
// IPv6 的主机位通常是 64 位（/64），从网段基地址顺序枚举既不可能扫完，也没有意义：
// 基地址是 subnet-router anycast，真正的主机分布在整个 IID 空间里。
// 因此这里按「确定性伪随机接口标识」采样，预算控制单个网段的探测总量，
// 保证同一条前缀每次采样的序列一致，断点续扫才能对得上。
const DefaultIPv6Budget = 4096

// IterateCIDR 返回迭代 CIDR 或单个 IP/域名的 Host 通道 (支持从 startIP 断点处继续)
func IterateCIDR(ctx context.Context, cidrStr string, startIP string, enableIPv6 bool) <-chan Host {
	return IterateCIDRWithOptions(ctx, cidrStr, startIP, enableIPv6, 0)
}

// IterateCIDRWithOptions 同 IterateCIDR，额外支持 IPv6 网段探针预算
// ipv6Budget <= 0 时使用 DefaultIPv6Budget
func IterateCIDRWithOptions(ctx context.Context, cidrStr string, startIP string, enableIPv6 bool, ipv6Budget int) <-chan Host {
	hostChan := make(chan Host, 100)
	go func() {
		defer close(hostChan)

		p, err := netip.ParsePrefix(cidrStr)
		if err != nil {
			// 如果不是 CIDR，尝试单 IP 或 域名
			ip := net.ParseIP(cidrStr)
			if ip != nil {
				select {
				case hostChan <- Host{IP: ip, Origin: cidrStr, Type: HostTypeIP}:
				case <-ctx.Done():
				}
				return
			}
			if ValidateDomainName(cidrStr) {
				select {
				case hostChan <- Host{IP: nil, Origin: cidrStr, Type: HostTypeDomain}:
				case <-ctx.Done():
				}
				return
			}
			return
		}

		if !p.Addr().Is4() && !enableIPv6 {
			return
		}

		p = p.Masked()
		if p.Addr().Is4() {
			iterateIPv4Sequential(ctx, p, startIP, cidrStr, hostChan)
			return
		}
		iterateIPv6Sparse(ctx, p, startIP, cidrStr, ipv6Budget, hostChan)
	}()
	return hostChan
}

// iterateIPv4Sequential 顺序枚举 IPv4 网段（可从 startIP 的下一个地址续扫）
func iterateIPv4Sequential(ctx context.Context, p netip.Prefix, startIP, origin string, hostChan chan<- Host) {
	addr := p.Addr()

	// 如果指定了断点 startIP，从该 IP 的下一个 IP 开始遍历
	if startIP != "" {
		if startAddr, err := netip.ParseAddr(startIP); err == nil && p.Contains(startAddr) {
			addr = startAddr.Next()
		}
	}

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		if !p.Contains(addr) {
			break
		}

		ip := net.ParseIP(addr.String())
		if ip != nil {
			select {
			case hostChan <- Host{IP: ip, Origin: origin, Type: HostTypeCIDR}:
			case <-ctx.Done():
				return
			}
		}
		addr = addr.Next()
	}
}

// iterateIPv6Sparse 在 IPv6 网段内按确定性伪随机 IID 采样，最多 ipv6Budget 个候选地址。
//
// 序列只由（前缀, 序号）决定，所以断点续扫可以通过重放序列定位 startIP，
// 不需要给 scan_checkpoints 增加字段。
func iterateIPv6Sparse(ctx context.Context, p netip.Prefix, startIP, origin string, budget int, hostChan chan<- Host) {
	if budget <= 0 {
		budget = DefaultIPv6Budget
	}

	// 单个地址的前缀（/128）没有主机位可采样，直接探测自身
	if p.Bits() >= 128 {
		ip := net.ParseIP(p.Addr().String())
		if ip != nil {
			select {
			case hostChan <- Host{IP: ip, Origin: origin, Type: HostTypeCIDR}:
			case <-ctx.Done():
			}
		}
		return
	}

	prefixBytes := p.Addr().As16()
	startIdx := 0
	if startIP != "" {
		if startAddr, err := netip.ParseAddr(startIP); err == nil && p.Contains(startAddr) {
			for i := 0; i < budget; i++ {
				if candidateIPv6Addr(p, prefixBytes, i) == startAddr {
					startIdx = i + 1
					break
				}
			}
		}
	}

	seen := make(map[netip.Addr]struct{}, 16)
	for i := startIdx; i < budget; i++ {
		select {
		case <-ctx.Done():
			return
		default:
		}

		addr := candidateIPv6Addr(p, prefixBytes, i)
		if !addr.IsValid() || !p.Contains(addr) || addr == p.Addr() {
			continue
		}
		if _, dup := seen[addr]; dup {
			continue
		}
		seen[addr] = struct{}{}

		ip := net.ParseIP(addr.String())
		if ip == nil {
			continue
		}
		select {
		case hostChan <- Host{IP: ip, Origin: origin, Type: HostTypeCIDR}:
		case <-ctx.Done():
			return
		}
	}
}

// candidateIPv6Addr 由（前缀, 序号）确定性派生候选地址：SHA256(前缀字节 || 序号) 填充主机位
func candidateIPv6Addr(p netip.Prefix, prefixBytes [16]byte, index int) netip.Addr {
	h := sha256.New()
	_, _ = h.Write(prefixBytes[:])
	var idx [8]byte
	binary.BigEndian.PutUint64(idx[:], uint64(index))
	_, _ = h.Write(idx[:])
	sum := h.Sum(nil) // 32 字节 = 256 bit，足够覆盖最多 128 个主机位

	var raw [16]byte
	copy(raw[:], prefixBytes[:])

	prefixBits := p.Bits()
	for bit := prefixBits; bit < 128; bit++ {
		offset := bit - prefixBits
		bitVal := (sum[offset/8] >> (7 - uint(offset%8))) & 1
		if bitVal == 1 {
			raw[bit/8] |= 1 << (7 - uint(bit%8))
		}
	}

	addr, ok := netip.AddrFromSlice(raw[:])
	if !ok {
		return netip.Addr{}
	}
	return addr
}

func ValidateDomainName(domain string) bool {
	r := regexp.MustCompile(`(?m)^[A-Za-z0-9\-.]+$`)
	return r.MatchString(domain)
}

func LookupIP(addr string, enableIPv6 bool) (net.IP, error) {
	ips, err := net.LookupIP(addr)
	if err != nil {
		return nil, fmt.Errorf("failed to lookup: %w", err)
	}
	var arr []net.IP
	for _, ip := range ips {
		if ip.To4() != nil || enableIPv6 {
			arr = append(arr, ip)
		}
	}
	if len(arr) == 0 {
		return nil, errors.New("no IP found")
	}
	return arr[0], nil
}
