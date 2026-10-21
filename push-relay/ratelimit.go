package main

import (
	"math"
	"sync"
	"time"
)

// rateLimiter is an in-memory token bucket per key. State is lost on restart,
// which is acceptable for abuse protection on a single relay instance.
type rateLimiter struct {
	burst     float64
	perSecond float64
	now       func() time.Time

	mu        sync.Mutex
	buckets   map[string]*bucket
	lastSweep time.Time
}

type bucket struct {
	tokens float64
	last   time.Time
}

func newRateLimiter(burst int, perMinute float64, now func() time.Time) *rateLimiter {
	return &rateLimiter{
		burst:     float64(burst),
		perSecond: perMinute / 60,
		now:       now,
		buckets:   map[string]*bucket{},
	}
}

// allow consumes one token for key. When denied it returns how long until a
// token is available.
func (l *rateLimiter) allow(key string) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	if now.Sub(l.lastSweep) > time.Minute {
		l.sweep(now)
	}
	b, ok := l.buckets[key]
	if !ok {
		b = &bucket{tokens: l.burst, last: now}
		l.buckets[key] = b
	} else {
		b.tokens = math.Min(l.burst, b.tokens+now.Sub(b.last).Seconds()*l.perSecond)
		b.last = now
	}
	if b.tokens >= 1 {
		b.tokens--
		return true, 0
	}
	wait := time.Duration((1 - b.tokens) / l.perSecond * float64(time.Second))
	return false, wait
}

// sweep drops buckets that have refilled completely; they are equivalent to new ones.
func (l *rateLimiter) sweep(now time.Time) {
	l.lastSweep = now
	for key, b := range l.buckets {
		if b.tokens+now.Sub(b.last).Seconds()*l.perSecond >= l.burst {
			delete(l.buckets, key)
		}
	}
}

func (l *rateLimiter) size() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.buckets)
}
