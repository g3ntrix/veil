package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

var (
	probeMagic = []byte("\xffVEILPROBE\x01")
	pongMagic  = []byte("\xffVEILPONG\x01")
)

type probeResult struct {
	Sent            int     `json:"sent"`
	Received        int     `json:"received"`
	ReceivedAfter30 int     `json:"receivedAfter30"`
	LossPercent     float64 `json:"lossPercent"`
	RTTMedianMs     float64 `json:"rttMedianMs"`
	RTTMinMs        float64 `json:"rttMinMs"`
	RTTMaxMs        float64 `json:"rttMaxMs"`
	ServerVersion   string  `json:"serverVersion,omitempty"`
	Hysteria        *bool   `json:"hysteria,omitempty"`
	SourcePorts     int     `json:"sourcePorts"`
	Error           string  `json:"error,omitempty"`
}

func runProbe(args []string) error {
	fs := flag.NewFlagSet("probe", flag.ExitOnError)
	server := fs.String("server", "", "")
	port := fs.Int("port", 2100, "")
	count := fs.Int("count", 40, "")
	rotate := fs.Int("rotate", 22, "")
	interval := fs.Duration("interval", 25*time.Millisecond, "")
	wait := fs.Duration("wait", 2*time.Second, "")
	_ = fs.Parse(args)

	res := probe(*server, *port, *count, *rotate, *interval, *wait)
	enc := json.NewEncoder(os.Stdout)
	_ = enc.Encode(res)
	return nil
}

func probe(server string, port, count, rotate int, interval, wait time.Duration) probeResult {
	res := probeResult{Sent: 0}
	srv, err := net.ResolveUDPAddr("udp4", net.JoinHostPort(server, fmt.Sprint(port)))
	if err != nil {
		res.Error = "resolve: " + err.Error()
		return res
	}

	var (
		mu    sync.Mutex
		sent  = map[uint64]time.Time{}
		rtts  []float64
		after int
		ver   string
		hy    *bool
		seen  = map[uint64]bool{}
		conns []*net.UDPConn
		wg    sync.WaitGroup
	)
	reader := func(c *net.UDPConn) {
		defer wg.Done()
		buf := make([]byte, 2048)
		for {
			n, _, err := c.ReadFromUDP(buf)
			if err != nil {
				if ne, ok := err.(net.Error); ok && ne.Timeout() {
					return
				}
				if strings.Contains(err.Error(), "use of closed") {
					return
				}
				continue
			}
			pkt := buf[:n]
			if !bytes.HasPrefix(pkt, pongMagic) || len(pkt) < len(pongMagic)+8 {
				continue
			}
			seq := binary.BigEndian.Uint64(pkt[len(pongMagic):])
			info := string(pkt[len(pongMagic)+8:])
			mu.Lock()
			if t0, ok := sent[seq]; ok && !seen[seq] {
				seen[seq] = true
				rtts = append(rtts, float64(time.Since(t0).Microseconds())/1000)
				if seq >= 30 {
					after++
				}
				for _, kv := range strings.Split(info, ";") {
					k, v, _ := strings.Cut(kv, "=")
					switch k {
					case "v":
						ver = v
					case "hy":
						b := v == "1"
						hy = &b
					}
				}
			}
			mu.Unlock()
		}
	}

	var cur *net.UDPConn
	cnt := 0
	openSock := func() error {
		c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero})
		if err != nil {
			return err
		}
		conns = append(conns, c)
		cur, cnt = c, 0
		wg.Add(1)
		go reader(c)
		return nil
	}
	if err := openSock(); err != nil {
		res.Error = "socket: " + err.Error()
		return res
	}
	pkt := make([]byte, len(probeMagic)+8)
	copy(pkt, probeMagic)
	for i := 0; i < count; i++ {
		if rotate > 0 && cnt >= rotate {
			if err := openSock(); err != nil {
				res.Error = "socket: " + err.Error()
				break
			}
		}
		binary.BigEndian.PutUint64(pkt[len(probeMagic):], uint64(i))
		mu.Lock()
		sent[uint64(i)] = time.Now()
		mu.Unlock()
		if _, err := cur.WriteToUDP(pkt, srv); err == nil {
			res.Sent++
		}
		cnt++
		time.Sleep(interval)
	}
	deadline := time.Now().Add(wait)
	for _, c := range conns {
		_ = c.SetReadDeadline(deadline)
	}
	wg.Wait()
	for _, c := range conns {
		_ = c.Close()
	}

	res.Received = len(rtts)
	res.ReceivedAfter30 = after
	res.SourcePorts = len(conns)
	res.ServerVersion = ver
	res.Hysteria = hy
	if res.Sent > 0 {
		res.LossPercent = 100 * float64(res.Sent-res.Received) / float64(res.Sent)
	}
	if len(rtts) > 0 {
		sort.Float64s(rtts)
		res.RTTMinMs = rtts[0]
		res.RTTMaxMs = rtts[len(rtts)-1]
		res.RTTMedianMs = rtts[len(rtts)/2]
	}
	return res
}
