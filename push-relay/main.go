// Command push-relay forwards encrypted Web Push messages from self-hosted
// term-llm servers to the iOS app through APNs. It never sees notification
// content and keeps no per-device state. See README.md.
package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	cmd := "serve"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	switch cmd {
	case "serve":
		if err := serve(); err != nil {
			fmt.Fprintln(os.Stderr, "push-relay:", err)
			os.Exit(1)
		}
	case "genkey":
		var key [32]byte
		if _, err := rand.Read(key[:]); err != nil {
			fmt.Fprintln(os.Stderr, "push-relay:", err)
			os.Exit(1)
		}
		fmt.Printf("RELAY_TOKEN_KEYS=1:%s\n", base64.StdEncoding.EncodeToString(key[:]))
	default:
		fmt.Fprintln(os.Stderr, "usage: push-relay [serve|genkey]")
		os.Exit(2)
	}
}

func serve() error {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg, err := loadConfig(os.Getenv)
	if err != nil {
		return fmt.Errorf("configuration:\n%w", err)
	}
	sealer, err := NewTokenSealer(cfg.TokenKeys)
	if err != nil {
		return err
	}
	relay := NewServer(cfg, sealer, NewAPNsClient(cfg.APNs, nil), logger)
	srv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           relay.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      40 * time.Second,
		IdleTimeout:       2 * time.Minute,
		MaxHeaderBytes:    16 << 10,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	errCh := make(chan error, 1)
	go func() { errCh <- srv.ListenAndServe() }()
	logger.Info("listening", "addr", cfg.ListenAddr, "public_url", cfg.PublicURL, "apns_topic", cfg.APNs.Topic)

	select {
	case err := <-errCh:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	case <-ctx.Done():
	}
	logger.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	return srv.Shutdown(shutdownCtx)
}
