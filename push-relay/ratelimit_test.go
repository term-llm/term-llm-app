package main

import (
	"testing"
	"time"
)

func TestRateLimiter(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	l := newRateLimiter(3, 6, func() time.Time { return now }) // refill one token every 10s

	for i := range 3 {
		if ok, _ := l.allow("a"); !ok {
			t.Fatalf("request %d within burst denied", i)
		}
	}
	ok, wait := l.allow("a")
	if ok || wait != 10*time.Second {
		t.Fatalf("expected denial with 10s wait, got ok=%v wait=%v", ok, wait)
	}
	if ok, _ := l.allow("b"); !ok {
		t.Fatal("keys must be independent")
	}

	now = now.Add(10 * time.Second)
	if ok, _ := l.allow("a"); !ok {
		t.Fatal("token not refilled")
	}

	now = now.Add(2 * time.Minute)
	l.allow("c")
	if got := l.size(); got != 1 {
		t.Fatalf("idle full buckets should be swept, have %d", got)
	}
}
