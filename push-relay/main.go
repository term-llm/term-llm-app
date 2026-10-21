// Command term-llm-push is a deliberately small, operator-run native APNs
// relay. It exposes exactly two routes and sends accepted notifications to
// Apple's fixed sandbox or production endpoint.
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/SamSaffron/term-llm-app/push-relay/internal/apns"
	"github.com/SamSaffron/term-llm-app/push-relay/internal/config"
	"github.com/SamSaffron/term-llm-app/push-relay/internal/relay"
)

func main() {
	logger := log.New(os.Stderr, "term-llm-push: ", log.LstdFlags|log.LUTC)
	if err := run(logger); err != nil {
		logger.Print(err)
		os.Exit(1)
	}
}

func run(logger *log.Logger) error {
	cfg, err := config.Load(os.Getenv)
	if err != nil {
		return fmt.Errorf("configuration: %w", err)
	}

	client, err := apns.NewClient(cfg.APNSKey, cfg.APNSKeyID, cfg.APNSTeamID, cfg.APNSTopic, cfg.APNSTimeout)
	if err != nil {
		return fmt.Errorf("APNs client: %w", err)
	}
	defer client.CloseIdleConnections()

	handler, err := relay.New(client, cfg.Token, relay.Options{
		MaxConcurrent: cfg.MaxConcurrent,
		APNSTimeout:   cfg.APNSTimeout,
		MaxBodyBytes:  relay.DefaultMaxBodyBytes,
	})
	// The relay keeps only a digest. Drop the shared bearer credential from
	// the configuration struct as soon as it has been used.
	clear(cfg.Token)
	if err != nil {
		return fmt.Errorf("relay: %w", err)
	}

	listener, err := net.Listen("tcp", cfg.Addr)
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}

	writeTimeout := cfg.APNSTimeout + 10*time.Second
	if writeTimeout < 20*time.Second {
		writeTimeout = 20 * time.Second
	}
	server := &http.Server{
		Handler:                      handler,
		ReadHeaderTimeout:            5 * time.Second,
		ReadTimeout:                  10 * time.Second,
		WriteTimeout:                 writeTimeout,
		IdleTimeout:                  60 * time.Second,
		MaxHeaderBytes:               8 << 10,
		DisableGeneralOptionsHandler: true,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	shutdownDone := make(chan error, 1)
	go func() {
		<-ctx.Done()
		logger.Print("shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			_ = server.Close()
			shutdownDone <- err
			return
		}
		shutdownDone <- nil
	}()

	logger.Printf("listening on %s", cfg.Addr)
	serveErr := server.Serve(listener)
	if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
		return fmt.Errorf("serve: %w", serveErr)
	}
	if ctx.Err() != nil {
		if err := <-shutdownDone; err != nil {
			return fmt.Errorf("shutdown: %w", err)
		}
	}
	return nil
}
