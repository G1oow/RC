package scanner

import (
	"context"
	"net/netip"
	"reflect"
	"testing"
	"time"
)

func collectIPv6(t *testing.T, prefix string, startIP string, budget int) []string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var out []string
	for host := range IterateCIDRWithOptions(ctx, prefix, startIP, true, budget) {
		if host.IP == nil {
			t.Fatalf("IPv6 迭代返回了空 IP: %+v", host)
		}
		out = append(out, host.IP.String())
	}
	return out
}

// IPv6 网段必须能在 IPv6 探测开启时产出候选地址，且全部落在前缀内、无重复、不超过预算
func TestIterateCIDRWithOptions_IPv6Sparse(t *testing.T) {
	const prefix = "2001:db8:1::/64"
	const budget = 64

	got := collectIPv6(t, prefix, "", budget)
	if len(got) == 0 {
		t.Fatal("IPv6 稀疏采样没有产出任何候选地址")
	}
	if len(got) > budget {
		t.Fatalf("候选地址 %d 个，超过预算 %d", len(got), budget)
	}

	p := netip.MustParsePrefix(prefix)
	seen := make(map[netip.Addr]bool, len(got))
	for _, ip := range got {
		addr := netip.MustParseAddr(ip)
		if !p.Contains(addr) {
			t.Fatalf("候选地址 %s 不在前缀 %s 内", addr, prefix)
		}
		if seen[addr] {
			t.Fatalf("候选地址重复: %s", addr)
		}
		seen[addr] = true
	}

	// 网段基地址是 subnet-router anycast，不应被当成普通主机来探测
	if seen[p.Addr()] {
		t.Fatalf("网段基地址 %s 不应进入候选列表", p.Addr())
	}

	// 确定性：同前缀同预算必须得到同一序列，断点续扫才能重放
	if again := collectIPv6(t, prefix, "", budget); !reflect.DeepEqual(got, again) {
		t.Fatal("IPv6 采样序列不确定，断点续扫会失效")
	}
}

// 断点续扫：从某个已探测地址继续，必须得到原序列中它之后的地址
func TestIterateCIDRWithOptions_IPv6Resume(t *testing.T) {
	const prefix = "2001:db8:2::/64"
	const budget = 40

	all := collectIPv6(t, prefix, "", budget)
	if len(all) < 12 {
		t.Fatalf("采样数量过少，无法验证续扫: %d", len(all))
	}

	resumeFrom := all[10]
	resumed := collectIPv6(t, prefix, resumeFrom, budget)
	if !reflect.DeepEqual(resumed, all[11:]) {
		t.Fatalf("断点续扫结果与原始序列不一致\nresumed=%v\nwant=%v", resumed, all[11:])
	}
}

// enableIPv6=false 时 IPv6 网段不产出任何主机（保持既有语义）
func TestIterateCIDR_IPv6Disabled(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	count := 0
	for range IterateCIDR(ctx, "2001:db8:3::/64", "", false) {
		count++
	}
	if count != 0 {
		t.Fatalf("enableIPv6=false 时不应产出 IPv6 主机，实际产出 %d 个", count)
	}
}

// /128 前缀只有自身一个地址，必须被探测
func TestIterateCIDRWithOptions_IPv6SingleHost(t *testing.T) {
	got := collectIPv6(t, "2001:db8:4::5/128", "", 16)
	if len(got) != 1 || got[0] != "2001:db8:4::5" {
		t.Fatalf("/128 前缀应只探测自身，实际: %v", got)
	}
}

// IPv4 顺序枚举行为保持不变
func TestIterateCIDR_IPv4Sequential(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var got []string
	for host := range IterateCIDR(ctx, "198.51.100.0/30", "", false) {
		got = append(got, host.IP.String())
	}
	want := []string{"198.51.100.0", "198.51.100.1", "198.51.100.2", "198.51.100.3"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("IPv4 顺序枚举结果变化: %v", got)
	}
}
