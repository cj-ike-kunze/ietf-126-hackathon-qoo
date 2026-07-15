// quicserve is a minimal static file server over HTTP/3 (QUIC), serving the
// same /var/www content tree the plain-HTTP responder serves, so a DASH
// client can pull the manifest/segments over either transport for A/B
// comparison under gateway impairment.
package main

import (
	"crypto/tls"
	"log"
	"net/http"
	"os"

	"github.com/quic-go/quic-go/http3"
)

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	addr := getenv("QUIC_ADDR", ":4433")
	dir := getenv("QUIC_ROOT", "/var/www")
	certFile := getenv("QUIC_CERT", "/app/certs/cert.pem")
	keyFile := getenv("QUIC_KEY", "/app/certs/key.pem")

	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		log.Fatalf("loading cert/key: %v", err)
	}

	server := &http3.Server{
		Addr:      addr,
		Handler:   http.FileServer(http.Dir(dir)),
		TLSConfig: &tls.Config{Certificates: []tls.Certificate{cert}},
	}

	log.Printf("quicserve listening on %s (HTTP/3), serving %s", addr, dir)
	log.Fatal(server.ListenAndServe())
}
