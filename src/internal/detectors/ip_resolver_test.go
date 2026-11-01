package detectors

import (
	"net"
	"testing"
)

// dialAddress 必须产出 net.Dial 能直接消费的 host:port。
// 回归背景：曾用 ip+":443" 直接拼接，IPv6 字面量会拼成 "2001:db8::1:443"，
// net.Dial 立刻返回 "too many colons in address"，导致只有 AAAA 记录的域名
// 被误判为「网络不可达」。
func TestDialAddress_IPv6NeedsBrackets(t *testing.T) {
	const v6 = "2001:db8::6440:1007"

	got := dialAddress(v6, "443")
	if want := "[" + v6 + "]:443"; got != want {
		t.Fatalf("dialAddress(%q, \"443\") = %q, want %q", v6, got, want)
	}

	// 用 net.SplitHostPort 校验：拼接错误的地址这里就会报错，
	// 且 Dial 依赖同一套解析，能真正守住回归。
	host, port, err := net.SplitHostPort(got)
	if err != nil {
		t.Fatalf("dialAddress produced unparseable address %q: %v", got, err)
	}
	if host != v6 {
		t.Fatalf("host = %q, want %q", host, v6)
	}
	if port != "443" {
		t.Fatalf("port = %q, want %q", port, "443")
	}
}

// 空方括号包裹的 IPv6 会被 Dial 接受，这里顺带覆盖 80 端口分支。
func TestDialAddress_IPv6Port80(t *testing.T) {
	got := dialAddress("2001:db8::1", "80")
	if want := "[2001:db8::1]:80"; got != want {
		t.Fatalf("dialAddress = %q, want %q", got, want)
	}
}

// IPv4 不得被加上方括号，否则 Dial 同样失败。
func TestDialAddress_IPv4Unbracketed(t *testing.T) {
	for _, tc := range []struct{ ip, port, want string }{
		{"192.0.2.10", "443", "192.0.2.10:443"},
		{"198.51.100.7", "80", "198.51.100.7:80"},
	} {
		if got := dialAddress(tc.ip, tc.port); got != tc.want {
			t.Fatalf("dialAddress(%q, %q) = %q, want %q", tc.ip, tc.port, got, tc.want)
		}
	}
}
