package main

import (
	"encoding/binary"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"
)

func cappedEcho(t *testing.T, cap int) (*net.UDPConn, func() int) {
	t.Helper()
	c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	perFlow := map[string]int{}
	go func() {
		buf := make([]byte, 65535)
		for {
			n, a, err := c.ReadFromUDP(buf)
			if err != nil {
				return
			}
			mu.Lock()
			perFlow[a.String()]++
			over := perFlow[a.String()] > cap
			mu.Unlock()
			if !over {
				_, _ = c.WriteToUDP(buf[:n], a)
			}
		}
	}()
	return c, func() int { mu.Lock(); defer mu.Unlock(); return len(perFlow) }
}

func sendAndCount(t *testing.T, relayAddr *net.UDPAddr, n int) int {
	t.Helper()
	cl, err := net.DialUDP("udp4", nil, relayAddr)
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	got := map[uint64]bool{}
	done := make(chan struct{})
	go func() {
		defer close(done)
		buf := make([]byte, 2048)
		for {
			_ = cl.SetReadDeadline(time.Now().Add(1500 * time.Millisecond))
			k, err := cl.Read(buf)
			if err != nil {
				return
			}
			if k >= 8 {
				got[binary.BigEndian.Uint64(buf)] = true
			}
		}
	}()
	pkt := make([]byte, 200)
	for i := 0; i < n; i++ {
		binary.BigEndian.PutUint64(pkt, uint64(i))
		if _, err := cl.Write(pkt); err != nil {
			t.Fatal(err)
		}
		time.Sleep(2 * time.Millisecond)
	}
	<-done
	return len(got)
}

func TestRotationBeatsPerFlowCap(t *testing.T) {
	srv, flows := cappedEcho(t, 30)
	defer srv.Close()
	port := srv.LocalAddr().(*net.UDPAddr).Port

	r, err := newRelay("127.0.0.1", port, "127.0.0.1:0", 22, 8*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	go r.uplink()

	const n = 300
	got := sendAndCount(t, r.local.LocalAddr().(*net.UDPAddr), n)
	if got != n {
		t.Fatalf("with rotation: got %d/%d echoes", got, n)
	}
	if f := flows(); f < n/22 {
		t.Fatalf("expected at least %d flows, saw %d", n/22, f)
	}
}

func TestWithoutRotationTheCapBites(t *testing.T) {
	srv, _ := cappedEcho(t, 30)
	defer srv.Close()
	port := srv.LocalAddr().(*net.UDPAddr).Port
	r, err := newRelay("127.0.0.1", port, "127.0.0.1:0", 1_000_000, 8*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	go r.uplink()
	if got := sendAndCount(t, r.local.LocalAddr().(*net.UDPAddr), 100); got != 30 {
		t.Fatalf("control: expected exactly 30 echoes, got %d", got)
	}
}

func TestOldSocketsAreCollected(t *testing.T) {
	srv, _ := cappedEcho(t, 1000)
	defer srv.Close()
	port := srv.LocalAddr().(*net.UDPAddr).Port
	r, err := newRelay("127.0.0.1", port, "127.0.0.1:0", 2, 200*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	go r.uplink()
	sendAndCount(t, r.local.LocalAddr().(*net.UDPAddr), 40)
	time.Sleep(300 * time.Millisecond)
	r.mu.Lock()
	r.gcLocked()
	open := len(r.socks)
	r.mu.Unlock()
	if open != 1 {
		t.Fatalf("expected only the current socket to remain, %d open", open)
	}
}

func TestProbeAgainstServerRelay(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 not available")
	}
	script, _ := filepath.Abs("../../Server/gate.py")
	if _, err := os.Stat(script); err != nil {
		t.Skip("gate.py not found")
	}
	backend, _ := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	defer backend.Close()
	listen := freeUDPPort(t)
	cmd := exec.Command(py, "-I", script, itoa(listen), itoa(backend.LocalAddr().(*net.UDPAddr).Port))
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer cmd.Process.Kill()
	time.Sleep(400 * time.Millisecond)

	res := probe("127.0.0.1", listen, 40, 22, 5*time.Millisecond, time.Second)
	if res.Received != 40 || res.ReceivedAfter30 != 10 {
		t.Fatalf("probe: %+v", res)
	}
	if res.ServerVersion != "2" || res.Hysteria == nil || !*res.Hysteria {
		t.Fatalf("probe info: %+v", res)
	}
	if res.SourcePorts != 2 {
		t.Fatalf("expected 2 source ports, got %d", res.SourcePorts)
	}
}

func TestProbeNoServer(t *testing.T) {
	res := probe("127.0.0.1", freeUDPPort(t), 5, 22, time.Millisecond, 300*time.Millisecond)
	if res.Received != 0 || res.LossPercent != 100 {
		t.Fatalf("expected total loss: %+v", res)
	}
}

func freeUDPPort(t *testing.T) int {
	c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	return c.LocalAddr().(*net.UDPAddr).Port
}

func itoa(i int) string { return strconv.Itoa(i) }
