package main

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"strings"
	"testing"
	"time"
)

// A relay defaults to production and must not mint development endpoints
// unless the operator explicitly enables that environment.
func TestRegisterRejectsDisabledEnvironment(t *testing.T) {
	sender := &fakeSender{}
	_, ts := startRelay(t, func(c *Config) {
		c.APNsEnvironments = []Environment{EnvProduction}
	}, sender)
	key := newVAPIDKey(t)

	for _, env := range []string{"development", "sandbox"} {
		resp, out := register(t, ts.URL, map[string]string{
			"device_token": hex.EncodeToString(testDeviceToken()), "environment": env, "application_server_key": key.encoded(),
		})
		if resp.StatusCode != http.StatusUnprocessableEntity {
			t.Fatalf("%s: status %d", env, resp.StatusCode)
		}
		if out["endpoint"] != "" {
			t.Fatalf("%s: endpoint was minted for a disabled environment", env)
		}
		if out["code"] != "unsupported_environment" {
			t.Fatalf("%s: code %q", env, out["code"])
		}
		if msg := out["error"]; !strings.Contains(msg, "production") || !strings.Contains(msg, "development") {
			t.Fatalf("%s: unhelpful error %q", env, msg)
		}
	}

	if endpoint := registerOK(t, ts.URL, key, "production"); endpoint == "" {
		t.Fatal("production registration failed")
	}
	if n := len(sender.sent()); n != 0 {
		t.Fatalf("registration reached APNs: %d", n)
	}
}

func TestRegisterHonorsEnabledEnvironments(t *testing.T) {
	_, ts := startRelay(t, func(c *Config) {
		c.APNsEnvironments = []Environment{EnvProduction, EnvDevelopment}
	}, &fakeSender{})
	key := newVAPIDKey(t)

	development := registerOK(t, ts.URL, key, "development")
	if alias := registerOK(t, ts.URL, key, "sandbox"); alias != development {
		t.Fatal("sandbox alias must map to the development environment")
	}
	if production := registerOK(t, ts.URL, key, "production"); production == development {
		t.Fatal("environments must not share endpoints")
	}
}

// An endpoint sealed while its environment was enabled must stop at the relay
// once the operator disables that environment.
func TestPushRejectsDisabledEnvironmentBeforeAPNs(t *testing.T) {
	sender := &fakeSender{}
	relay, ts := startRelay(t, func(c *Config) {
		c.APNsEnvironments = []Environment{EnvProduction}
	}, sender)
	key := newVAPIDKey(t)
	token, err := relay.sealer.Seal(Subscription{
		Env: EnvDevelopment, DeviceToken: testDeviceToken(), VAPIDKeyHash: sha256.Sum256(key.raw),
	})
	if err != nil {
		t.Fatal(err)
	}
	resp := push(t, ts.URL+"/v1/push/"+token, pushOpts{auth: key.header(t, validClaims(ts.URL, time.Now()))})
	if resp.StatusCode != http.StatusGone {
		t.Fatalf("disabled environment: status %d", resp.StatusCode)
	}
	if n := len(sender.sent()); n != 0 {
		t.Fatalf("disabled-environment push reached APNs: %d", n)
	}
}
