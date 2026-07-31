package main

import (
	"log"
	"net"
	"os"
	"strings"

	"github.com/miekg/dns"
)

var hostMap map[string]string // query FQDN -> target IP

func handler(w dns.ResponseWriter, r *dns.Msg) {
	msg := new(dns.Msg)
	msg.SetReply(r)
	msg.Authoritative = true

	// Source address as seen by this pod — may be the real tailnet client IP, or
	// the tailscale proxy pod's own cluster IP if it SNATs the forwarded traffic
	// for return routing. Logging it is how we find out which.
	src := w.RemoteAddr()

	for _, q := range r.Question {
		name := strings.ToLower(q.Name)
		qtype := dns.TypeToString[q.Qtype]

		ip, ok := hostMap[name]
		if !ok {
			log.Printf("query from %s: %s %s -> no match (NXDOMAIN)", src, name, qtype)
			continue
		}

		// A record regardless of queried type (A/AAAA/HTTPS/etc) — direct IP, no
		// second hop for the client to get wrong (the CNAME-to-MagicDNS-name
		// design this replaced worked on Linux but broke on Android: the stub
		// answered correctly, but Android's resolver didn't correctly chase the
		// CNAME target across the split-DNS-to-ts.net domain boundary the way
		// systemd-resolved does). Trades away MagicDNS's automatic IP-tracking
		// for resolution that actually works on mobile — see
		// ai-fluency/tailscale-tasks-v2.md Task 5 for the full reasoning.
		rr, err := dns.NewRR(name + " 60 IN A " + ip)
		if err != nil {
			log.Printf("query from %s: %s %s -> error building A record for %s: %v", src, name, qtype, ip, err)
			continue
		}
		log.Printf("query from %s: %s %s -> A %s", src, name, qtype, ip)
		msg.Answer = append(msg.Answer, rr)
	}

	if len(msg.Answer) == 0 {
		msg.Rcode = dns.RcodeNameError
	}

	_ = w.WriteMsg(msg)
}

// parseHostMap parses "query1=ip1,query2=ip2" into FQDN(query) -> ip.
func parseHostMap(raw string) map[string]string {
	m := make(map[string]string)
	for _, pair := range strings.Split(raw, ",") {
		pair = strings.TrimSpace(pair)
		if pair == "" {
			continue
		}
		kv := strings.SplitN(pair, "=", 2)
		if len(kv) != 2 || kv[0] == "" || kv[1] == "" {
			log.Fatalf("HOST_MAP entry %q must be query=ip", pair)
		}
		if net.ParseIP(kv[1]) == nil {
			log.Fatalf("HOST_MAP entry %q: %q is not a valid IP", pair, kv[1])
		}
		m[dns.Fqdn(kv[0])] = kv[1]
	}
	return m
}

func main() {
	hostMapEnv := os.Getenv("HOST_MAP")
	if hostMapEnv == "" {
		log.Fatal("HOST_MAP env var not set")
	}
	hostMap = parseHostMap(hostMapEnv)

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
