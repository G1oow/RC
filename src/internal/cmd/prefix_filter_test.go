package cmd

import (
	"testing"

	"RealityChecker/internal/types"
)

// 协议族过滤：--ipv4-only / --ipv6-only 各自只保留对应前缀，双栈时原样保留
func TestFilterPrefixesByFamily(t *testing.T) {
	prefixes := []string{"203.0.113.0/24", "2001:db8::/32", "not-a-prefix"}

	both := filterPrefixesByFamily(prefixes, types.FilterConfig{})
	if len(both) != 2 {
		t.Fatalf("双栈应保留 2 个合法前缀，实际 %d: %v", len(both), both)
	}

	v4 := filterPrefixesByFamily(prefixes, types.FilterConfig{IPv4Only: true})
	if len(v4) != 1 || v4[0] != "203.0.113.0/24" {
		t.Fatalf("仅 IPv4 过滤结果异常: %v", v4)
	}

	v6 := filterPrefixesByFamily(prefixes, types.FilterConfig{IPv6Only: true})
	if len(v6) != 1 || v6[0] != "2001:db8::/32" {
		t.Fatalf("仅 IPv6 过滤结果异常: %v", v6)
	}
}

// 国家过滤：country 为空时只做协议族过滤（国家不可解析的降级路径）
func TestFilterPrefixesByCountry_EmptyCountry(t *testing.T) {
	prefixes := []string{"203.0.113.0/24", "2001:db8::/32"}

	got, unknown := filterPrefixesByCountry(prefixes, nil, "", types.FilterConfig{})
	if len(got) != 2 || unknown != 0 {
		t.Fatalf("country 为空时应保留全部前缀且不计 unknown，实际 %v (unknown=%d)", got, unknown)
	}

	v6, _ := filterPrefixesByCountry(prefixes, nil, "", types.FilterConfig{IPv6Only: true})
	if len(v6) != 1 || v6[0] != "2001:db8::/32" {
		t.Fatalf("country 为空时仍应遵守协议族限制: %v", v6)
	}
}

// 缓存快速通道与同地区回退共用同一套协议族判定
func TestIpFamilyAllowed(t *testing.T) {
	cases := []struct {
		ip     string
		filter types.FilterConfig
		want   bool
	}{
		{"203.0.113.10", types.FilterConfig{}, true},
		{"203.0.113.10", types.FilterConfig{IPv4Only: true}, true},
		{"203.0.113.10", types.FilterConfig{IPv6Only: true}, false},
		{"2001:db8::10", types.FilterConfig{IPv6Only: true}, true},
		{"2001:db8::10", types.FilterConfig{IPv4Only: true}, false},
		{"", types.FilterConfig{IPv4Only: true}, true},
	}

	for _, c := range cases {
		if got := ipFamilyAllowed(c.ip, c.filter); got != c.want {
			t.Errorf("ipFamilyAllowed(%q, v4only=%v, v6only=%v) = %v, want %v",
				c.ip, c.filter.IPv4Only, c.filter.IPv6Only, got, c.want)
		}
	}
}

// 缓存记录必须按协议族裁剪，避免把上一次另一协议族的资产当成本次结果
func TestFilterRecordsByFamily(t *testing.T) {
	records := []*types.TargetRecord{
		{Domain: "a.example.com", IP: "203.0.113.10"},
		{Domain: "b.example.com", IP: "2001:db8::10"},
		nil,
	}

	if got := filterRecordsByFamily(records, types.FilterConfig{}); len(got) != 3 {
		t.Fatalf("双栈时应原样返回（含 nil），实际 %d", len(got))
	}

	v4 := filterRecordsByFamily(records, types.FilterConfig{IPv4Only: true})
	if len(v4) != 1 || v4[0].Domain != "a.example.com" {
		t.Fatalf("仅 IPv4 时缓存裁剪结果异常: %v", v4)
	}

	v6 := filterRecordsByFamily(records, types.FilterConfig{IPv6Only: true})
	if len(v6) != 1 || v6[0].Domain != "b.example.com" {
		t.Fatalf("仅 IPv6 时缓存裁剪结果异常: %v", v6)
	}
}
