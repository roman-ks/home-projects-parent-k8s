package main

import (
	"log"
	"net"
	"os"

	"github.com/miekg/dns"
)

var targetIP string

// handler answers every query it receives with an A record for targetIP,
// regardless of the name or type asked — this only ever receives queries
// Tailscale's Split DNS routed here in the first place (the pi.home zone),
// and every hostname in that zone points at the same shared Traefik-tailnet
// instance (see ai-fluency/tailscale-tasks-v2.md Task 3), so there's nothing
// left to differentiate by name for.
func handler(w dns.ResponseWriter, r *dns.Msg) {
	msg := new(dns.Msg)
	msg.SetReply(r)
	msg.Authoritative = true

	src := w.RemoteAddr()

	for _, q := range r.Question {
		qtype := dns.TypeToString[q.Qtype]
		rr, err := dns.NewRR(q.Name + " 60 IN A " + targetIP)
		if err != nil {
			log.Printf("query from %s: %s %s -> error building A record: %v", src, q.Name, qtype, err)
			continue
		}
		log.Printf("query from %s: %s %s -> A %s", src, q.Name, qtype, targetIP)
		msg.Answer = append(msg.Answer, rr)
	}

	_ = w.WriteMsg(msg)
}

func main() {
	targetIP = os.Getenv("TARGET_IP")
	if targetIP == "" {
		log.Fatal("TARGET_IP env var not set")
	}
	if net.ParseIP(targetIP) == nil {
		log.Fatalf("TARGET_IP %q is not a valid IP", targetIP)
	}

	dns.HandleFunc(".", handler)

	udpServer := &dns.Server{Addr: ":53", Net: "udp"}
	tcpServer := &dns.Server{Addr: ":53", Net: "tcp"}

	go func() {
		if err := udpServer.ListenAndServe(); err != nil {
			log.Fatalf("UDP server failed: %v", err)
		}
	}()

	if err := tcpServer.ListenAndServe(); err != nil {
		log.Fatalf("TCP server failed: %v", err)
	}
}
